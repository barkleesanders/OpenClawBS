#!/bin/bash
# cron-wrapper.sh — Wrap any cron job with: locking, alerting on failure, bounded runtime.
#
# Why this exists:
#   - A naive `* * * * * /path/to/script.sh` silently loses stdout/stderr to /dev/null
#   - If the job hangs, cron happily starts another instance on top of it
#   - Failures never surface until someone notices the side effect is missing
#
# This wrapper fixes all three. Drop it in front of any cron script.
#
# Crontab usage:
#   0 4 * * * /path/to/cron-wrapper.sh my-backup /path/to/actual-script.sh
#
# The first arg is a short JOB_NAME (used for lock file, log tag, alert step).
# Remaining args are the command + args to run.

set -euo pipefail

JOB_NAME="${1:?cron-wrapper: need job name as first arg}"
shift

: "${TG_TOKEN:?cron-wrapper: TG_TOKEN must be set}"
: "${TG_CHAT:?cron-wrapper: TG_CHAT must be set}"

LOG="/var/log/cron-${JOB_NAME}.log"
LOCK="/var/lock/cron-${JOB_NAME}.lock"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-3600}"   # default: 1 hour

START_EPOCH=$(date +%s)
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo vps)

# Load the alert helper from wherever you installed OpenClawBS
: "${OPENCLAW_SCRIPTS:=/usr/local/openclaw-patterns/scripts}"
source "${OPENCLAW_SCRIPTS}/lib/alert.sh"

mkdir -p "$(dirname "$LOG")" "$(dirname "$LOCK")"

# --- Acquire lock (fail if another instance is running) ---
exec 9>"$LOCK"
if ! flock -n 9; then
  # Not an error — prior instance still running. Just exit quietly.
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP: previous ${JOB_NAME} still running" >> "$LOG"
  exit 0
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ${JOB_NAME} START (pid $$) ===" >> "$LOG"

# --- Run with timeout, tee output to log ---
EXIT=0
timeout --foreground "$MAX_RUNTIME_SECONDS" "$@" >> "$LOG" 2>&1 || EXIT=$?

RUNTIME=$(( $(date +%s) - START_EPOCH ))

if [ "$EXIT" -eq 0 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ${JOB_NAME} OK (${RUNTIME}s) ===" >> "$LOG"
  exit 0
elif [ "$EXIT" -eq 124 ]; then
  # timeout(1) exit code for "killed by --timeout"
  alert CRITICAL "${JOB_NAME}" "Job exceeded MAX_RUNTIME_SECONDS=${MAX_RUNTIME_SECONDS}. Killed by cron-wrapper. Ran for ${RUNTIME}s."
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ${JOB_NAME} TIMEOUT (${RUNTIME}s) ===" >> "$LOG"
  exit 124
else
  alert CRITICAL "${JOB_NAME}" "Job failed with exit code ${EXIT} after ${RUNTIME}s. Command: $*"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] === ${JOB_NAME} FAIL (exit=${EXIT}, ${RUNTIME}s) ===" >> "$LOG"
  exit "$EXIT"
fi
