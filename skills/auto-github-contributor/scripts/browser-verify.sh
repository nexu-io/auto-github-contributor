#!/usr/bin/env bash

# Browser-based visual verification.
#
# This script drives a headless browser to capture screenshots / DOM dumps so
# the agent can eyeball the change before opening the PR.  The Playwright
# backend is wired up by default; Puppeteer and chrome-devtools MCP are
# available as drop-in alternatives (see commented blocks below).
#
# Contract:
#   Input  : --url <url> --out <png-path> [--selector <css>] [--wait <ms>]
#   Output : writes PNG to --out, prints "SCREENSHOT=<abs-path>" on stdout
#   Stub   : when the automation body fails, the script still creates the output
#            directory, writes a placeholder note, and exits 0 so the agent flow
#            continues.
#
# Backend selection (change the single `backend` variable below):
#   playwright  – Playwright CLI (default, works on all platforms)
#   puppeteer   – node + puppeteer.mjs
#   chrome-mcp  – chrome-devtools MCP (agent should use MCP tool directly)

set -euo pipefail
source "$(dirname "$0")/config.sh"

URL=""
OUT=""
SELECTOR=""
WAIT_MS="1500"
# Set to "playwright", "puppeteer", or "chrome-mcp"
backend="playwright"

while (($#)); do
  case "$1" in
    --url)     URL="$2";     shift 2 ;;
    --out)     OUT="$2";     shift 2 ;;
    --selector) SELECTOR="$2"; shift 2 ;;
    --wait)    WAIT_MS="$2"; shift 2 ;;
    *)         agc::die "unknown flag: $1" ;;
  esac
done

[[ -n "$URL" ]] || agc::die "--url required"
[[ -n "$OUT" ]] || agc::die "--out required"

mkdir -p "$(dirname "$OUT")"

VIEWPORT_W="${AGC_BROWSER_VIEWPORT%x*}"
VIEWPORT_H="${AGC_BROWSER_VIEWPORT#*x}"

agc::log "browser-verify backend=${backend} url=${URL} out=${OUT} viewport=${AGC_BROWSER_VIEWPORT} headless=${AGC_BROWSER_HEADLESS}"

# ---------------------------------------------------------------------------
# Backend A: Playwright CLI  (default)
# ---------------------------------------------------------------------------
playwright_backend() {
  agc::require npx
  local extra=()
  [[ -n "$SELECTOR" ]] && extra+=(--selector "$SELECTOR")

  if npx --yes playwright@latest screenshot \
    --viewport-size="${VIEWPORT_W},${VIEWPORT_H}" \
    --wait-for-timeout "$WAIT_MS" \
    "${extra[@]}" \
    "$URL" "$OUT" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Backend B: Puppeteer via node
# ---------------------------------------------------------------------------
puppeteer_backend() {
  if [[ -f "$(dirname "$0")/puppet.mjs" ]]; then
    node "$(dirname "$0")/puppet.mjs" \
      --url "$URL" --out "$OUT" \
      --selector "$SELECTOR" --wait "$WAIT_MS" \
      --viewport "$AGC_BROWSER_VIEWPORT" \
      --headless "$AGC_BROWSER_HEADLESS" 2>/dev/null
    return $?
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Backend C: chrome-devtools MCP
# ---------------------------------------------------------------------------
chrome_mcp_backend() {
  # The agent should call mcp__chrome_devtools__take_screenshot directly.
  # If routed here, just log the hint — we can't invoke MCP from bash.
  agc::log "chrome-mcp: use mcp__chrome_devtools__take_screenshot tool directly"
  return 1
}

# ---------------------------------------------------------------------------
# Run the selected backend; fall back to stub on failure
# ---------------------------------------------------------------------------
did_capture=false

case "$backend" in
  playwright)
    if playwright_backend; then
      did_capture=true
      agc::log "screenshot captured via Playwright: $OUT"
    else
      agc::log "Playwright capture failed, falling back to stub"
    fi
    ;;
  puppeteer)
    if puppeteer_backend; then
      did_capture=true
      agc::log "screenshot captured via Puppeteer: $OUT"
    else
      agc::log "Puppeteer capture failed, falling back to stub"
    fi
    ;;
  chrome-mcp)
    if chrome_mcp_backend; then
      did_capture=true
    else
      agc::log "chrome-devtools MCP unavailable, falling back to stub"
    fi
    ;;
  *)
    agc::die "unknown backend: $backend (expected playwright|puppeteer|chrome-mcp)"
    ;;
esac

# ---------------------------------------------------------------------------
# Stub fallback
# ---------------------------------------------------------------------------
if [[ "$did_capture" != "true" ]]; then
  cat > "${OUT%.png}.stub.txt" <<EOF
# browser-verify backend not captured for: $URL
# Backend: $backend
# Would write screenshot to: $OUT
# Selector: ${SELECTOR:-<full page>}
# Wait: ${WAIT_MS}ms
# Viewport: ${AGC_BROWSER_VIEWPORT}
EOF
  agc::log "stub: browser capture unavailable (see ${OUT%.png}.stub.txt)"
fi

printf 'SCREENSHOT=%s\n' "$OUT"
exit 0