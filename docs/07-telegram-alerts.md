# 07 — Telegram Alerts: Fail Loud, Succeed Quiet

## Philosophy

Your attention is the most expensive resource in this system. Respect it.

- **Successful runs stay quiet.** They write a status file on disk. No notification.
- **Failed runs alert Telegram with enough context that you can triage without opening a terminal.**
- **Borderline (partial failures) get a WARNING instead of a CRITICAL** — same channel, different severity.

The goal: when your phone buzzes with a Telegram alert, you know it's real, and you know within 10 seconds what's wrong and where to look.

## The alert format

Every alert has the same structure:

```
🚨 VPS-HOSTNAME CRITICAL

Step: D1 export trigger
Time: 2026-04-13 12:25:51 UTC
Runtime: 5s

Detail:
```
Cloudflare D1 export API rejected the request. Response:
{"success":false,"errors":[{"code":7001,"message":"..."}]}
```

Recent log:
```
[2026-04-13 12:25:46] === backup started ===
[2026-04-13 12:25:48] Step 1: Starting D1 export...
[2026-04-13 12:25:51] export rejected (HTTP 400)
```

Log file: `/var/log/myapp-backup.log`
```

Every piece earns its place:

- **Severity + emoji** — scannable at a glance on a locked phone
- **Hostname** — when you have 3 VPSes, you know which one
- **Step name** — specific to this failure mode, not just "failed"
- **UTC time** — no timezone confusion
- **Runtime** — "died in 5s" vs "died after 3 hours" tells you which class of bug
- **Detail** — the *actual* error, not "something went wrong"
- **Recent log** — context you'd have grepped manually anyway
- **Log file path** — when you want the full picture, you know where to tail

## Severity levels

- **`CRITICAL` (🚨)** — total failure. The thing that was supposed to happen didn't happen. Investigate now.
- **`WARNING` (⚠️)** — partial failure. Some work succeeded, some didn't. Can wait until morning.
- **`INFO` (✅)** — unusual success. Rare — used for first-time-after-migration confirmations and self-tests.

## Implementation

See [`scripts/lib/alert.sh`](../scripts/lib/alert.sh). Source it from any bash script:

```bash
source /path/to/scripts/lib/alert.sh

START_EPOCH=$(date +%s)  # required, used for runtime calculation
LOG=/var/log/mything.log  # required, used to tail recent context
# TG_TOKEN and TG_CHAT must be in env already (from /etc/openclaw/env.sh)

# Usage:
alert CRITICAL "db export" "Postgres dump returned empty output. Connection string: $DB_URL"
alert WARNING  "upload" "3 of 47 files failed to upload. See log for per-file errors."
alert INFO     "migration" "First fully-green backup since April 7. Composio migration complete."
```

The function handles: emoji lookup, log tail extraction, Markdown escaping, URL-encoding for Telegram API, timeout (won't block the script if Telegram is down).

## Targeted alerts per failure class

Don't let one generic alert cover five different failure modes. Split them:

```bash
# BAD — generic, tells you nothing actionable
alert CRITICAL "backup" "something went wrong"

# GOOD — specific, points to the fix
alert CRITICAL "D1 export trigger" "Cloudflare D1 export API rejected the request. Response body included in detail."
alert CRITICAL "D1 export polling" "Export did not complete after 60s. Last status: processing"
alert CRITICAL "D1 dump download" "curl failed to download SQL dump from signed URL. Check network/auth."
alert CRITICAL "D1 upload to Drive" "drive_upload rejected file. Composio token may be broken — run: node composio-client.cjs status"
alert CRITICAL "R2 sync to Drive" "drive_upload_tree failed. Check log for per-file errors."
alert WARNING  "R2 download"       "Backup finished but $N R2 objects failed to download from Cloudflare. Drive mirror is incomplete."
alert CRITICAL "preflight"         "Composio could not issue a Drive token. Check: node composio-client.cjs status"
```

Each one tells you: *what specifically failed* + *what to do about it*. That's the whole game.

## Preflight alerts

The most valuable alert is often the one that fires *before* work begins — not after.

```bash
if ! composio_preflight googledrive; then
  alert CRITICAL "preflight" "Composio OAuth broken. Run: node composio-client.cjs status. Backup aborted."
  exit 1
fi
```

This means when auth is broken, you find out at 4 AM (when the cron starts) instead of 4:05 AM (after the expensive export step runs and then fails on upload). 5 minutes faster isn't huge — but the *clarity* of the alert is: "Composio broken" is specific and fixable; "upload failed" is generic and ambiguous.

## Telegram bot setup (if you haven't already)

1. Message `@BotFather` on Telegram, run `/newbot`, pick a name and username. Save the token.
2. Start a chat with your new bot. Send it "hi".
3. Hit `https://api.telegram.org/bot<TOKEN>/getUpdates` and find the `chat.id` in the JSON response.
4. Export `TG_TOKEN` and `TG_CHAT`.

Total setup time: 2 minutes. 

## Why Telegram and not email / Slack / PagerDuty

- **Latency** — Telegram messages arrive in 1-2 seconds, reliably
- **Simplicity** — one HTTP POST, no libraries, no auth broker needed
- **Rich formatting** — Markdown support means alerts can have code blocks
- **Phone-native** — push notifications work, unlike email
- **Free, forever** — no per-seat cost, no expiration
- **Bot, not a person** — won't accidentally alert someone who left the company

For a personal setup this is overwhelmingly the right choice. For a team, Slack or PagerDuty is more appropriate — but the alert format (severity + step + detail + log tail) is the same.

## The self-test pattern

Send yourself an `INFO` alert after any migration to prove the alert path still works:

```bash
alert INFO "self-test" "Post-migration alert test. If you see this, Telegram routing is live."
```

You'd be surprised how often alerts fail silently because a token got rotated or the bot got banned. A one-off self-test after every change confirms end-to-end.

## What NOT to alert on

- Successful runs
- Stdout from successful runs
- DEBUG-level events
- Anything that happens more than once per hour
- Anything you'd ignore anyway

If it's not worth a phone buzz, it shouldn't be an alert. Put it in the log file instead.
