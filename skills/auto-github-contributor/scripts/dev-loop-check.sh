#!/usr/bin/env bash
# Phase-aware dev-loop checker. Invoked from the repo workdir.
# Phases:
#   --phase red    → expect the newest test(s) to FAIL (proves coverage gap)
#   --phase green  → install + lint + typecheck + test (must all pass)
#   --phase final  → clean install + lint + typecheck + full tests + build
#
# Usage:
#   dev-loop-check.sh --phase green [--workdir <dir>]

set -euo pipefail
source "$(dirname "$0")/config.sh"

PHASE=""
WORKDIR="$(pwd)"

while (($#)); do
  case "$1" in
    --phase) PHASE="$2"; shift 2 ;;
    --workdir) WORKDIR="$2"; shift 2 ;;
    *) agc::die "unknown flag: $1" ;;
  esac
done

[[ -n "$PHASE" ]] || agc::die "--phase required (red|green|final)"
[[ -d "$WORKDIR/.git" ]] || agc::die "not a git workdir: $WORKDIR"

cd "$WORKDIR"

run() {
  local label="$1"; shift
  agc::log "▶ ${label}: $*"
  if "$@"; then
    agc::log "✓ ${label}"
    return 0
  else
    local rc=$?
    agc::err "✗ ${label} (exit ${rc})"
    return $rc
  fi
}

has_known_toolchain() {
  [[ -f package.json ]] || [[ -f pnpm-lock.yaml ]] || [[ -f yarn.lock ]] || [[ -f package-lock.json ]] || [[ -f bun.lockb ]] || \
  [[ -f pyproject.toml ]] || [[ -f requirements.txt ]] || [[ -f setup.py ]] || [[ -f go.mod ]] || [[ -f Cargo.toml ]] || \
  [[ -f pom.xml ]] || [[ -f build.gradle ]] || [[ -f build.gradle.kts ]] || [[ -f Makefile ]] || [[ -f justfile ]] || \
  [[ -f Gemfile ]] || [[ -f composer.json ]]
}

collect_changed_paths() {
  {
    git diff --name-only
    git diff --cached --name-only
    git ls-files --others --exclude-standard
  } | sed '/^$/d' | sed 's#\\#/#g' | grep -Ev '^\.auto-pr/' | sort -u
}

is_docs_path() {
  local path="$1"
  case "$path" in
    README|README.*|CHANGELOG|CHANGELOG.*|CONTRIBUTING|CONTRIBUTING.*|LICENSE|LICENSE.*|NOTICE|NOTICE.*) return 0 ;;
    docs/*|.github/*) return 0 ;;
    *.md|*.mdx|*.txt|*.rst|*.adoc|*.asciidoc|*.org) return 0 ;;
    *) return 1 ;;
  esac
}

is_docs_only_change() {
  local changed
  changed="$(collect_changed_paths)"
  [[ -n "$changed" ]] || return 1

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    is_docs_path "$path" || return 1
  done <<<"$changed"

  return 0
}

should_use_docs_only_checks() {
  if is_docs_only_change; then
    agc::log "docs-only change detected; using diff-based verification"
    return 0
  fi

  if ! has_known_toolchain; then
    agc::log "no supported build/test toolchain detected; using diff-based verification"
    return 0
  fi

  return 1
}

run_docs_only_checks() {
  run "diff (worktree)" git diff --check
  run "diff (staged)" git diff --cached --check
}

# Pick the right package manager command based on lockfile.
detect_install_cmd() {
  if [[ -f pnpm-lock.yaml ]]; then echo "pnpm install --frozen-lockfile";
  elif [[ -f yarn.lock ]]; then echo "yarn install --frozen-lockfile";
  elif [[ -f package-lock.json ]]; then echo "npm ci";
  elif [[ -f bun.lockb ]]; then echo "bun install --frozen-lockfile";
  else echo "${AGC_INSTALL_CMD}";
  fi
}

# Pick the JS package manager runner based on lockfile.
detect_runner() {
  if [[ -f pnpm-lock.yaml ]]; then echo "pnpm run";
  elif [[ -f yarn.lock ]]; then echo "yarn";
  elif [[ -f bun.lockb ]]; then echo "bun run";
  else echo "npm run";
  fi
}

detect_script() {
  # Check if package.json defines a given script; echo cmd if present, else fallback.
  local name="$1" fallback="$2"
  if [[ -f package.json ]] && jq -e --arg n "$name" '.scripts[$n] // empty' package.json >/dev/null 2>&1; then
    printf '%s %s' "$(detect_runner)" "$name"
  else
    echo "$fallback"
  fi
}

INSTALL_CMD="$(detect_install_cmd)"
LINT_CMD="$(detect_script lint "$AGC_LINT_CMD")"
TYPECHECK_CMD="$(detect_script typecheck "$AGC_TYPECHECK_CMD")"
TEST_CMD="$(detect_script test "$AGC_TEST_CMD")"
BUILD_CMD="$(detect_script build "$AGC_BUILD_CMD")"

case "$PHASE" in
  red)
    if should_use_docs_only_checks; then
      agc::log "red phase not applicable for docs-only / no-toolchain verification"
      exit 0
    fi
    # Red: run only the test suite. Expect non-zero (failing new test) — we
    # invert the exit code so a "correctly failing" red phase reports success.
    agc::log "red phase: expecting test failure"
    if eval "$TEST_CMD"; then
      agc::err "tests passed in red phase — you have not written a failing test yet"
      exit 1
    else
      agc::log "tests failed as expected (red phase OK)"
      exit 0
    fi
    ;;

  green)
    if should_use_docs_only_checks; then
      run_docs_only_checks
      exit 0
    fi
    run "install" bash -lc "$INSTALL_CMD"
    run "lint" bash -lc "$LINT_CMD"
    run "typecheck" bash -lc "$TYPECHECK_CMD"
    run "test" bash -lc "$TEST_CMD"
    ;;

  final)
    if should_use_docs_only_checks; then
      run_docs_only_checks
      agc::log "final verification complete"
      exit 0
    fi
    run "install (clean)" bash -lc "$INSTALL_CMD"
    run "lint" bash -lc "$LINT_CMD"
    run "typecheck" bash -lc "$TYPECHECK_CMD"
    run "test" bash -lc "$TEST_CMD"
    run "build" bash -lc "$BUILD_CMD"
    # TODO(auto-gh): repo-specific `verify` / e2e hook. Wire a shell command here
    # once the target repo ships a stable e2e target (e.g. `pnpm test:e2e`).
    agc::log "final verification complete"
    ;;

  *)
    agc::die "invalid phase: $PHASE (expected red|green|final)"
    ;;
esac
