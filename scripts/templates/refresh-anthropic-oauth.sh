#!/usr/bin/env bash
#
# refresh-anthropic-oauth.sh (reference implementation)
#
# Hourly re-seed of an OpenClaw `anthropic:oauth` profile from Claude CLI's
# auto-maintained credentials file. Turns a static paste-token profile into
# a self-refreshing one without touching OpenClaw internals.
#
# Why this exists
# ---------------
# `openclaw models auth paste-token` stores the token as a static
# `type: "token"` record with no refresh metadata. Anthropic OAuth access
# tokens expire in ~4h, so a one-time paste breaks silently every night.
#
# Claude CLI (`/usr/bin/claude`) already handles OAuth refresh natively
# against its own credentials file (default `~/.claude/.credentials.json`).
# This script nudges the CLI to refresh-if-needed, reads the fresh access
# token out of the credentials file, and — if it differs from what OpenClaw
# has stored — re-seeds the OpenClaw profile via the native paste-token
# command. Telegram alert on failure.
#
# Refresh trigger: `claude mcp list` is the lightest command proven to
# invoke the CLI's refresh-if-needed path without consuming inference
# tokens (verified by forced-expire test: artificially expired `expiresAt`,
# ran `claude mcp list`, credentials file was rewritten with a new token).
#
# Paste-token footgun: the `openclaw models auth paste-token` prompt
# terminates on **carriage return** (\r), NOT newline (\n). Always use
# `printf '%s\r'` — NOT `echo` and NOT `printf '%s\n'`.
#
# Suggested cron (avoid :00 stampede, every hour):
#   17 * * * * /root/.openclaw/scripts/refresh-anthropic-oauth.sh \
#              >> /root/.openclaw/logs/anthropic-oauth-refresh-cron.log 2>&1
#
# See docs/12-openclaw-native-first.md for the native-first rule and the
# 2026-04-14 incident that motivated this design.

set -euo pipefail

# ─── Config (override via env) ──────────────────────────────────────
CLAUDE_CREDS="${CLAUDE_CREDS:-$HOME/.claude/.credentials.json}"
PROFILES_JSON="${PROFILES_JSON:-$HOME/.openclaw/agents/main/agent/auth-profiles.json}"
PROFILE_ID="${PROFILE_ID:-anthropic:oauth}"
PROVIDER="${PROVIDER:-anthropic}"
CLAUDE_BIN="${CLAUDE_BIN:-/usr/bin/claude}"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
LOG="${LOG:-$HOME/.openclaw/logs/anthropic-oauth-refresh.log}"
LOCK="${LOCK:-/tmp/anthropic-oauth-refresh.lock}"

# Optional: where notify-telegram.sh lives. If the file exists and exports
# TG_TOKEN + TG_CHAT, we use those for alerts. Otherwise alerts are a
# silent no-op (logged, but not raised).
NOTIFY_TELEGRAM_SH="${NOTIFY_TELEGRAM_SH:-/root/clawd/scripts/notify-telegram.sh}"

mkdir -p "$(dirname "$LOG")"

# ─── Concurrency guard (stale lock after 10 min) ────────────────────
if [ -f "$LOCK" ] && [ "$(( $(date +%s) - $(stat -c %Y "$LOCK") ))" -lt 600 ]; then
  echo "[$(date -Iseconds)] Lock held <10min — exiting" >> "$LOG"
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

# ─── Telegram failure alerts (best-effort) ──────────────────────────
TG_AVAILABLE=0
if [ -f "$NOTIFY_TELEGRAM_SH" ]; then
  # shellcheck disable=SC1090
  source "$NOTIFY_TELEGRAM_SH" 2>/dev/null || true
  if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
    TG_AVAILABLE=1
  fi
fi
tg_alert() {
  local msg="$1"
  if [ "$TG_AVAILABLE" = "1" ]; then
    curl -sf --max-time 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="$TG_CHAT" \
      -d text="$msg" \
      -d parse_mode="HTML" >/dev/null 2>&1 || log "WARN Telegram send failed"
  else
    log "WARN Telegram creds missing — alert skipped: $msg"
  fi
}

log "=== Hourly anthropic OAuth refresh ==="

# ─── 1) Nudge Claude CLI to refresh-if-needed ───────────────────────
# `claude mcp list` is the lightest command that (a) touches the API and
# (b) triggers the CLI's refresh logic when the token is near/past expiry.
# No inference tokens consumed. No-op when the token is still valid.
log "Triggering Claude CLI credential refresh via: claude mcp list"
if ! IS_SANDBOX=1 timeout 20 "$CLAUDE_BIN" mcp list >/dev/null 2>&1; then
  log "WARN claude mcp list invocation failed (non-fatal — may still have valid creds)"
fi

# ─── 2) Read the current access token from Claude CLI creds ─────────
if [ ! -f "$CLAUDE_CREDS" ]; then
  log "ERROR $CLAUDE_CREDS missing"
  tg_alert "🔴 OAuth refresh: $CLAUDE_CREDS missing — anthropic:oauth will expire in ~4h"
  exit 1
