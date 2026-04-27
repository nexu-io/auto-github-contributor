#!/usr/bin/env bash
# Scan a checked-out repo for quick-win contribution candidates.
# Emits a JSON array on stdout. Each entry:
#   { kind, title, summary, file, line, estimated_minutes, slug }
#
# Kinds covered:
#   typo        — common English misspellings in docs / comments
#   missing-test — source files with no matching test file
#   i18n        — locale JSON files missing keys present in the reference locale
#   todo        — TODO/FIXME/XXX comments (actionable picks only)
#
# Usage: scan-quick-wins.sh [--workdir <path>] [--max <n>]
# Notes:
#   - Read-only. Never modifies the repo.
#   - Uses ripgrep when available, falls back to grep.

# shellcheck disable=SC1091
source "$(dirname "$0")/config.sh"
# Deliberately loosen after sourcing config.sh (which sets -e). This is a
# best-effort scanner: individual checks returning empty (e.g. `grep -Ev` with
# no matches) must not abort the run.
set +e
set -uo pipefail

WORKDIR="$(pwd)"
MAX=40
while (($#)); do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    *) agc::die "unknown flag: $1" ;;
  esac
done

[[ -d "$WORKDIR/.git" ]] || agc::die "not a git workdir: $WORKDIR"
cd "$WORKDIR"

if command -v rg >/dev/null 2>&1; then
  BACKEND="rg"
  SEARCH() {
    rg -n --no-heading --hidden \
      --glob '!node_modules' --glob '!dist' --glob '!build' --glob '!.git' --glob '!.next' \
      --glob '!.auto-pr' --glob '!.auto-pr/**' --glob '!**/.auto-pr/**' \
      "$@"
  }
else
  BACKEND="grep"
  SEARCH() {
    grep -rEn --binary-files=without-match \
      --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=.git --exclude-dir=.auto-pr \
      "$@"
  }
fi

# Backend-specific file-type filter for the typo scan.
# rg uses -t <name>; grep uses --include='*.ext'.
if [[ "$BACKEND" == "rg" ]]; then
  # rg covers .jsx/.tsx via 'js'/'ts'; rust/ruby are the long names (not rs/rb).
  TYPO_FILE_FILTER=(-t md -t txt -t rst -t js -t ts -t py -t go -t rust -t java -t ruby)
else
  TYPO_FILE_FILTER=(
    --include='*.md' --include='*.mdx' --include='*.txt' --include='*.rst'
    --include='*.js' --include='*.jsx' --include='*.mjs' --include='*.cjs'
    --include='*.ts' --include='*.tsx' --include='*.cts' --include='*.mts'
    --include='*.py' --include='*.go' --include='*.rs' --include='*.java' --include='*.rb'
  )
fi

# Exclude local workflow metadata paths from findings even if backend globbing
# behavior changes or path-like tokens appear in content.
IS_LOCAL_METADATA_PATH() {
  case "$1" in
    .auto-pr|.auto-pr/*|*/.auto-pr/*) return 0 ;;
    *) return 1 ;;
  esac
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1) Typo scan --------------------------------------------------------
# Curated list: common → correct. Case-insensitive regex; we only report the
# first match per file to keep noise down.
TYPO_MAP=(
  "teh|the"
  "recieve|receive"
  "seperate|separate"
  "occured|occurred"
  "occurence|occurrence"
  "definately|definitely"
  "wierd|weird"
  "accomodate|accommodate"
  "untill|until"
  "refered|referred"
  "acheive|achieve"
  "arguement|argument"
  "begining|beginning"
  "calender|calendar"
  "commited|committed"
  "enviroment|environment"
  "existance|existence"
  "familliar|familiar"
  "foward|forward"
  "independant|independent"
  "occassion|occasion"
  "persistant|persistent"
  "priviledge|privilege"
  "publically|publicly"
  "reccomend|recommend"
  "succesful|successful"
  "sucessful|successful"
  "tommorow|tomorrow"
  "writting|writing"
  "lenght|length"
  "heigth|height"
  "widht|width"
  "wether|whether"
  "alot|a lot"
  "intial|initial"
  "paramter|parameter"
  "paramaters|parameters"
  "parmeter|parameter"
  "responsability|responsibility"
  "transfered|transferred"
  "proccess|process"
)

echo "[]" > "$TMP/typo.json"
for entry in "${TYPO_MAP[@]}"; do
  bad="${entry%%|*}"
  good="${entry#*|}"
  # Word-boundary regex, case-insensitive. Scan text-ish files.
  matches="$(SEARCH -i -w "${TYPO_FILE_FILTER[@]}" "\b${bad}\b" 2>/dev/null | head -n 2 || true)"
  [[ -z "$matches" ]] && continue
  while IFS=: read -r file line _rest; do
    [[ -z "$file" ]] && continue
    IS_LOCAL_METADATA_PATH "$file" && continue
    [[ "$_rest" == *".auto-pr"* ]] && continue
    jq --arg bad "$bad" --arg good "$good" --arg file "$file" --arg line "$line" \
      '. + [{
        kind: "typo",
        title: "Typo: \($bad) → \($good) in \($file)",
        summary: "Fix spelling \"\($bad)\" → \"\($good)\" at \($file):\($line).",
        file: $file,
        line: ($line | tonumber? // 0),
        estimated_minutes: 5,
        slug: "typo-\($bad)-\($file | gsub("[^A-Za-z0-9]+"; "-"))"
      }]' "$TMP/typo.json" > "$TMP/typo.next" && mv "$TMP/typo.next" "$TMP/typo.json"
  done <<<"$matches"
done

# --- 2) Missing-test scan (JS/TS) ----------------------------------------
# For each src/**/*.{ts,tsx,js,jsx} that looks like a module (not a test and not an index re-export),
# check whether a sibling test file exists (same basename + .test.* / .spec.*).
echo "[]" > "$TMP/missing.json"
if [[ -d src ]] || [[ -d packages ]] || [[ -d lib ]]; then
  CANDIDATES="$(
    {
      find src packages lib -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) 2>/dev/null || true
    } | grep -Ev '(\.test\.|\.spec\.|__tests__|__mocks__|\.d\.ts$|node_modules|/dist/|/build/|(^|/)\.auto-pr(/|$))' | head -n 200
  )"
  count=0
  while IFS= read -r src_file; do
    [[ -z "$src_file" ]] && continue
    IS_LOCAL_METADATA_PATH "$src_file" && continue
    ((count > 6)) && break
    dir="$(dirname "$src_file")"
    base="$(basename "$src_file")"
    stem="${base%.*}"
    ext="${base##*.}"
    # Skip trivial re-exports (file is just `export * from ...`).
    if [[ "$(wc -l < "$src_file" 2>/dev/null || echo 0)" -lt 10 ]]; then
      continue
    fi
    # Only flag files that export something.
    grep -qE '^(export |module\.exports|exports\.)' "$src_file" 2>/dev/null || continue
    # Look for a matching test file.
    if ! find "$dir" -maxdepth 2 -type f \( -name "${stem}.test.${ext}" -o -name "${stem}.spec.${ext}" \) 2>/dev/null | grep -q . ; then
      if ! find "$dir" -maxdepth 2 -type d -name '__tests__' -exec find {} -name "${stem}.*" \; 2>/dev/null | grep -q . ; then
        jq --arg file "$src_file" --arg stem "$stem" \
          '. + [{
            kind: "missing-test",
            title: "Add unit tests for \($file)",
            summary: "Exported module \($file) has no co-located test file. Add a minimal test covering its public API.",
            file: $file,
            line: 1,
            estimated_minutes: 30,
            slug: "add-tests-\($stem | gsub("[^A-Za-z0-9]+"; "-"))"
          }]' "$TMP/missing.json" > "$TMP/missing.next" && mv "$TMP/missing.next" "$TMP/missing.json"
        ((count++)) || true
      fi
    fi
  done <<<"$CANDIDATES"
