#!/usr/bin/env bash
#
# OpenClaw Auto-Update (reference implementation)
#
# Wraps OpenClaw's native `openclaw update` with snapshot + rollback +
# health-gate + out-of-band Telegram alerts.
#
# Philosophy: let `openclaw update` do the update (it runs the package
# manager, plugin sync, doctor checks, and gateway restart natively).
# Our wrapper adds only what openclaw can't do for itself: *rollback*.
# See docs/12-openclaw-native-first.md for the rule and the incident
# that motivated this design.
#
# Suggested cron (PT):
#   0 0 * * * /root/.openclaw/scripts/auto-update.sh >> /root/.openclaw/logs/auto-update.log 2>&1
#

set -euo pipefail

# ─── Config (override via env if you want) ──────────────────────────
SERVICE="${SERVICE:-openclaw-gateway.service}"
OPENCLAW_DIR="${OPENCLAW_DIR:-/usr/lib/node_modules/openclaw}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/root/.openclaw/backups}"
CONFIG="${OPENCLAW_CONFIG:-/root/.openclaw/openclaw.json}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org/openclaw/latest}"
LOCKFILE="${LOCKFILE:-/tmp/openclaw-auto-update.lock}"
NODE="${NODE:-/usr/bin/node}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

# Optional: where notify-telegram.sh lives. If the file exists and exports
# TG_TOKEN + TG_CHAT, the script uses those. Otherwise it reads the creds
# out of openclaw.json (channels.telegram.botToken / allowFrom[0]). If
# neither is available, Telegram alerts are a silent no-op.
NOTIFY_TELEGRAM_SH="${NOTIFY_TELEGRAM_SH:-/root/clawd/scripts/notify-telegram.sh}"

# Optional: npm-bin-fix helper used during rollback on NodeSource systems
# where `npm install -g` doesn't create /usr/bin symlinks. Safe to leave
# pointing at a non-existent file — the call is wrapped in `|| true`.
FIX_NPM_BINS="${FIX_NPM_BINS:-/root/.openclaw/scripts/fix-npm-bins.sh}"

export TZ="${TZ:-America/Los_Angeles}"

# ─── Sources ────────────────────────────────────────────────────────
if [ -f "$NOTIFY_TELEGRAM_SH" ]; then
    # shellcheck disable=SC1090
    source "$NOTIFY_TELEGRAM_SH" 2>/dev/null || true
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Out-of-band Telegram notifier — hits the Bot API directly so it still
# works when openclaw itself is down.
send_telegram() {
    local msg="$1"
    local tok="${TG_TOKEN:-}"
    local chat="${TG_CHAT:-}"
    if [ -z "$tok" ] || [ -z "$chat" ]; then
        if [ -f "$CONFIG" ]; then
            tok=$(python3 -c "import json; print(json.load(open('$CONFIG'))['channels']['telegram']['botToken'])" 2>/dev/null || true)
            chat=$(python3 -c "import json; print(json.load(open('$CONFIG'))['channels']['telegram']['allowFrom'][0])" 2>/dev/null || true)
        fi
    fi
    if [ -z "$tok" ] || [ -z "$chat" ]; then
        log "WARN: Telegram credentials not available; alert skipped: $msg"
        return
    fi
    curl -sf --max-time 10 "https://api.telegram.org/bot${tok}/sendMessage" \
        -d chat_id="$chat" -d text="$msg" -d parse_mode="HTML" \
        >/dev/null 2>&1 || log "WARN: Telegram send failed"
}

cleanup() { rm -f "$LOCKFILE"; }
trap cleanup EXIT

# Prevent concurrent runs
if [ -f "$LOCKFILE" ]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "$LOCKFILE" 2>/dev/null || echo 0) ))
    if [ "$LOCK_AGE" -gt 3600 ]; then
        log "WARN: Stale lock (age ${LOCK_AGE}s), removing"
        rm -f "$LOCKFILE"
    else
        log "INFO: Another update running, exiting"
        exit 0
    fi