fi

NEW_TOKEN=$(python3 - <<PYEOF
import json, sys, time
try:
    d = json.load(open("$CLAUDE_CREDS"))
except Exception as e:
    sys.exit(f"parse-error: {e}")
o = d.get("claudeAiOauth", {})
t = o.get("accessToken")
e = o.get("expiresAt")
if not t or not t.startswith("sk-ant-oat"):
    sys.exit("invalid or missing accessToken")
if not e:
    sys.exit("missing expiresAt")
# Token should be valid for at least 5 more minutes; otherwise the CLI
# refresh didn't take effect and we shouldn't propagate an almost-dead token.
if e/1000 < time.time() + 300:
    sys.exit(f"token expires within 5min (at {e}) - Claude CLI refresh did not take effect")
print(t)
PYEOF
) || {
  log "ERROR reading fresh access token: ${NEW_TOKEN:-<empty>}"
  tg_alert "🔴 OAuth refresh: could not read fresh access token from Claude CLI credentials"
  exit 1
}

if [ -z "$NEW_TOKEN" ]; then
  log "ERROR empty access token after parse"
  tg_alert "🔴 OAuth refresh: empty access token after parse"
  exit 1
fi

# ─── 3) Read currently-stored OpenClaw token ────────────────────────
CURRENT_TOKEN=$(python3 - <<PYEOF
import json
try:
    p = json.load(open("$PROFILES_JSON"))["profiles"].get("$PROFILE_ID", {})
    print(p.get("token") or p.get("access") or "")
except Exception:
    print("")
PYEOF
)

# ─── 4) Short-circuit if already in sync ────────────────────────────
if [ "$NEW_TOKEN" = "$CURRENT_TOKEN" ]; then
  log "INFO Token unchanged — no action needed"
  exit 0
fi

log "INFO Token drift detected — re-seeding openclaw $PROFILE_ID profile"
log "INFO old_prefix=${CURRENT_TOKEN:0:20}... new_prefix=${NEW_TOKEN:0:20}..."

# ─── 5) Re-seed via native `openclaw models auth paste-token` ───────
# CRITICAL: the paste-token prompt terminator is \r, not \n.
PASTE_OUT=$(printf '%s\r' "$NEW_TOKEN" \
  | "$OPENCLAW_BIN" models auth paste-token --provider "$PROVIDER" --profile-id "$PROFILE_ID" 2>&1) || {
  log "ERROR paste-token failed"
  log "paste-token output: $PASTE_OUT"
  tg_alert "🔴 OAuth refresh: openclaw models auth paste-token failed — Telegram bot may break in ~4h"
  exit 1
}
log "paste-token output: $(echo "$PASTE_OUT" | tr '\n' ' ' | head -c 500)"

# ─── 6) Verify persistence ──────────────────────────────────────────
VERIFY_TOKEN=$(python3 - <<PYEOF
import json
try:
    p = json.load(open("$PROFILES_JSON"))["profiles"].get("$PROFILE_ID", {})
    print(p.get("token") or p.get("access") or "")
except Exception:
    print("")
PYEOF
)
if [ "$VERIFY_TOKEN" != "$NEW_TOKEN" ]; then
  log "ERROR paste-token did not persist — expected ${NEW_TOKEN:0:20}..., got ${VERIFY_TOKEN:0:20}..."
  tg_alert "🔴 OAuth refresh: paste-token did not persist — check $LOG"
  exit 1
fi

# ─── 7) Live probe to confirm the new token authenticates ───────────
# openclaw emits `[plugins] ...` chatter on stdout/stderr before the JSON
# blob — strip everything up to the first line starting with `{`.
PROBE_JSON=$("$OPENCLAW_BIN" models status --probe --probe-provider "$PROVIDER" \
             --probe-profile "$PROFILE_ID" --json 2>/dev/null \
             | awk '/^{/{f=1} f')

PROBE_STATUS=$(printf '%s' "$PROBE_JSON" | jq -r --arg id "$PROFILE_ID" '
  .auth.probes.results // []
  | map(select(.profileId==$id))
  | if length==0 then "no-result"
    else (.[0].status // "unknown")
    end
' 2>/dev/null || echo "parse-error")

if [ "$PROBE_STATUS" = "ok" ]; then
  log "SUCCESS refreshed $PROFILE_ID token; probe status=ok"
  exit 0
else
  PROBE_ERR=$(printf '%s' "$PROBE_JSON" | jq -r --arg id "$PROFILE_ID" '
    .auth.probes.results // []
    | map(select(.profileId==$id))
    | if length==0 then "no-probe-result"
      else (.[0].error // "unspecified")
      end
  ' 2>/dev/null || echo "parse-error")
  log "ERROR probe failed after re-seed: status=$PROBE_STATUS error=$PROBE_ERR"
  tg_alert "🔴 OAuth refresh: probe failed after token update (status=$PROBE_STATUS, err=$PROBE_ERR) — check $LOG"
  exit 1
fi