fi

# --- 3) i18n gap scan ----------------------------------------------------
# Heuristic: find folders named "locales", "lang", "i18n" or "translations"
# containing multiple JSON files; flag any file that has fewer top-level keys
# than the largest sibling (likely missing translations).
echo "[]" > "$TMP/i18n.json"
LOCALE_DIRS="$(find . -type d \( -name 'locales' -o -name 'locale' -o -name 'lang' -o -name 'i18n' -o -name 'translations' \) 2>/dev/null | grep -Ev 'node_modules|/dist/|/build/|/\.auto-pr/' | head -n 10)"
while IFS= read -r dir; do
  [[ -z "$dir" ]] && continue
  IS_LOCAL_METADATA_PATH "$dir" && continue
  JSONS="$(find "$dir" -maxdepth 2 -type f -name '*.json' 2>/dev/null | head -n 20)"
  [[ -z "$JSONS" ]] && continue
  # Find the file with the most keys (reference locale).
  ref=""; ref_count=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n="$(jq 'paths(scalars) | length' "$f" 2>/dev/null | wc -l | tr -d ' ')"
    if (( n > ref_count )); then
      ref="$f"; ref_count="$n"
    fi
  done <<<"$JSONS"
  [[ -z "$ref" ]] && continue
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == "$ref" ]] && continue
    n="$(jq 'paths(scalars) | length' "$f" 2>/dev/null | wc -l | tr -d ' ')"
    if (( n > 0 )) && (( n < ref_count * 9 / 10 )); then
      missing=$((ref_count - n))
      jq --arg file "$f" --arg ref "$ref" --arg missing "$missing" \
        '. + [{
          kind: "i18n",
          title: "Fill missing i18n keys in \($file)",
          summary: "Locale \($file) appears to be missing ~\($missing) keys present in \($ref).",
          file: $file,
          line: 1,
          estimated_minutes: 45,
          slug: "i18n-\($file | gsub("[^A-Za-z0-9]+"; "-"))"
        }]' "$TMP/i18n.json" > "$TMP/i18n.next" && mv "$TMP/i18n.next" "$TMP/i18n.json"
    fi
  done <<<"$JSONS"
