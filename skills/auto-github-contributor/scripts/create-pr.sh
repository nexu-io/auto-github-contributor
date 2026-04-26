#!/usr/bin/env bash
# Commit pending changes, push the branch, and open a PR via gh.
# Usage: create-pr.sh <issue-number-or-slug> [--workdir <dir>] [--draft] [--title "..."]
# Env:   TARGET_REPO required, TARGET_FORK optional.
#
# Reads:
#   <workdir>/.auto-pr/SPEC.md
#   <workdir>/.auto-pr/TODO.md
#   <workdir>/.auto-pr/screenshots/*.png  (optional)
#   <workdir>/.auto-pr/BLOCKERS.md        (optional)
#   <workdir>/.auto-pr/issue.json         (optional — only if started from an issue)
# Writes:
#   <workdir>/.auto-pr/PR-BODY.md  (rendered)
# Prints PR URL on success.

set -euo pipefail
source "$(dirname "$0")/config.sh"

KEY="${1:?issue number or slug required}"
shift || true

WORKDIR=""
DRAFT=""
TITLE_OVERRIDE=""
while (($#)); do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2 ;;
    --draft) DRAFT="--draft"; shift ;;
    --title) TITLE_OVERRIDE="$2"; shift 2 ;;
    *) agc::die "unknown flag: $1" ;;
  esac
done

agc::require_repo
agc::require gh
agc::require git

WORKDIR="${WORKDIR:-$(agc::workdir_for "$KEY")}"
[[ -d "$WORKDIR/.git" ]] || agc::die "not a git workdir: $WORKDIR"

cd "$WORKDIR"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# Safety: never commit/push directly to base branch.
case "$BRANCH" in
  main|master|develop) agc::die "refusing to push base branch '$BRANCH'" ;;
esac

ISSUE_JSON_PATH="$WORKDIR/.auto-pr/issue.json"
ISSUE_NUMBER=""
ISSUE_TITLE=""
ISSUE_URL=""
if [[ -f "$ISSUE_JSON_PATH" ]]; then
  ISSUE_NUMBER="$(jq -r '.number' "$ISSUE_JSON_PATH")"
  ISSUE_TITLE="$(jq -r '.title' "$ISSUE_JSON_PATH")"
  ISSUE_URL="$(jq -r '.url' "$ISSUE_JSON_PATH")"
fi

PR_TITLE=""
COMMIT_PREFIX=""
if [[ -n "$TITLE_OVERRIDE" ]]; then
  PR_TITLE="$TITLE_OVERRIDE"
  COMMIT_PREFIX="chore"
elif [[ -n "$ISSUE_NUMBER" ]]; then
  PR_TITLE="fix(#${ISSUE_NUMBER}): ${ISSUE_TITLE}"
  COMMIT_PREFIX="fix"
else
  PR_TITLE="chore: ${KEY}"
  COMMIT_PREFIX="chore"
fi

# 1) Stage + commit if there are changes.
if ! git diff --quiet || ! git diff --cached --quiet; then
  git add -A
  git reset --quiet -- .auto-pr 2>/dev/null || true
  if [[ -n "$ISSUE_NUMBER" ]]; then
    COMMIT_MSG="${COMMIT_PREFIX}(#${ISSUE_NUMBER}): ${ISSUE_TITLE}

Fixes #${ISSUE_NUMBER}

Ref: ${ISSUE_URL}
"
  else
    COMMIT_MSG="${PR_TITLE}
"
  fi
  git commit -m "$COMMIT_MSG"
  agc::log "created commit"
else
  agc::log "no uncommitted changes — assuming work was already committed"
fi

# 2) Decide push remote. Prefer fork when configured.
PUSH_REMOTE="origin"
if [[ -n "${TARGET_FORK}" ]] && git remote | grep -q '^fork$'; then
  PUSH_REMOTE="fork"
else
  agc::log "no fork configured (TARGET_FORK empty) — pushing to origin (${TARGET_REPO}). Ctrl+C within 3s to abort."
  sleep 3 || true
fi
agc::log "pushing to ${PUSH_REMOTE}/${BRANCH}"
git push -u "$PUSH_REMOTE" "$BRANCH"

# 3) Render PR body.
TEMPLATE_DIR="$(cd "$(dirname "$0")/../templates" && pwd)"
PR_BODY="$WORKDIR/.auto-pr/PR-BODY.md"

SPEC_SNIPPET="$(cat "$WORKDIR/.auto-pr/SPEC.md" 2>/dev/null || echo '_spec missing_')"
TODO_SNIPPET="$(cat "$WORKDIR/.auto-pr/TODO.md" 2>/dev/null || echo '_todo missing_')"
SHOT_LIST=""
for f in "$WORKDIR"/.auto-pr/screenshots/*.png; do
  [[ -e "$f" ]] || continue
  SHOT_LIST+=$'\n'"- \`$(basename "$f")\`"
done
[[ -z "$SHOT_LIST" ]] && SHOT_LIST=$'\n'"_No screenshots captured (stub or non-UI change)._"

BLOCKERS_SNIPPET=""
if [[ -f "$WORKDIR/.auto-pr/BLOCKERS.md" ]]; then
  BLOCKERS_SNIPPET="$(cat "$WORKDIR/.auto-pr/BLOCKERS.md")"
fi

export ISSUE_NUMBER ISSUE_TITLE ISSUE_URL SPEC_SNIPPET TODO_SNIPPET SHOT_LIST BLOCKERS_SNIPPET

PYTHON_CMD=()
if command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD=(python3)
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD=(python)
elif command -v py >/dev/null 2>&1; then
  PYTHON_CMD=(py -3)
else
  agc::die "missing dependency: python3 (or python / py -3)"
fi

"${PYTHON_CMD[@]}" - "$TEMPLATE_DIR/PR-BODY.template.md" "$PR_BODY" <<'PY'
import os, pathlib, sys
src, dst = sys.argv[1], sys.argv[2]
body = pathlib.Path(src).read_text()
body = (body
  .replace("{{ISSUE_NUMBER}}", os.environ.get("ISSUE_NUMBER", ""))
  .replace("{{ISSUE_TITLE}}", os.environ.get("ISSUE_TITLE", ""))
  .replace("{{ISSUE_URL}}", os.environ.get("ISSUE_URL", ""))
  .replace("{{SPEC}}", os.environ.get("SPEC_SNIPPET", ""))
  .replace("{{TODO}}", os.environ.get("TODO_SNIPPET", ""))
  .replace("{{SCREENSHOTS}}", os.environ.get("SHOT_LIST", ""))
  .replace("{{BLOCKERS}}", os.environ.get("BLOCKERS_SNIPPET", "")))
pathlib.Path(dst).write_text(body)
PY

# 4) Create PR.
HEAD_REF="$BRANCH"
if [[ "$PUSH_REMOTE" == "fork" && -n "${TARGET_FORK}" ]]; then
  HEAD_REF="${TARGET_FORK%%/*}:${BRANCH}"
fi

agc::log "opening PR against ${TARGET_REPO}:${AGC_BASE_BRANCH} from ${HEAD_REF}"
PR_URL="$(gh pr create \
  -R "$TARGET_REPO" \
  --base "$AGC_BASE_BRANCH" \
  --head "$HEAD_REF" \
  --title "$PR_TITLE" \
  --body-file "$PR_BODY" \
  ${DRAFT} 2>&1 | tee /dev/stderr | tail -n 1)"

agc::log "PR created: $PR_URL"
printf 'PR_URL=%s\n' "$PR_URL"
