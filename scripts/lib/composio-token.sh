#!/bin/bash
# composio-token.sh — Fetch a fresh OAuth token from Composio for any connected app
#
# Composio auto-refreshes tokens server-side, so fetching fresh on each call
# eliminates the whole class of "token expired in production" failures.
#
# Required env:
#   COMPOSIO_API_KEY — your Composio API key
#
# Usage:
#   source /path/to/scripts/lib/composio-token.sh
#   TOKEN=$(composio_token googledrive)
#   # Then call the service's native REST API with: -H "Authorization: Bearer $TOKEN"
#
# Also exposes a preflight helper for cron scripts:
#   composio_preflight googledrive || exit 1

: "${COMPOSIO_API_KEY:?composio_token: COMPOSIO_API_KEY not set}"

_COMPOSIO_HOST="${_COMPOSIO_HOST:-backend.composio.dev}"

# Fetch a fresh access_token for the named Composio toolkit_slug.
# Prints the token on success, prints nothing + returns 1 on failure.
composio_token() {
  local app="${1:?composio_token: need toolkit_slug (e.g. googledrive, gmail, notion)}"
  local token
  token=$(curl -sS --max-time 15 -H "X-API-Key: ${COMPOSIO_API_KEY}" \
    "https://${_COMPOSIO_HOST}/api/v3/connected_accounts?toolkit_slug=${app}&limit=100" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
for a in d.get('items', []):
    if a.get('toolkit', {}).get('slug') == '$app' and a.get('status') == 'ACTIVE':
        tok = a.get('data', {}).get('access_token', '')
        if tok:
            print(tok); sys.exit(0)
sys.exit(1)
" 2>/dev/null)
  if [ -z "$token" ]; then
    return 1
  fi
  echo "$token"
}

# Preflight: verify Composio can issue a token for the named app before doing work.
# Returns 0 if OK, 1 if not (and writes a reason to stderr).
composio_preflight() {
  local app="${1:?composio_preflight: need toolkit_slug}"
  local token
  token=$(composio_token "$app") || true
  if [ -z "$token" ]; then
    echo "composio_preflight: failed to get token for '$app'. Check: node composio-client.cjs status" >&2
    return 1
  fi
  return 0
}

# CLI mode
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    token)      shift; composio_token "$@" ;;
    preflight)  shift; composio_preflight "$@" ;;
    *)          echo "Usage: $0 {token|preflight} <toolkit_slug>" >&2; exit 2 ;;
  esac
fi