done <<<"$LOCALE_DIRS"

# --- 4) TODO/FIXME scan --------------------------------------------------
echo "[]" > "$TMP/todo.json"
# Match only TODO/FIXME that look actionable (have a hint of what to do).
# Pattern: TODO|FIXME|XXX followed by a non-alphanum then 15+ chars on the line.
TODOS="$(SEARCH -e '(TODO|FIXME|XXX)[^A-Za-z0-9].{15,200}' 2>/dev/null | head -n 15 || true)"
while IFS=: read -r file line rest; do
  [[ -z "$file" ]] && continue
  IS_LOCAL_METADATA_PATH "$file" && continue
  [[ "$rest" == *".auto-pr"* ]] && continue
  # Clean up the excerpt.
  excerpt="$(printf '%s' "$rest" | sed -E 's/^[[:space:]]+//' | cut -c1-160)"
  jq --arg file "$file" --arg line "$line" --arg excerpt "$excerpt" \
    '. + [{
      kind: "todo",
      title: "Resolve TODO in \($file):\($line)",
      summary: $excerpt,
      file: $file,
      line: ($line | tonumber? // 0),
      estimated_minutes: 60,
      slug: "todo-\($file | gsub("[^A-Za-z0-9]+"; "-"))-\($line)"
    }]' "$TMP/todo.json" > "$TMP/todo.next" && mv "$TMP/todo.next" "$TMP/todo.json"
done <<<"$TODOS"

# --- Merge + cap ---------------------------------------------------------
jq --arg max "$MAX" -s '
  (.[0] + .[1] + .[2] + .[3])
  | unique_by(.slug)
  | sort_by(.estimated_minutes, .kind)
  | .[0:($max | tonumber)]
' "$TMP/typo.json" "$TMP/missing.json" "$TMP/i18n.json" "$TMP/todo.json"