fi
echo $$ > "$LOCKFILE"

log "INFO: Starting update check"

# ─── Ensure npm works (openclaw update uses it) ─────────────────────
ensure_npm() {
    if ! $NODE /usr/lib/node_modules/npm/index.js --version &>/dev/null; then
        log "ERROR: npm is broken. Cannot proceed."
        send_telegram "🚨 OpenClaw auto-update: npm broken, manual fix needed."
        exit 1
    fi
}
ensure_npm

# ─── Version check (short-circuit if already latest) ────────────────
INSTALLED_VERSION=$(openclaw --version 2>/dev/null | awk '{print $2}' || echo "unknown")
log "INFO: Installed: $INSTALLED_VERSION"

if [ "$INSTALLED_VERSION" = "unknown" ] || [ -z "$INSTALLED_VERSION" ]; then
    log "ERROR: Cannot determine installed version. openclaw binary may be broken."
    send_telegram "🚨 OpenClaw auto-update: cannot determine installed version."
    exit 1
fi

LATEST_VERSION=$(curl -sf "$NPM_REGISTRY" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null)
if [ -z "$LATEST_VERSION" ]; then
    log "ERROR: Could not fetch latest version from npm registry"
    exit 1
fi
log "INFO: Latest: $LATEST_VERSION"

if [ "$INSTALLED_VERSION" = "$LATEST_VERSION" ]; then
    log "INFO: Already up to date. No action needed."
    exit 0
fi

log "INFO: Update available: $INSTALLED_VERSION -> $LATEST_VERSION"

# ─── Snapshot (our only real value-add over native) ─────────────────
mkdir -p "$SNAPSHOT_DIR"
SNAP_TS="$(date +%Y%m%d-%H%M%S)"
SNAPSHOT="$SNAPSHOT_DIR/openclaw-${INSTALLED_VERSION}-${SNAP_TS}"
log "INFO: Snapshotting current install -> $SNAPSHOT"
if ! cp -a "$OPENCLAW_DIR" "$SNAPSHOT"; then
    log "ERROR: Snapshot failed. Aborting update."
    exit 1
fi
# Keep newest 3
ls -1dt "$SNAPSHOT_DIR"/openclaw-* 2>/dev/null | tail -n +4 | xargs -r rm -rf
log "INFO: Retained snapshots:"
ls -1dt "$SNAPSHOT_DIR"/openclaw-* 2>/dev/null | head -3 | while read d; do log "   $(basename "$d")"; done

# ─── Rollback helper ────────────────────────────────────────────────
rollback_and_alert() {
    local reason="$1"
    log "CRIT: Rolling back. Reason: $reason"
    systemctl stop "$SERVICE" 2>/dev/null || true
    sleep 3
    pkill -9 -f "openclaw-gateway" 2>/dev/null || true
    fuser -k "${GATEWAY_PORT}/tcp" 2>/dev/null || true
    sleep 2

    log "INFO: Restoring from snapshot: $SNAPSHOT"
    rm -rf "$OPENCLAW_DIR"
    cp -a "$SNAPSHOT" "$OPENCLAW_DIR"
    [ -x "$FIX_NPM_BINS" ] && "$FIX_NPM_BINS" || true

    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    systemctl start "$SERVICE" 2>/dev/null || true
    sleep 10

    if ss -tlnp | grep -q ":${GATEWAY_PORT}"; then
        log "INFO: Rollback successful. Gateway running on $INSTALLED_VERSION"
        send_telegram "⚠️ OpenClaw auto-update to ${LATEST_VERSION} failed: ${reason}. Rolled back to ${INSTALLED_VERSION}."
    else
        log "ERROR: Rollback failed. Manual intervention required."
        send_telegram "🚨 OpenClaw auto-update AND rollback both failed. Manual fix required."
    fi
}

