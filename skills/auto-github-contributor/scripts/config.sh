#!/usr/bin/env bash
# Shared config for the auto-github-contributor skill.
# Override any value by exporting env vars before invoking a script.
#
# REQUIRED at runtime (no default — the skill prompts the user):
#   TARGET_REPO   "<owner>/<name>"  e.g. refly-ai/refly
#
# OPTIONAL:
#   TARGET_FORK   "<owner>"         push branches to this fork owner (repo name follows TARGET_REPO)
#                                   backward-compatible: "<owner>/<name>" still works
#   AGC_BASE_BRANCH                 default: main
#   AGC_WORK_ROOT                   default: $HOME/auto-gh-contrib-work
#   AGC_LABELS                      comma-separated labels for issue search
#                                   default: "good first issue,help wanted,documentation,good-first-issue"
#   AGC_ISSUE_LIMIT                 default: 30

set -euo pipefail

: "${TARGET_REPO:=}"
: "${TARGET_FORK:=}"

: "${AGC_BASE_BRANCH:=main}"
: "${AGC_WORK_ROOT:="$HOME/auto-gh-contrib-work"}"

: "${AGC_LABELS:=good first issue,help wanted,documentation,good-first-issue}"
: "${AGC_ISSUE_LIMIT:=30}"

# Dev-loop commands. Auto-detected per-repo when possible; these are fallbacks.
: "${AGC_INSTALL_CMD:=pnpm install --frozen-lockfile}"
: "${AGC_LINT_CMD:=pnpm lint}"
: "${AGC_TYPECHECK_CMD:=pnpm typecheck}"
: "${AGC_TEST_CMD:=pnpm test}"
: "${AGC_BUILD_CMD:=pnpm build}"
: "${AGC_DEV_URL:=http://localhost:5173}"

# Browser verification defaults.
: "${AGC_SCREENSHOT_DIR:=.auto-pr/screenshots}"
: "${AGC_BROWSER_HEADLESS:=1}"
: "${AGC_BROWSER_VIEWPORT:=1440x900}"

export TARGET_REPO TARGET_FORK
export AGC_BASE_BRANCH AGC_WORK_ROOT AGC_LABELS AGC_ISSUE_LIMIT
export AGC_INSTALL_CMD AGC_LINT_CMD AGC_TYPECHECK_CMD AGC_TEST_CMD AGC_BUILD_CMD AGC_DEV_URL
export AGC_SCREENSHOT_DIR AGC_BROWSER_HEADLESS AGC_BROWSER_VIEWPORT

agc::log() { printf '[auto-gh] %s\n' "$*" >&2; }
agc::err() { printf '[auto-gh][error] %s\n' "$*" >&2; }
agc::die() { agc::err "$*"; exit 1; }

agc::require() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || agc::die "missing dependency: $bin"
}

agc::require_repo() {
  [[ -n "$TARGET_REPO" ]] || agc::die "TARGET_REPO is empty. Export TARGET_REPO=<owner>/<name> before invoking."
  case "$TARGET_REPO" in
    */*) ;;
    *) agc::die "TARGET_REPO must be in <owner>/<name> form (got: $TARGET_REPO)" ;;
  esac
}

agc::target_repo_name() {
  printf '%s' "${TARGET_REPO#*/}"
}

agc::fork_repo() {
  # TARGET_FORK accepts either:
  # - owner (preferred): owner/<TARGET_REPO name>
  # - owner/repo (legacy): used as-is
  if [[ -z "${TARGET_FORK}" ]]; then
    printf '%s' ""
    return 0
  fi
  case "$TARGET_FORK" in
    */*) printf '%s' "$(agc::normalize_repo "$TARGET_FORK")" ;;
    *) printf '%s/%s' "$TARGET_FORK" "$(agc::target_repo_name)" ;;
  esac
}

agc::repo_slug() {
  printf '%s' "$TARGET_REPO" | tr '/' '-'
}

agc::workdir_for() {
  # $1 = issue number OR a slug for non-issue work
  printf '%s/%s/%s\n' "$AGC_WORK_ROOT" "$(agc::repo_slug)" "$1"
}

agc::slugify() {
  local s="${1:-}"
  s="$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  printf '%s' "${s:0:40}"
}

# Normalize "https://github.com/owner/repo[.git]" or "owner/repo" → "owner/repo".
agc::normalize_repo() {
  local input="$1"
  input="${input%/}"
  input="${input%.git}"
  case "$input" in
    https://github.com/*) input="${input#https://github.com/}" ;;
    git@github.com:*)     input="${input#git@github.com:}" ;;
  esac
  printf '%s' "$input"
}
