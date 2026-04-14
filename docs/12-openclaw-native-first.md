# 12 — OpenClaw Native-First Rule

> **Before writing any custom script, cron, systemd unit, or workaround for OpenClaw, check what OpenClaw itself already does natively. Custom wrappers are the last resort, not the first move.**

This is the single most expensive lesson from running OpenClaw on a small VPS for a year. Every outage we've had in the last two months traced back to home-grown bandaids that reimplemented — badly — functionality OpenClaw ships out of the box.

## Why this rule exists

Over spring 2026, a pile of custom scripts accumulated on the VPS. Each looked like a small targeted fix at the time. The cumulative effect was catastrophic.

| Custom band-aid | What it reimplemented | How it failed |
|---|---|---|
| `auto-update.sh` custom dep-validation | `openclaw update` | Ran `npm install` inside `/usr/lib/node_modules/openclaw`, pulled devDependencies, `madge@8 ↔ typescript@6` ERESOLVE, corrupted `dist/` chunk hashes, gateway crash-looped for 9 hours |
| `gateway-self-heal.service` + `clear-stale-session.sh` | `openclaw doctor` + agent-runner's built-in `/new` recovery | Parsed journal for "No conversation found with session ID: X", recursively nuked refs from `sessions.json`, emitted a Telegram notification each time. Didn't clear in-memory cache. Looped on every user message, spamming "self-heal: cleared stale session …" until gateway restart. |
| Custom `"Unrecognized key"` regex → jq config rewrite | `openclaw doctor --fix` | Missed key migrations OpenClaw knew about; didn't learn new ones; ran at the wrong time in the update lifecycle |
| `session-watcher.service` (inotify on `sessions.json`) | OpenClaw's own atomic writes | Raced with the gateway's atomic rename. Left 5 abandoned `sessions.json.*.tmp` files (up to 10 MB each) from crashed writes. |
| Hardcoded Telegram bot token in self-heal script | `notify-telegram.sh` (single source of truth) | Token drift. Secret on disk outside the sanctioned credential file. |
| Custom plugin-dep installer | `openclaw plugins install` | Ran `npm install grammy @grammyjs/…` in the wrong cwd; left orphan node_modules |

Every single one was avoidable by asking, before writing the script: *"What does `openclaw --help` say about this?"*

## The rule in one line

```
openclaw --help → openclaw <area> --help → openclaw <area> <action> --dry-run → docs.openclaw.ai
```

Only after all four return "not supported" do you write custom code.

## Canonical native commands

| Task | Use this, not a script |
|---|---|
| Update the package | `openclaw update --yes --channel stable --timeout 1200` |
| Migrate config after update | Auto-run by `openclaw update`; or `openclaw doctor --fix` |
| Health-check the gateway | `openclaw health` or `openclaw doctor` |
| Restart the gateway | `openclaw gateway restart` (wraps systemd; matches install model) |
| Clear stale session state | `openclaw doctor --fix` + user-side `/new` in the chat |
| Install/remove plugins | `openclaw plugins install` / `openclaw plugins remove` |
| Rotate model auth | `openclaw models auth login --provider <p>` |
| Deep config audit | `openclaw doctor --deep` |
| Inspect memory | `openclaw memory` (search/reindex) |
| Manage cron jobs | `openclaw cron` (don't hand-edit `cron/jobs.json`) |
| Manage channels | `openclaw channels` (don't edit `channels.*` in `openclaw.json`) |

## Red flags — if you're writing any of these, STOP and check native first

- A journal-tail watcher that parses error strings → there's almost certainly a native `doctor` subcommand or RPC for the same signal
- A recursive JSON walker over `/root/.openclaw/*.json` → native tooling reads/writes these; you will race with it
- A new systemd service that wraps the `openclaw` CLI → OpenClaw already ships daemon management
- Hardcoded paths under `/usr/lib/node_modules/openclaw/dist/` → those filenames change every release (Vite emits new chunk hashes)
- `npm install` inside the openclaw package directory → always wrong; pulls dev dependencies that production installs omit
- Custom config migration "because doctor seems too aggressive" → pass `--non-interactive` (safe migrations only) instead of routing around it

## When a custom wrapper is genuinely justified

Rare. Two legitimate cases we've found:

1. **Thin outer guard** — e.g., snapshot `/usr/lib/node_modules/openclaw` before calling `openclaw update`, then roll back from snapshot if a health gate fails afterward. This adds rollback *around* the native command without replacing it. See `scripts/auto-update.sh` for the current shape.

2. **Cross-service coordination OpenClaw can't know about** — e.g., pause a separate process before restarting the gateway. These should be vanishingly rare.

Any custom wrapper must:
- Document at the top why the native path didn't work
- Link the `docs.openclaw.ai` URL the author checked
- Be revisited quarterly — OpenClaw ships monthly, your workaround may already be obsolete

## Enforcement in this repo

- This document (`docs/12-openclaw-native-first.md`) is linked from `README.md`
- `claude-code/CLAUDE.md.sanitized` references this rule under "Operating OpenClaw"
- Any PR that adds a shell wrapper, cron, or systemd unit touching OpenClaw must justify why `openclaw <thing>` doesn't work first

## Incident record

**2026-04-14** — Triggered the writing of this doc. Timeline:

- 00:00 PT — `auto-update.sh` (custom) fired. Ran `npm install -g openclaw@latest`, then its custom "validate bundled plugin runtime dependencies" block `cd`'d into the package dir and ran bare `npm install`, which pulled devDeps → `madge@8` vs `typescript@6` ERESOLVE → partial install → chunk hash mismatch in `dist/`.
- 00:01 — Gateway started crash-looping with `Cannot find module '/usr/lib/node_modules/openclaw/dist/monitor-polling.runtime-CfNg0sGE.js'` every 5 minutes.
- 09:00 PT — Recovery: manual `npm uninstall -g openclaw && npm install -g openclaw@latest --legacy-peer-deps`. Gateway came back.
- 09:18 PT — `auto-update.sh` rewritten to use `openclaw update --yes --channel stable --timeout 1200`. 146 lines deleted. The three flaw-blocks (custom npm install, bundled-plugin-dep installer, custom config migration) removed entirely.
- 10:11 PT — Stale-session loop discovered. `gateway-self-heal.service` was clearing session `b8b1ea5d` from `sessions.json` on every message while the gateway kept using the cached in-memory copy. Retired the entire custom self-heal stack; replaced with native `openclaw doctor --fix` on recovery paths.
