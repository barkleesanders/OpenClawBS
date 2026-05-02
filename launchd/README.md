# launchd — OpenClaw on macOS (production reference)

This is the **canonical** deployment for OpenClawBS as of 2026-05-01: a Mac mini
running OpenClaw under a per-user LaunchAgent. The Linux/systemd variant is
preserved at [`legacy/systemd/`](../legacy/systemd/) for hosts where launchd
isn't available.

## Why launchd (over a Linux VPS)

- **iMessage / Notes / Shortcuts** integrations need a real macOS host.
- **Persistent low-watt always-on** — Mac mini M4 base draws ~3W idle.
- **No cgroup OOM killer surprises** — macOS RSS pressure handling is gentler
  than Linux's, so the `memory-guardian` pattern (still useful as a watchdog)
  matters less than it did on a 4 GB VPS.
- **One-time hardware cost** crosses over a Hetzner CX43 in roughly 3 years; for
  iMessage-connected automations the crossover is immediate.

## Files in this directory

| File | Purpose |
|---|---|
| `ai.openclaw.gateway.plist.template` | The LaunchAgent definition. Copies to `~/Library/LaunchAgents/`. |
| `ai.openclaw.gateway-env-wrapper.sh.template` | Wrapper that sources a chmod-600 env file before exec'ing the gateway, so secrets stay out of the world-readable plist. |
| `ai.openclaw.gateway-env.template` | Env file shape (Composio key, Telegram tokens, etc.). Copy + chmod 600. |

## Install

```bash
# 1. Replace YOUR_USERNAME and (if needed) the homebrew paths
USERNAME=$(id -un)
mkdir -p ~/.openclaw/service-env ~/.openclaw/logs ~/Library/LaunchAgents

sed "s/YOUR_USERNAME/${USERNAME}/g" \
    launchd/ai.openclaw.gateway.plist.template \
    > ~/Library/LaunchAgents/ai.openclaw.gateway.plist

cp launchd/ai.openclaw.gateway-env-wrapper.sh.template \
   ~/.openclaw/service-env/ai.openclaw.gateway-env-wrapper.sh
chmod 700 ~/.openclaw/service-env/ai.openclaw.gateway-env-wrapper.sh

cp launchd/ai.openclaw.gateway-env.template \
   ~/.openclaw/service-env/ai.openclaw.gateway.env
chmod 600 ~/.openclaw/service-env/ai.openclaw.gateway.env

# 2. Edit the env file with your real secrets
$EDITOR ~/.openclaw/service-env/ai.openclaw.gateway.env

# 3. Bootstrap the agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist

# 4. Verify
launchctl print gui/$(id -u)/ai.openclaw.gateway | grep -E 'state|program'
lsof -nP -iTCP:18789 -sTCP:LISTEN
```

## Verify the bind is loopback-only

```bash
lsof -nP -iTCP:18789 -sTCP:LISTEN
# Expected:
#   node ... TCP 127.0.0.1:18789 (LISTEN)
#   node ... TCP [::1]:18789 (LISTEN)
# If you see 0.0.0.0:18789 instead, your gateway is exposed publicly — fix
# the `gateway.bind` setting (run `openclaw config` to inspect/edit).
```

## Stop / restart / uninstall

```bash
# Restart (after editing env file or upgrading openclaw)
launchctl kickstart -k gui/$(id -u)/ai.openclaw.gateway

# Stop
launchctl bootout gui/$(id -u)/ai.openclaw.gateway

# Uninstall completely
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist
rm ~/Library/LaunchAgents/ai.openclaw.gateway.plist
rm -rf ~/.openclaw/service-env
```

## Scheduled jobs

Cron-equivalent jobs come in two flavors on macOS:

1. **`openclaw cron`** — for AI agent turns (reasoning, writing, browsing).
   Listed via `openclaw cron list`. The flat-rate model plan makes full-context
   crons effectively free, so they get the workspace + skills.
2. **`launchd` LaunchAgent / LaunchDaemon** — for pure shell jobs (rsync, curl,
   `git pull`). Spending agent tokens on deterministic shell work is pure waste.

System cron (`/etc/crontab`, `crontab -e`) still works on macOS but launchd is
the native idiom and survives sleep/wake cleanly.
