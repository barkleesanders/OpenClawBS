# Example: A daily backup cron

Walkthrough of wiring `scripts/templates/backup-template.sh` into a real working cron that backs up a Postgres database to Google Drive via Composio.

## Prerequisites

- A VPS with systemd, bash, python3, and curl (basically every Linux)
- A Composio account with Google Drive connected → [composio.dev](https://composio.dev)
- A Telegram bot + chat ID (see `docs/07-telegram-alerts.md`)
- A Google Drive folder created for the backups — grab its ID from the URL

## Step 1 — Run the installer

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR-GH-USER>/OpenClawBS/main/scripts/install/quick-install.sh | bash
```

After this you have:

- `/usr/local/openclaw-patterns/` — the repo
- `/usr/local/bin/composio-drive.sh`, `memory-guardian.sh`, `cron-wrapper.sh` — symlinks
- `/etc/openclaw/env.sh` — template, needs your secrets

## Step 2 — Fill in secrets

```bash
sudo "$EDITOR" /etc/openclaw/env.sh
```

Minimum to set:

```bash
export COMPOSIO_API_KEY="your-key-from-composio-dashboard"
export TG_TOKEN="your-telegram-bot-token"
export TG_CHAT="your-telegram-chat-id"
export TELEGRAM_BOT_TOKEN="$TG_TOKEN"
export TELEGRAM_CHAT_ID="$TG_CHAT"
export DRIVE_FOLDER_ID="the-drive-folder-id-from-the-url"
```

```bash
sudo chmod 600 /etc/openclaw/env.sh
```

## Step 3 — Verify auth

```bash
source /etc/openclaw/env.sh
bash /usr/local/openclaw-patterns/scripts/lib/composio-token.sh preflight googledrive
echo "exit: $?"  # should print: exit: 0
```

If this fails: check `node composio-client.cjs status` and reconnect Google Drive in the Composio dashboard.

## Step 4 — Fork the backup template

```bash
sudo cp /usr/local/openclaw-patterns/scripts/templates/backup-template.sh /usr/local/bin/mydb-backup.sh
sudo "$EDITOR" /usr/local/bin/mydb-backup.sh
```

Fill in the EXPORT section. For Postgres:

```bash
# --- BEGIN YOUR EXPORT LOGIC ---
PGPASSWORD="$PG_PASSWORD" pg_dump -h "$PG_HOST" -U "$PG_USER" "$PG_DB" > "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
gzip "$TMPDIR/${BACKUP_NAME}-${DATE}.sql"
# --- END YOUR EXPORT LOGIC ---
```

Add the PG vars to `/etc/openclaw/env.sh`:

```bash
export PG_HOST="..."
export PG_USER="..."
export PG_PASSWORD="..."
export PG_DB="..."
```

Update `BACKUP_NAME` and `STATUS_FILE` paths at the top of the script to match your naming.

## Step 5 — Test manually

```bash
sudo /usr/local/bin/mydb-backup.sh
echo "exit: $?"
tail /var/log/mydb-backup.log
```

You should see the backup run to completion, write a status file at `/var/lib/mydb-backup/status.txt`, and upload a file to your Drive folder. Check Drive to confirm.

On any failure: Telegram buzzes with the specific step name, error detail, and log tail. No guessing what went wrong.

## Step 6 — Schedule it

```bash
sudo crontab -e
```

Add:

```cron
# Daily Postgres backup to Drive at 4 AM UTC
0 4 * * * . /etc/openclaw/env.sh && /usr/local/bin/cron-wrapper.sh mydb-backup /usr/local/bin/mydb-backup.sh
```

The `cron-wrapper.sh` adds: file lock (no overlapping runs), timeout (default 1 hour), Telegram alert on non-zero exit, consolidated log.

## Step 7 — Verify tomorrow morning

After the first scheduled run:

```bash
# Did it run?
grep "$(date -d yesterday +%Y-%m-%d)" /var/log/mydb-backup.log | head
# Is the Drive folder getting files?
# (Open Drive in browser or use rclone / composio-drive.sh list)
```

If yes: you're done. It'll run every day forever.

If no: check Telegram (you'll have an alert explaining why) and `/var/log/cron-mydb-backup.log`.

## What you get

- **Preflight check** — if Composio auth is broken, you find out at the very start, not 30 min in
- **Auto-refreshing auth** — you never renew an OAuth token again
- **Resumable uploads** — files >5 MB use resumable upload automatically; no size cap
- **Old-copy cleanup** — files in the Drive folder older than 90 days are deleted automatically
- **Rich alerts** — failures come with enough context to fix without opening the VPS
- **Status on success** — `/var/lib/mydb-backup/status.txt` is the authoritative "last successful run" file

Total setup time from zero to working cron: ~15 minutes.
