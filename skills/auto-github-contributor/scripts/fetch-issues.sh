#!/usr/bin/env bash
# Fetch open beginner-friendly issues from the target repo.
# Queries each label in $AGC_LABELS (comma-separated) separately, merges, de-dupes,
# ranks by a heuristic score (label match strength + freshness + body length),
# and emits a JSON array on stdout.
#
# Env: TARGET_REPO required. AGC_LABELS + AGC_ISSUE_LIMIT optional.

set -euo pipefail
source "$(dirname "$0")/config.sh"

agc::require gh
agc::require jq
agc::require_repo

if ! gh auth status >/dev/null 2>&1; then
  agc::err "gh is not authenticated. Run: gh auth login"
  exit 2
fi

IFS=',' read -r -a LABELS <<<"$AGC_LABELS"

agc::log "searching ${TARGET_REPO} for labels: ${AGC_LABELS}"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

printf '[]' > "$TMP"

for raw_label in "${LABELS[@]}"; do
  label="${raw_label#"${raw_label%%[![:space:]]*}"}"
  label="${label%"${label##*[![:space:]]}"}"
  [[ -z "$label" ]] && continue

  agc::log "  → label='${label}'"

  # Per-label fetch. Some repos won't have a given label — ignore those errors.
  PARTIAL="$(gh issue list \
    -R "$TARGET_REPO" \
    --label "$label" \
    --state open \
    --limit "$AGC_ISSUE_LIMIT" \
    --search "sort:updated-desc no:assignee" \
    --json number,title,url,labels,updatedAt,body 2>/dev/null || echo '[]')"

  jq --argjson add "$PARTIAL" '. + $add' "$TMP" > "$TMP.next" && mv "$TMP.next" "$TMP"
done

# Quick-label weights (more specific beginner-friendly labels score higher).
jq --arg limit "$AGC_ISSUE_LIMIT" '
  def label_score(ls):
    (ls | map(ascii_downcase) | map(
      if . == "good first issue" or . == "good-first-issue" then 3
      elif . == "help wanted" or . == "help-wanted" then 2
      elif . == "documentation" or . == "docs" then 2
      elif . == "typo" then 3
      elif . == "i18n" or . == "l10n" or . == "translation" then 2
      elif . == "testing" or . == "tests" then 2
      else 1 end
    ) | max // 0);

  def freshness(updatedAt):
    ((now - (updatedAt | fromdateiso8601)) / 86400) as $days
    | if $days < 7 then 3
      elif $days < 30 then 2
      elif $days < 90 then 1
      else 0 end;

  def body_clarity(body):
    ((body // "") | length) as $len
    | if $len > 200 and $len < 2000 then 2
      elif $len >= 2000 then 1
      elif $len > 50 then 1
      else 0 end;

  # De-dupe by number; keep first occurrence.
  unique_by(.number)
  | map({
      number,
      title,
      url,
      updatedAt,
      labels: [.labels[].name],
      excerpt: ((.body // "") | gsub("\r"; "") | split("\n") | map(select(length > 0)) | .[0:3] | join(" ") | .[0:240]),
      score: (label_score([.labels[].name]) + freshness(.updatedAt) + body_clarity(.body))
    })
  | sort_by(-.score, .updatedAt)
  | .[0:($limit | tonumber)]
' "$TMP"
