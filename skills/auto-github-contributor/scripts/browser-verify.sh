#!/usr/bin/env bash
# Browser-based visual verification.
#
# This script drives a headless browser to capture screenshots / DOM dumps so
# the agent can eyeball the change before opening the PR. The actual automation
# body is intentionally a STUB — wire it up to whichever tool you prefer:
#
#   - Playwright    (pnpm dlx playwright screenshot ...)
#   - Puppeteer     (node ./scripts/puppet.js ...)
#   - chrome-devtools MCP   (mcp__chrome_devtools__take_screenshot)
#   - Browser Use MCP
#
# Contract:
#   Input  : --url <url> --out <png-path> [--selector <css>] [--wait <ms>]
#   Output : writes PNG to --out, prints "SCREENSHOT=<abs-path>" on stdout
#   Stubs  : when the automation body is not yet implemented, the script
#            still creates the output directory, writes a placeholder note,
#            and exits 0 with "stub: <reason>" so the agent flow continues.

set -euo pipefail
source "$(dirname "$0")/config.sh"

URL=""
OUT=""
SELECTOR=""
WAIT_MS="1500"

while (($#)); do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --selector) SELECTOR="$2"; shift 2 ;;
    --wait) WAIT_MS="$2"; shift 2 ;;
    *) agc::die "unknown flag: $1" ;;
  esac
done

[[ -n "$URL" ]] || agc::die "--url required"
[[ -n "$OUT" ]] || agc::die "--out required"

mkdir -p "$(dirname "$OUT")"

agc::log "browser-verify url=${URL} out=${OUT} viewport=${AGC_BROWSER_VIEWPORT} headless=${AGC_BROWSER_HEADLESS}"

# --------------------------------------------------------------------------
# Implementation hook — pick ONE backend and uncomment.
# Left as stubs on purpose; user will plug in preferred tooling.
# --------------------------------------------------------------------------

# === Backend A: Playwright CLI =============================================
# agc::require npx
# VIEWPORT_W="${AGC_BROWSER_VIEWPORT%x*}"
# VIEWPORT_H="${AGC_BROWSER_VIEWPORT#*x}"
# npx --yes playwright@latest screenshot \
#   --viewport-size="${VIEWPORT_W},${VIEWPORT_H}" \
#   --wait-for-timeout "$WAIT_MS" \
#   ${SELECTOR:+--selector "$SELECTOR"} \
#   "$URL" "$OUT"

# === Backend B: Puppeteer via node =========================================
# node "$(dirname "$0")/puppet.mjs" --url "$URL" --out "$OUT" \
#   --selector "$SELECTOR" --wait "$WAIT_MS" \
#   --viewport "$AGC_BROWSER_VIEWPORT" --headless "$AGC_BROWSER_HEADLESS"

# === Backend C: chrome-devtools MCP ========================================
# The agent should call the MCP tool directly rather than shelling out.
# If routed through this script, print the hint so the agent knows to switch:
# agc::log "use mcp__chrome_devtools__take_screenshot instead of this shell"

# --------------------------------------------------------------------------
# Fallback: stub mode
# --------------------------------------------------------------------------
if [[ ! -s "$OUT" ]]; then
  cat > "${OUT%.png}.stub.txt" <<EOF
# TODO(auto-gh): browser-verify backend not wired up yet.
# Requested: $URL
# Would write screenshot to: $OUT
# Selector: ${SELECTOR:-<full page>}
# Wait: ${WAIT_MS}ms
# Viewport: ${AGC_BROWSER_VIEWPORT}
EOF
  agc::log "stub: browser backend not configured (see ${OUT%.png}.stub.txt)"
  printf 'SCREENSHOT=%s\n' "${OUT%.png}.stub.txt"
  exit 0
fi

printf 'SCREENSHOT=%s\n' "$OUT"
