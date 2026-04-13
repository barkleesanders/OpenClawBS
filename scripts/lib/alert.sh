#!/bin/bash
# alert.sh — Rich Telegram alerts for cron jobs and background scripts
#
# Source this from any script that needs to alert on failure. Requires:
#   TG_TOKEN    — Telegram bot token
#   TG_CHAT     — Telegram chat ID
#   LOG         — path to this script's log file (used to tail for context)
#   START_EPOCH — set to `$(date +%s)` at script start (for runtime calc)
#   HOSTNAME_SHORT — defaults to `hostname -s`
#
# Usage:
#   source /path/to/scripts/lib/alert.sh
#   alert CRITICAL "D1 export trigger" "Cloudflare D1 export API rejected the request."
#
# Severities:
#   CRITICAL → 🚨 (backup failed entirely)
#   WARNING  → ⚠️ (partial failure, some items missing)
#   INFO     → ✅ (unusual success — e.g. self-test)

: "${TG_TOKEN:?alert.sh: TG_TOKEN not set}"
: "${TG_CHAT:?alert.sh: TG_CHAT not set}"
: "${LOG:=/tmp/openclaw-cron.log}"
: "${START_EPOCH:=$(date +%s)}"
: "${HOSTNAME_SHORT:=$(hostname -s 2>/dev/null || echo vps)}"

alert() {
  local severity="${1:-CRITICAL}"
  local step="${2:-unknown}"
  local detail="${3:-no detail}"
  local now_utc; now_utc=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  local runtime_s=$(( $(date +%s) - START_EPOCH ))
  local emoji
  case "$severity" in
    CRITICAL) emoji="🚨" ;;
    WARNING)  emoji="⚠️" ;;
    INFO)     emoji="✅" ;;
    *)        emoji="📣" ;;
  esac

  # Tail last 5 log lines (trimmed) with a light escape pass for Markdown.
  local log_tail=""
  if [ -f "$LOG" ]; then
    log_tail=$(tail -n 5 "$LOG" 2>/dev/null \
      | sed 's/\[`*/[/g; s/`*\]/]/g; s/\*//g; s/_/\\_/g' \
      | cut -c -200)
  fi

  # Keep the detail comfortably under Telegram's 4096-char message cap.
  local detail_trim; detail_trim=$(echo -n "$detail" | head -c 800)

  local msg
  msg=$(cat <<MSG
${emoji} *${HOSTNAME_SHORT^^} ${severity}*

*Step:* ${step}
*Time:* ${now_utc}
*Runtime:* ${runtime_s}s

*Detail:*
\`\`\`
${detail_trim}
\`\`\`

*Recent log:*
\`\`\`
${log_tail}
\`\`\`

Log file: \`${LOG}\`
MSG
)
  curl -s -m 10 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode chat_id="${TG_CHAT}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="$msg" > /dev/null 2>&1 || true
}
