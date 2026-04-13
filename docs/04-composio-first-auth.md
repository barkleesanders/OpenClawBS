# 04 — Composio-First Auth

## The failure that motivated this

On April 7, 2026, the rclone OAuth token for Google Drive expired. The daily 4 AM backup cron began failing silently — the Cloudflare D1 export succeeded, but the Drive upload rejected with `invalid_grant`. rclone's renewal flow requires a browser callback to `localhost:53682` on the server. Nobody noticed.

Six days of failed backups. Six days of Telegram alerts I'd muted because they seemed noisy. Six days in which, if the production database had corrupted, there would have been no recent recovery point.

The fix wasn't "renew the token." The fix was "stop holding tokens."

## The rule

**For ANY cron, script, or agent action that needs auth to a third-party service, check Composio first before setting up anything else.**

Composio is an OAuth broker. You connect a service once (clicking through its OAuth flow in a browser, at your leisure). Composio stores the refresh token and handles renewal server-side. You fetch a fresh bearer token via API whenever you need one.

The consequence: tokens effectively never expire *from your perspective*. The expiration class of failure is eliminated.

## Order of preference (always)

1. **Composio CLI / action** — if Composio already has the exact action you need, use it directly
2. **Composio OAuth token + service's native REST API** — when Composio's action is too limited (size caps, missing parameters), fetch the token and call the real API
3. **`gcloud` / `az` / `aws` CLIs** — only if Composio has no integration for this service
4. **Per-service OAuth** (`rclone config`, `gh auth`, etc.) — last resort, reintroduces the expiration risk
5. **Service account JSON / long-lived key** — machine-only fallback for services without OAuth

## The token-fetch pattern

See [`scripts/lib/composio-token.sh`](../scripts/lib/composio-token.sh) for the sourceable helper. The core idea:

```bash
TOKEN=$(curl -sS -H "X-API-Key: ${COMPOSIO_API_KEY}" \
  "https://backend.composio.dev/api/v3/connected_accounts?toolkit_slug=googledrive&limit=100" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('items', []):
    if a.get('toolkit', {}).get('slug') == 'googledrive' and a.get('status') == 'ACTIVE':
        print(a['data']['access_token']); break
")
# TOKEN is a fresh ya29.* Google OAuth bearer — good for ~1 hour
# Use it directly with any Drive API endpoint
```

Replace `googledrive` with `gmail`, `notion`, `linear`, `github`, etc. Same pattern works for every connected service.

## When Composio's action is too limited

Composio wraps each service's API in pre-defined actions. Some of them are great; some have awkward constraints.

Example: `GOOGLEDRIVE_UPLOAD_FILE` requires a pre-uploaded `s3key` in Composio's storage (max 5 MB). Useless for backing up a 50 MB tarball.

**Workaround:** skip the action, use the token directly against Google's native Drive API. Full resumable upload support, no size cap, all the parameters Google exposes. See [`scripts/composio-drive.sh`](../scripts/composio-drive.sh) — it's a full rclone replacement that uses Composio for auth and Drive's native endpoints for I/O.

This pattern generalizes: when a Composio action is limiting, the Composio *token* rarely is. Reach for the token + native API.

## What you still need to secure

Composio holds the OAuth tokens, but **you still hold the Composio API key.** That key grants access to all 24+ connected services. If it leaks, every service is compromised.

- Store it only in `/etc/openclaw/env.sh` (chmod 600, root-only)
- Never commit it to git — see `.gitignore`
- Never log it — scripts should `unset COMPOSIO_API_KEY` before logging environment dumps
- Rotate at Composio's dashboard if any doubt

Single key, single point of failure — but at least it's one point instead of 24.

## Preflight check

Every cron that depends on Composio should run a preflight check *before* starting real work:

```bash
source /path/to/scripts/lib/composio-token.sh
composio_preflight googledrive || {
  # Telegram alert with specific reason
  alert CRITICAL "preflight" "Composio could not issue a Drive token. Check: node composio-client.cjs status"
  exit 1
}
```

This fails fast instead of running the expensive export step before discovering auth is broken.

## Migrating an existing cron off rclone / gh / whatever

Rough recipe:

1. Connect the service in Composio (browser, one-time)
2. Copy [`scripts/lib/composio-token.sh`](../scripts/lib/composio-token.sh) into your infrastructure
3. Add a preflight check to your cron
4. Replace the old auth call with a Composio token fetch
5. Call the service's native REST API with the token
6. Keep the old auth as a fallback for ~1 week, then remove

The migration that kicked this off (a daily database + document backup) took about 90 minutes and has been stable since.

## Why this matters structurally

OAuth expiration is a *protocol-level* design flaw that every service provider re-implements differently, and every client has to handle differently. Pushing it into a single broker (Composio) is the only way to make it stop eating your time.

If you're reading this because your OAuth broke again: the fix is not to renew the token. The fix is to move to a broker and never own a token yourself again.
