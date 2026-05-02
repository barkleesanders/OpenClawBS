#!/bin/bash
# memory-guardian.sh — Prevents OOM crash-loops from silently killing the gateway
#
# Designed for a small VPS (e.g. 3.7 GB RAM) where the OpenClaw gateway can grow
# close to the RAM ceiling. Runs every 5 minutes via cron. Checks four things:
#   1. Gateway process is alive (systemd active)
#   2. Gateway RSS is below MAX_RSS_MB
#   3. System has at least MIN_AVAIL_MB available RAM
#   4. chrome-state.json has not ballooned past MAX_CHROME_STATE_MB
# On any threshold breach: restarts the gateway, drops caches, kills stale Chrome,
# waits for Telegram reconnection, and alerts via Telegram.
#
# Expected env (set in a sourced env file OR systemd drop-in):
#   TELEGRAM_BOT_TOKEN=...
#   TELEGRAM_CHAT_ID=...
#   OPENCLAW_HOME=/root/.openclaw   (optional; defaults to this)
#
# Install:
#   sudo cp memory-guardian.sh /usr/local/bin/
#   sudo chmod +x /usr/local/bin/memory-guardian.sh
#   # crontab -e
#   */5 * * * * /usr/local/bin/memory-guardian.sh >> /var/log/memory-guardian.log 2>&1

set -euo pipefail

# --- User systemd environment (required for cron context) ---
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

# --- Configuration ---
: "${OPENCLAW_HOME:=/root/.openclaw}"
: "${TELEGRAM_BOT_TOKEN:=}"
: "${TELEGRAM_CHAT_ID:=}"

GATEWAY_SERVICE="openclaw-gateway.service"
CHROME_STATE="${OPENCLAW_HOME}/chrome-state.json"
LCM_DB="${OPENCLAW_HOME}/lcm.db"
LOG_FILE="${OPENCLAW_HOME}/logs/memory-guardian.log"
LOCK_FILE="/tmp/memory-guardian.lock"

MAX_RSS_MB=3200          # Restart when gateway RSS is well above steady-state
MIN_AVAIL_MB=200         # Restart when real free headroom gets tight
MAX_CHROME_STATE_MB=10   # Truncate chrome-state.json if > this
MAX_DB_MB=200            # (Optional) VACUUM lcm.db if > this
MAX_RETRIES=2            # Max forced restarts per guardian run

# --- Helpers ---
ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

send_telegram() {
    local msg="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ] && return 0
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d text="${msg}" \
        -d parse_mode="HTML" \
        --max-time 10 >/dev/null 2>&1 || true
}

get_gateway_pid() {
    # MainPID is the parent "openclaw" (tiny). The actual gateway is the child.
    local main_pid
    main_pid=$(systemctl show -p MainPID "${GATEWAY_SERVICE}" 2>/dev/null | cut -d= -f2)
    if [ -n "$main_pid" ] && [ "$main_pid" != "0" ]; then
        local child_pid
        child_pid=$(pgrep -P "$main_pid" 2>/dev/null | head -1)
        if [ -n "$child_pid" ]; then
            echo "$child_pid"
        else
            echo "$main_pid"
        fi
    else
        echo "0"
    fi
}

