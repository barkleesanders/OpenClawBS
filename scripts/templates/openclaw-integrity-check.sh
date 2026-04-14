#!/bin/bash
#
# OpenClaw Integrity Check — systemd ExecStartPre guard (reference impl).
#
# Verifies that every runtime-*.js chunk referenced by openclaw's dist/
# files is actually present on disk before the gateway starts. If a chunk
# is missing (e.g. after a partial/crashed npm install), restores from the
# most recent snapshot created by auto-update.sh.
#
# Philosophy: complement `openclaw update` / `openclaw doctor`, not
# replace them. This script does ONE thing: catch the specific failure
# mode where `dist/` is left with mismatched chunk hashes after an
# interrupted install. That's the exact failure pattern documented in
# docs/12-openclaw-native-first.md.
#
# Install:
#   sudo cp openclaw-integrity-check.sh /usr/local/sbin/
#   sudo chmod +x /usr/local/sbin/openclaw-integrity-check.sh
#   sudo cp openclaw-integrity.conf /etc/systemd/system/openclaw-gateway.service.d/integrity.conf
#   sudo systemctl daemon-reload
#

set -u

DIST="${OPENCLAW_DIST:-/usr/lib/node_modules/openclaw/dist}"
LOG="${INTEGRITY_LOG:-/root/.openclaw/logs/integrity-guard.log}"
SNAPSHOT_DIR="${SNAPSHOT_DIR:-/root/.openclaw/backups}"
NOTIFY_TELEGRAM_SH="${NOTIFY_TELEGRAM_SH:-/root/clawd/scripts/notify-telegram.sh}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date -Iseconds)] $*" >> "$LOG"; }

notify() {
    local msg="$1"
    [ -f "$NOTIFY_TELEGRAM_SH" ] || return 0
    # shellcheck disable=SC1090
    . "$NOTIFY_TELEGRAM_SH" 2>/dev/null || return 0
    if [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ]; then
        curl -s --max-time 5 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT}" -d "text=${msg}" >/dev/null 2>&1 || true
    fi
}

restore_snapshot() {
    local reason="$1"
    local snap
    snap=$(ls -1dt "$SNAPSHOT_DIR"/openclaw-* 2>/dev/null | head -1)
    if [ -z "$snap" ]; then
        log "No snapshot available — cannot restore (reason: $reason)"
        notify "🛡️ Integrity guard: $reason BUT no snapshot to restore from"
        return 1
    fi
    log "Restoring from snapshot: $snap (reason: $reason)"
    rm -rf "$DIST/.." 2>/dev/null || rm -rf /usr/lib/node_modules/openclaw
    if cp -a "$snap" /usr/lib/node_modules/openclaw; then
        log "Restore complete"
        notify "🛡️ Integrity guard restored openclaw from $(basename "$snap") (reason: $reason)"
        return 0
    else
        log "Restore FAILED"
        notify "🚨 Integrity guard restore FAILED — manual intervention needed"
        return 1
    fi
}

# Case 1: dist/ missing entirely
if [ ! -d "$DIST" ]; then
    log "dist/ missing entirely"
    restore_snapshot "dist/ missing" || true
    exit 0  # Never block service start — let systemd's own logic handle persistent failure
fi

# Case 2: enumerate referenced runtime-*.js chunks from dist/ JS files.
# Bundler emits chunk names as "./name.runtime-<hash>.js" (compound names
# can contain dots, e.g. image-generation-core.auth.runtime-MlZEeOnt.js).
# The leading "./" anchor prevents matching short substrings of compound names.
MISSING=$(grep -rhoE '\./[A-Za-z0-9_.-]+\.runtime-[A-Za-z0-9_-]{8,}\.js' "$DIST" 2>/dev/null \
    | sed 's|^\./||' \
    | sort -u \
    | while read -r chunk; do
        [ -f "$DIST/$chunk" ] || echo "$chunk"
    done)

if [ -n "$MISSING" ]; then
    MISSING_COUNT=$(echo "$MISSING" | wc -l)
    log "MISSING runtime chunks detected ($MISSING_COUNT):"
    echo "$MISSING" | while read -r c; do log "  - $c"; done
    restore_snapshot "$MISSING_COUNT missing runtime chunks" || true
else
    log "OK — all runtime chunks present"
fi

exit 0
