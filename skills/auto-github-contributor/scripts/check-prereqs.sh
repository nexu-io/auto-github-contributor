#!/usr/bin/env bash
# Verify required CLI tools + gh authentication before the agent starts work.
# Exits 0 when everything is ready.
# Exits 2 + prints a structured hint when something is missing — the skill
# surfaces the hint to the user verbatim and stops.
#
# Usage: check-prereqs.sh

set -uo pipefail
# Deliberately not -e: we want to continue checking all tools even when one fails.

# shellcheck disable=SC1091
source "$(dirname "$0")/config.sh"

STATUS=0
MISSING=()
HINTS=()

check_bin() {
  local bin="$1" install_hint="$2"
  if command -v "$bin" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$bin" >&2
  else
    printf '  ✗ %s (not installed)\n' "$bin" >&2
    MISSING+=("$bin")
    HINTS+=("$install_hint")
    STATUS=2
  fi
}

printf '[auto-gh] checking prerequisites...\n' >&2

OS="$(uname -s)"
case "$OS" in
  Darwin) GH_HINT="brew install gh" ;;
  Linux)  GH_HINT="see https://github.com/cli/cli#installation (e.g. 'sudo apt install gh' or 'brew install gh')" ;;
  *)      GH_HINT="see https://github.com/cli/cli#installation" ;;
esac

check_bin gh   "$GH_HINT"
check_bin git  "install git for your OS"
check_bin jq   "$( [[ $OS == Darwin ]] && echo 'brew install jq' || echo 'sudo apt install jq  (or brew install jq)' )"

if ((${#MISSING[@]} > 0)); then
  printf '\n[auto-gh][error] missing required tools: %s\n' "${MISSING[*]}" >&2
  printf '\nInstall hints:\n' >&2
  for i in "${!MISSING[@]}"; do
    printf '  - %s: %s\n' "${MISSING[$i]}" "${HINTS[$i]}" >&2
  done
  exit 2
fi

# gh auth
if ! gh auth status >/dev/null 2>&1; then
  cat >&2 <<'EOF'

[auto-gh][error] gh is installed but not authenticated.

Run this in a terminal, then retry:

  gh auth login

Pick: GitHub.com → HTTPS → authenticate via browser (recommended) or token.
You need at least `repo` scope to open pull requests.
EOF
  exit 2
fi

GH_USER="$(gh api user --jq .login 2>/dev/null || echo '?')"
printf '  ✓ gh authed as %s\n' "$GH_USER" >&2

# Surface the authed user so the skill can default TARGET_FORK.
printf 'GH_USER=%s\n' "$GH_USER"
printf 'READY=1\n'