# ─── Update via openclaw's native command ───────────────────────────
# Reference: `openclaw update --help`
#   - Runs global package manager update with spec openclaw@latest
#   - Runs plugin update sync after core update
#   - Refreshes shell completion cache
#   - Restarts gateway and runs doctor checks (incl. config migration)
#
# We wrap in `timeout 1500` as an outer belt around --timeout 1200
# per-step.
#
# This is the key change from the anti-pattern: we do NOT run
# `npm install -g openclaw@latest` directly, and we do NOT run `npm
# install` inside the package dir (that pulls devDependencies and
# causes ERESOLVE — see the incident in docs/12-openclaw-native-first.md).
log "INFO: Running openclaw update (native command) -> target ${LATEST_VERSION}"

UPDATE_OUTPUT=$(mktemp)
set +e
timeout 1500 openclaw update --yes --channel stable --timeout 1200 2>&1 | tee "$UPDATE_OUTPUT"
UPDATE_RC=${PIPESTATUS[0]}
set -e

if [ "$UPDATE_RC" -ne 0 ]; then
    log "ERROR: openclaw update failed (exit=$UPDATE_RC)"
    UPDATE_TAIL=$(tail -20 "$UPDATE_OUTPUT" | tr '\n' ' ' | cut -c1-500)
    rm -f "$UPDATE_OUTPUT"
    rollback_and_alert "openclaw update failed (exit=$UPDATE_RC): $UPDATE_TAIL"
    exit 1
fi
rm -f "$UPDATE_OUTPUT"

log "INFO: openclaw update completed. Proceeding to health gate."

# openclaw update already restarted the gateway. Give it a beat to
# settle before we probe.
sleep 10

# ─── Health gate ────────────────────────────────────────────────────
NEW_VERSION=$(openclaw --version 2>/dev/null | awk '{print $2}' || echo "unknown")
log "INFO: Post-update version: $NEW_VERSION"

if [ "$NEW_VERSION" = "unknown" ] || [ -z "$NEW_VERSION" ]; then
    rollback_and_alert "openclaw binary broken after update"
    exit 1
fi

HEALTHY=true

# Port must be listening
if ! ss -tlnp | grep -q ":${GATEWAY_PORT}"; then
    log "WARN: Gateway not listening on port ${GATEWAY_PORT}. Retrying restart once..."
    systemctl restart "$SERVICE" 2>/dev/null || true
    sleep 15
    if ! ss -tlnp | grep -q ":${GATEWAY_PORT}"; then
        log "ERROR: Gateway still not listening after retry"
        HEALTHY=false
    fi
fi

# No missing-module errors (catches chunk-hash drift from partial installs)
if $HEALTHY; then
    MODULE_ERRS=$(journalctl -u "$SERVICE" --since "2 min ago" --no-pager 2>&1 | grep -cE "ERR_MODULE_NOT_FOUND|Cannot find module '${OPENCLAW_DIR}/dist/" || echo "0")
    if [ "$MODULE_ERRS" -gt 0 ]; then
        log "ERROR: ERR_MODULE_NOT_FOUND detected ($MODULE_ERRS occurrences) after update"
        HEALTHY=false
    else
        log "INFO: No module-not-found errors in journal"
    fi
fi

# No invalid-config errors (openclaw doctor should have migrated it)
if $HEALTHY; then
    CONFIG_INVALID=$(journalctl -u "$SERVICE" --since "2 min ago" --no-pager 2>&1 | grep -c 'Config invalid' || echo "0")
    if [ "$CONFIG_INVALID" -gt 0 ]; then
        log "ERROR: Config invalid after update (openclaw doctor should have migrated it)"
        HEALTHY=false
    fi
fi

if ! $HEALTHY; then
    rollback_and_alert "health gate failed after update to ${NEW_VERSION}"
    exit 1
fi

log "INFO: Update complete: $INSTALLED_VERSION -> $NEW_VERSION"
send_telegram "✅ OpenClaw updated: ${INSTALLED_VERSION} → ${NEW_VERSION}"
