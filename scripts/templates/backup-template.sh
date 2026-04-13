#!/bin/bash
# backup-template.sh — Generic daily backup pattern to Google Drive via Composio-managed auth.
#
# This is a TEMPLATE. Fork it, fill in the two EXPORT/SYNC blocks with whatever
# data source you're backing up (database dump, bucket sync, directory archive), and
# it will handle: preflight auth check, rich Telegram alerts, status file on success,
# old-file cleanup, and gzip/untar boilerplate.
#
# Architecture:
#   1. Preflight: verify Composio can issue a Drive OAuth token (fail fast)
#   2. Export your source data to $TMPDIR/ (you fill this in)
#   3. Upload to Google Drive via drive_upload / drive_upload_tree (Composio-backed)
#   4. Clean up remote copies older than $RETENTION_DAYS
#   5. Write a status file on success; Telegram alert on failure only.
#
# Required env (put in backup.env, chmod 600):
#   COMPOSIO_API_KEY=...
#   TG_TOKEN=...
#   TG_CHAT=...
#   DRIVE_FOLDER_ID=...         # target Drive folder for this backup stream
#   (plus whatever your EXPORT step needs: CF_ACCOUNT_ID, DB_ID, etc.)

set -euo pipefail

########################################
# 0. Constants (edit these)
########################################
BACKUP_NAME="myapp"                    # e.g. "myapp" → file: myapp-YYYYMMDD.sql.gz
RETENTION_DAYS=90                      # keep Drive uploads this many days
STATUS_FILE="/var/lib/${BACKUP_NAME}-backup/status.txt"
LOG="/var/log/${BACKUP_NAME}-backup.log"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# Adjust these paths to wherever you dropped the OpenClawBS scripts/:
: "${OPENCLAW_SCRIPTS:=/usr/local/openclaw-patterns/scripts}"

########################################
# 1. Load env + libs
########################################
# Secrets (chmod 600) — at minimum COMPOSIO_API_KEY, TG_TOKEN, TG_CHAT, DRIVE_FOLDER_ID
source /etc/${BACKUP_NAME}-backup.env
export COMPOSIO_API_KEY TG_TOKEN TG_CHAT DRIVE_FOLDER_ID

START_EPOCH=$(date +%s)
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo vps)

source "${OPENCLAW_SCRIPTS}/lib/alert.sh"
source "${OPENCLAW_SCRIPTS}/lib/composio-token.sh"
source "${OPENCLAW_SCRIPTS}/composio-drive.sh"

########################################
# 2. Housekeeping
########################################
DATE=$(date +%Y%m%d)
TMPDIR="/tmp/${BACKUP_NAME}-backup-$$"
mkdir -p "$TMPDIR" "$(dirname "$LOG")" "$(dirname "$STATUS_FILE")"
trap 'rm -rf "$TMPDIR"' EXIT

log() {
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${ts}] $1" >> "$LOG"
}

log "=== ${BACKUP_NAME} backup started ==="

########################################
# 3. Preflight: Composio must be able to issue a Drive token
########################################
if ! composio_preflight googledrive 2>>"$LOG"; then
  alert CRITICAL "preflight" "Composio could not issue a Google Drive token. Check: node composio-client.cjs status"
  log "PREFLIGHT FAILED"
  exit 1
fi
log "Preflight OK"

########################################
# 4. Export your data (REPLACE THIS BLOCK)
########################################
# EXAMPLE (replace with your export logic):
#   mysqldump -u backup mydb > "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
#   gzip "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
#
# Whatever you produce, set ARCHIVE to its path:
ARCHIVE="$TMPDIR/${BACKUP_NAME}-${DATE}.sql.gz"

# --- BEGIN YOUR EXPORT LOGIC ---
echo "Replace this block with your actual export command" > "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
gzip "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
# --- END YOUR EXPORT LOGIC ---

if [ ! -f "$ARCHIVE" ]; then
  alert CRITICAL "export" "Expected archive at ${ARCHIVE} not found. Export step produced nothing."
  log "Export produced no archive"
  exit 1
fi
SIZE=$(du -h "$ARCHIVE" | cut -f1)
log "Export complete: ${ARCHIVE} (${SIZE})"

########################################
# 5. Upload to Drive
########################################
if drive_upload "$ARCHIVE" "$DRIVE_FOLDER_ID" "${BACKUP_NAME}-${DATE}.sql.gz" >>"$LOG" 2>&1; then
  log "Uploaded to Drive (${SIZE})"
else
  alert CRITICAL "upload" "drive_upload rejected ${ARCHIVE} (${SIZE}). Composio token may be broken — run: node composio-client.cjs status"
  log "Upload failed"
  exit 1
fi

########################################
# 6. Cleanup: delete remote copies older than RETENTION_DAYS
########################################
log "Cleaning old copies (>${RETENTION_DAYS} days)"
drive_delete_older_than "$DRIVE_FOLDER_ID" "$RETENTION_DAYS" >>"$LOG" 2>&1 || true

########################################
# 7. Status file + done
########################################
FINISH=$(date '+%Y-%m-%d %H:%M UTC')
cat > "$STATUS_FILE" <<STATUS
${BACKUP_NAME^} backup OK -- ${FINISH}
  Archive: ${SIZE} -> Drive folder ${DRIVE_FOLDER_ID}
STATUS

log "=== ${BACKUP_NAME} backup complete ==="