get_rss_mb() {
    local pid="$1"
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/status" ]; then
        awk '/^VmRSS:/ { printf "%.0f", $2/1024 }' "/proc/$pid/status" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

get_avail_mb() {
    awk '/^MemAvailable:/ { printf "%.0f", $2/1024 }' /proc/meminfo
}

get_file_size_mb() {
    local file="$1"
    if [ -f "$file" ]; then
        stat -c %s "$file" 2>/dev/null | awk '{ printf "%.0f", $1/1048576 }'
    else
        echo "0"
    fi
}

is_gateway_active() {
    systemctl is-active "${GATEWAY_SERVICE}" 2>/dev/null | grep -q "^active$"
}

restart_gateway() {
    local reason="$1"
    log "RESTART: ${reason}"
    local state
    state=$(systemctl show -p ActiveState --value "${GATEWAY_SERVICE}" 2>/dev/null)
    if [ "$state" = "activating" ] || [ "$state" = "deactivating" ]; then
        log "SKIP: systemd already handling restart (state=$state)"
        return 0
    fi
    systemctl restart "${GATEWAY_SERVICE}" 2>&1 || true
}

wait_for_telegram() {
    # Wait up to 90s for the gateway to reconnect Telegram after restart.
    local waited=0
    while [ $waited -lt 90 ]; do
        sleep 10
        waited=$((waited + 10))
        if ! is_gateway_active; then
            log "WARN: Gateway died during startup (waited ${waited}s)"
            return 1
        fi
        if journalctl -u "${GATEWAY_SERVICE}" --since "-${waited} seconds" --no-pager 2>/dev/null \
            | grep -qiE "telegram|provider.*connected|starting provider|listening on ws|heartbeat.*started"; then
            log "OK: Telegram connected after ${waited}s"
            return 0
        fi
    done
    log "WARN: No Telegram activity after 90s"
    return 1
}

# --- Stale lock protection ---
if [ -f "$LOCK_FILE" ]; then
    lock_age=$(( $(date +%s) - $(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0) ))
    if [ "$lock_age" -gt 300 ]; then
        log "WARN: Stale lock (${lock_age}s old), removing"
        rm -f "$LOCK_FILE"
    else
        exit 0
    fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# --- Track if we need to notify ---
DID_RESTART=0
RESTART_REASONS=""

# --- Check 1: Gateway process alive ---
if ! is_gateway_active; then
    log "ALERT: Gateway is NOT running!"
    DID_RESTART=1
    RESTART_REASONS="Gateway was down"
    restart_gateway "Gateway not active"
fi

# --- Check 2: Gateway RSS memory ---
if [ "$DID_RESTART" -eq 0 ]; then
    PID=$(get_gateway_pid)
    RSS=$(get_rss_mb "$PID")
    if [ "$RSS" -gt "$MAX_RSS_MB" ]; then
        log "ALERT: Gateway RSS=${RSS}MB exceeds limit ${MAX_RSS_MB}MB"
        DID_RESTART=1
        RESTART_REASONS="RSS=${RSS}MB (limit ${MAX_RSS_MB}MB)"
        restart_gateway "RSS ${RSS}MB > ${MAX_RSS_MB}MB"
    else
        log "OK: Gateway RSS=${RSS}MB (limit ${MAX_RSS_MB}MB)"
    fi
fi

# --- Check 2.5: Stale Chrome processes (>1hr old) ---
STALE_CHROME=$(ps -eo pid,etimes,args 2>/dev/null | awk '/chrome.*agent-browser/ && $2 > 3600 {print $1}')
if [ -n "$STALE_CHROME" ]; then
    STALE_COUNT=$(echo "$STALE_CHROME" | wc -l | tr -d ' ')
    log "ACTION: Killing $STALE_COUNT stale chrome processes (>1hr old)"
    echo "$STALE_CHROME" | xargs -r kill -9 2>/dev/null || true
fi

# --- Check 3: System available memory ---
AVAIL=$(get_avail_mb)
if [ "$AVAIL" -lt "$MIN_AVAIL_MB" ] && [ "$DID_RESTART" -eq 0 ]; then
    log "ALERT: System available=${AVAIL}MB below minimum ${MIN_AVAIL_MB}MB"
    DID_RESTART=1
    RESTART_REASONS="System RAM=${AVAIL}MB free (minimum ${MIN_AVAIL_MB}MB)"
    pkill -9 -f "chrome" 2>/dev/null || true
    pkill -9 -f "chromium" 2>/dev/null || true
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 2
    restart_gateway "System available ${AVAIL}MB < ${MIN_AVAIL_MB}MB"
fi
log "OK: System available=${AVAIL}MB (minimum ${MIN_AVAIL_MB}MB)"

# --- Check 4: chrome-state.json size ---
CHROME_SIZE=$(get_file_size_mb "$CHROME_STATE")
if [ "$CHROME_SIZE" -gt "$MAX_CHROME_STATE_MB" ]; then
    log "ACTION: chrome-state.json=${CHROME_SIZE}MB > ${MAX_CHROME_STATE_MB}MB, truncating"
    echo '{}' > "$CHROME_STATE"
else
    log "OK: chrome-state.json=${CHROME_SIZE}MB (limit ${MAX_CHROME_STATE_MB}MB)"
fi

## --- Check 5 (optional, disabled by default): lcm.db VACUUM ---
## Uncomment if you want automatic SQLite maintenance.
# DB_SIZE=$(get_file_size_mb "$LCM_DB")
# if [ "$DB_SIZE" -gt "$MAX_DB_MB" ]; then
#     log "ACTION: lcm.db=${DB_SIZE}MB > ${MAX_DB_MB}MB, running VACUUM"
#     sqlite3 "$LCM_DB" "VACUUM;" 2>&1 || log "WARN: VACUUM failed"
#     NEW_DB_SIZE=$(get_file_size_mb "$LCM_DB")
#     log "OK: lcm.db after VACUUM: ${NEW_DB_SIZE}MB (was ${DB_SIZE}MB)"
# fi

# --- Post-restart verification ---
if [ "$DID_RESTART" -eq 1 ]; then
    retry=0
    while [ $retry -lt "$MAX_RETRIES" ]; do
        log "Waiting for Telegram connection (attempt $((retry + 1))/${MAX_RETRIES})..."
        if wait_for_telegram; then
            log "SUCCESS: Gateway recovered and Telegram connected"
            send_telegram "$(cat <<EOF
<b>Gateway Auto-Recovery</b>
Reason: ${RESTART_REASONS}
Status: Recovered, Telegram reconnected
Time: $(ts)
Available RAM: $(get_avail_mb)MB
EOF
)"
            break
        fi

        retry=$((retry + 1))
        if [ $retry -lt "$MAX_RETRIES" ]; then
            log "RETRY: Telegram not connected, forcing restart (attempt $((retry + 1)))"
            pkill -9 -f "chrome" 2>/dev/null || true
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            sleep 2
            restart_gateway "Telegram reconnection retry ${retry}"
        else
            log "FAILED: Could not verify Telegram connection after ${MAX_RETRIES} retries"
            send_telegram "$(cat <<EOF
<b>Gateway Recovery PARTIAL</b>
Reason: ${RESTART_REASONS}
Status: Gateway running but Telegram may not be connected
Time: $(ts)
Action: Manual check recommended
EOF
)"
        fi
    done
fi

log "--- guardian check complete ---"
