#!/usr/bin/env bash
# Clone (or reuse) the target repo in an isolated workdir and create a feature branch.
# Usage: setup-workspace.sh <issue-number-or-slug> [--title "<branch title>"]
# Env:   TARGET_REPO required, TARGET_FORK optional.
# Prints (machine-readable):
#   WORKDIR=<abs path>
#   BRANCH=<branch name>
#   ISSUE_TITLE=<string>   (only when an issue number was given)

set -euo pipefail
source "$(dirname "$0")/config.sh"

KEY="${1:?issue number or slug required}"
shift || true

TITLE_OVERRIDE=""
while (($#)); do
  case "$1" in
    --title) TITLE_OVERRIDE="$2"; shift 2 ;;
    *) agc::die "unknown flag: $1" ;;
  esac
done

agc::require_repo
agc::require gh
agc::require git
agc::require jq

WORKDIR="$(agc::workdir_for "$KEY")"
mkdir -p "$AGC_WORK_ROOT"

# Safety: never operate outside $AGC_WORK_ROOT.
case "$WORKDIR" in
  "$AGC_WORK_ROOT"/*) ;;
  *) agc::die "refusing to operate on path outside AGC_WORK_ROOT: $WORKDIR" ;;
esac

ISSUE_JSON=""
ISSUE_TITLE=""
BRANCH_PREFIX="fix"
if [[ "$KEY" =~ ^[0-9]+$ ]]; then
  agc::log "fetching issue metadata for #$KEY"
  ISSUE_JSON="$(gh issue view "$KEY" -R "$TARGET_REPO" --json number,title,body,labels,url)"
  ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title')"
  SLUG="$(agc::slugify "$ISSUE_TITLE")"
  BRANCH="${BRANCH_PREFIX}/issue-${KEY}-${SLUG}"
else
  # Quick-win mode: KEY is already a slug (e.g. "typo-readme").
  ISSUE_TITLE="${TITLE_OVERRIDE:-$KEY}"
  SLUG="$(agc::slugify "$KEY")"
  BRANCH_PREFIX="chore"
  BRANCH="${BRANCH_PREFIX}/${SLUG}"
fi

CLONE_URL="https://github.com/${TARGET_REPO}.git"

if [[ -d "$WORKDIR/.git" ]]; then
  agc::log "reusing existing workdir: $WORKDIR"
  git -C "$WORKDIR" fetch origin --prune
else
  agc::log "cloning $CLONE_URL → $WORKDIR"
  git clone --depth 50 "$CLONE_URL" "$WORKDIR"
fi

# Make sure base branch is up to date.
git -C "$WORKDIR" checkout "$AGC_BASE_BRANCH"
git -C "$WORKDIR" pull --ff-only origin "$AGC_BASE_BRANCH"

# Configure fork remote if provided.
if [[ -n "${TARGET_FORK}" ]]; then
  if git -C "$WORKDIR" remote | grep -q '^fork$'; then
    git -C "$WORKDIR" remote set-url fork "https://github.com/${TARGET_FORK}.git"
  else
    git -C "$WORKDIR" remote add fork "https://github.com/${TARGET_FORK}.git"
  fi
fi

# Create or reset branch off latest base.
if git -C "$WORKDIR" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  agc::log "branch $BRANCH exists — switching to it"
  git -C "$WORKDIR" checkout "$BRANCH"
else
  git -C "$WORKDIR" checkout -b "$BRANCH" "$AGC_BASE_BRANCH"
fi

mkdir -p "$WORKDIR/.auto-pr/screenshots"

if [[ -n "$ISSUE_JSON" ]]; then
  printf '%s\n' "$ISSUE_JSON" > "$WORKDIR/.auto-pr/issue.json"
fi
printf '%s\n' "$TARGET_REPO" > "$WORKDIR/.auto-pr/target-repo.txt"

agc::log "workspace ready"
printf 'WORKDIR=%s\n' "$WORKDIR"
printf 'BRANCH=%s\n' "$BRANCH"
printf 'ISSUE_TITLE=%s\n' "$ISSUE_TITLE"
