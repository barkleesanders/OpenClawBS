# Records Monitor

Autonomous public records request (CPRA/FOIA) management system running on OpenClaw VPS.

## What it does

Every 4 hours, the NR Document Watcher cron:

1. Polls your NextRequest portal for new documents on tracked requests
2. Downloads any new PDFs to `/tmp/`
3. Uploads them to Google Drive (via Composio OAuth — no token expiration)
4. Sends a Telegram notification with a Drive link
5. Writes `/tmp/nr-new-docs.json` with structured metadata

The OpenClaw agent then reads that JSON, extracts PDF text with `pdftotext`, performs gap analysis (what was requested vs. what was produced), and drafts a deficiency letter if records are incomplete.

Separately, `check-deadlines.py` (not in this repo) tracks statutory deadlines (10 days for CPRA acknowledgment, 10-day extensions, etc.) and alerts via Telegram when action is required.

## Files

| File | Purpose |
|------|---------|
| `nr-orchestrator.py` | Main script: poll NR, download, upload to Drive, alert |
| `prr-list.example.json` | Example PRR tracking list — copy to `prr-list.json` and fill in |

## Setup

1. Install dependencies on VPS:
   ```bash
   pip3 install requests
   apt-get install -y poppler-utils   # for pdftotext
   ```

2. Create `/opt/records-monitor/`:
   ```bash
   mkdir -p /opt/records-monitor
   cp nr-orchestrator.py /opt/records-monitor/
   cp prr-list.example.json /opt/records-monitor/prr-list.json
   # edit prr-list.json with your actual request IDs
   ```

3. Fill in secrets. The script reads from environment variables:
   ```bash
   # In /opt/records-monitor/.env (chmod 600):
   COMPOSIO_API_KEY=...
   DRIVE_ROOT_FOLDER_ID=...
   TELEGRAM_BOT_TOKEN=...
   TELEGRAM_CHAT_ID=...
   ```

4. Get your NextRequest session cookie:
   - Log in to your agency's NextRequest portal in Chrome
   - Open DevTools → Application → Cookies → find `_nextrequest_session`
   - Save the value — the script needs it to access your filed requests

5. Test manually:
   ```bash
   python3 /opt/records-monitor/nr-orchestrator.py
   ```

6. Add the OpenClaw cron (see `../openclaw-config/cron-nr-watcher.json`):
   ```bash
   openclaw cron add --from-file /opt/openclaw-config/cron-nr-watcher.json
   ```

## Cookie refresh

NextRequest sessions expire periodically. When the script gets 401s, log in again and update the cookie:
```bash
# The script reads from /opt/records-monitor/cookies.txt
# Format: standard Netscape cookie file (use "Cookie Quick Manager" Firefox extension to export)
```

## Files NOT in this repo (add to .gitignore)

- `prr-list.json` — your actual PRR tracking list (has request IDs)
- `seen-docs.json` — runtime state tracking which docs were already processed
- `cookies.txt` / `nr-cookies.txt` — auth cookies
- `*.bak` — backup files
