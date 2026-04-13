# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.

---

## 🔑 Composio-First Auth (MANDATORY)

For ANY cron, script, or action that needs to talk to a third-party service (Google Drive, Gmail, Notion, Linear, GitHub, Reddit, etc.), **check Composio first** before setting up any other auth.

Composio auto-refreshes OAuth tokens. Once a service is connected there, tokens effectively never expire from our perspective.

### Order of preference (ALWAYS in this order)

1. **Composio CLI / action** — `node /path/to/composio-client.cjs actions <app>`
2. **Composio OAuth token + service native REST API** — for when Composio's action is too limited (size caps, missing params)
3. `gcloud` / `az` / `aws` — only if Composio has no integration for this service
4. Per-service OAuth (`rclone config`, `gh auth`) — last resort, creates expiration risk
5. Service-account JSON / long-lived key — machine-only fallback

### Composio token fetch pattern (reusable for any service)

See `scripts/lib/composio-token.sh` for a sourceable helper. Minimal form:

```bash
source /path/to/scripts/env.sh   # must export COMPOSIO_API_KEY
TOKEN=$(curl -sS -H "X-API-Key: ${COMPOSIO_API_KEY}" \
  "https://backend.composio.dev/api/v3/connected_accounts?toolkit_slug=<app>&limit=100" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for a in d.get('items', []):
    if a.get('toolkit', {}).get('slug') == '<app>' and a.get('status') == 'ACTIVE':
        print(a['data']['access_token']); break
")
```

### Reference implementation

`scripts/composio-drive.sh` — drop-in rclone replacement for Google Drive. Uses Composio for auth, Drive REST API for upload/list/delete. Exposes: `drive_upload`, `drive_list`, `drive_delete`, `drive_purge_folder`, `drive_delete_older_than`, `drive_upload_tree`.

Source it in any script that needs Drive access:

```bash
source /path/to/scripts/env.sh && export COMPOSIO_API_KEY
source /path/to/scripts/composio-drive.sh
drive_upload /path/to/file.gz <folder-id>
```

### Why this rule exists

The original setup used `rclone` for Drive uploads. One day the OAuth token expired — and because rclone only renews via a browser callback to a localhost port on the server, the failure was silent and the backup cron kept failing for six days before anyone noticed. Migrating to Composio-managed tokens eliminated that failure mode. Same risk exists for every other service with its own OAuth — Composio centralizes and auto-refreshes them all.
