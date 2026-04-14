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

## Reference implementation

The two thin wrappers we *do* keep (both follow the rule — they delegate to `openclaw update` and only add a rollback path OpenClaw doesn't ship):

| File | What it does |
|---|---|
| [`scripts/templates/openclaw-auto-update.sh`](../scripts/templates/openclaw-auto-update.sh) | Daily update wrapper. Snapshots `/usr/lib/node_modules/openclaw`, calls `openclaw update --yes --channel stable --timeout 1200`, runs a post-update health gate (port listening + journal clean of `ERR_MODULE_NOT_FOUND` / `Config invalid`), rolls back from snapshot on failure, notifies Telegram out-of-band. |
| [`scripts/templates/openclaw-integrity-check.sh`](../scripts/templates/openclaw-integrity-check.sh) | `ExecStartPre` guard on `openclaw-gateway.service`. Enumerates runtime-*.js chunks referenced by `dist/` entry files; if any are missing on disk, restores from the most recent snapshot before the gateway starts. |
| [`scripts/templates/openclaw-integrity.conf`](../scripts/templates/openclaw-integrity.conf) | systemd drop-in that wires the integrity check in without editing the main unit file. |

Everything else (package install, plugin sync, config migration, gateway restart, doctor checks, stale-session recovery, cron session management, channel setup, model auth rotation) is delegated to OpenClaw's native commands. See [`scripts/templates/README.md`](../scripts/templates/README.md) for install instructions.

## Enforcement in this repo

- This document (`docs/12-openclaw-native-first.md`) is linked from `README.md`
- `claude-code/CLAUDE.md.sanitized` references this rule under "Operating OpenClaw"
- Any PR that adds a shell wrapper, cron, or systemd unit touching OpenClaw must justify why `openclaw <thing>` doesn't work first

## Incident record

**2026-04-14** — Triggered the writing of this doc. Full timeline:

- **00:01 PT** — `auto-update.sh` (custom, pre-rewrite) fired. Ran `npm install -g openclaw@latest`, then its custom "validate bundled plugin runtime dependencies" block `cd`'d into the package dir and ran bare `npm install`, which pulled devDeps → `madge@8` vs `typescript@6` ERESOLVE → partial install → chunk hash mismatch in `dist/`.
- **00:01–09:00 PT** — Gateway crash-looped with `Cannot find module '/usr/lib/node_modules/openclaw/dist/monitor-polling.runtime-CfNg0sGE.js'` every ~5 minutes. Telegram bot unresponsive for 9 hours.
- **09:00 PT** — Recovery: `systemctl stop openclaw-gateway; pkill -9 -f chrome; npm uninstall -g openclaw; npm cache clean --force; npm install -g openclaw@latest --legacy-peer-deps; systemctl start openclaw-gateway`. Gateway back on 2026.4.14.
- **09:05 PT** — First hardening pass: snapshot+rollback+health-gate layer added around the existing (still-flawed) auto-update.sh. Integrity guard (`openclaw-integrity-check.sh` as `ExecStartPre`) installed. Tested the guard by moving a runtime chunk aside and restarting — it restored from snapshot in 10 seconds.
- **09:18 PT** — Auto-update.sh rewritten to use `openclaw update --yes --channel stable --timeout 1200`. **−146 lines (−38%)**. Three flaw-blocks removed entirely: (1) raw `npm install -g openclaw@latest`, (2) "Ensuring bundled plugin runtime dependencies" (force-installed grammy/slack/bedrock into `OPENCLAW_DIR`), (3) "Validating dependencies" (the one that ran `npm install` inside `OPENCLAW_DIR` and caused the ERESOLVE), (4) custom "Unrecognized key" config migration — all deferred to `openclaw update`'s built-in plugin-sync and doctor steps.
- **10:11 PT** — Stale-session loop discovered. Real error: Claude CLI returned `No conversation found with session ID: b8b1ea5d-3ede-47f3-ae1b-c28529690a54` on every user message. `gateway-self-heal.service` (custom) was parsing the journal, calling `clear-stale-session.sh` (custom recursive `sessions.json` walker), and sending Telegram `🔁 self-heal: cleared stale session b8b1ea5d — user can retry` on each turn. The bad ID was already gone from disk — but the gateway had it cached in memory, and the custom stack never cleared the cache, only notified.
- **10:27–10:41 PT** — Retired the custom self-heal stack: `gateway-self-heal.service` + `session-watcher.service` + `gateway-self-heal.sh` + `clear-stale-session.sh` + the hardcoded Telegram bot token in the script. All files moved to `/root/.openclaw/retired-self-heal-<timestamp>/` for a rollback window. `openclaw gateway restart` cleared the in-memory cache. `openclaw doctor --fix --non-interactive` ran clean. Two successful `cli exec` calls in the verification window with zero errors.
- **10:45 PT onward** — Every recovery path now routes through `openclaw update` / `openclaw doctor` / `openclaw gateway restart`. The only custom code that remains is the rollback shell around `openclaw update` and the `ExecStartPre` integrity guard — both of which fill genuine gaps OpenClaw doesn't cover natively, and both are documented as reference implementations in `scripts/templates/`.

### Net result

| | Before (2026-04-14 00:00) | After (2026-04-14 10:45) |
|---|---|---|
| `auto-update.sh` length | 383 lines | 237 lines |
| Custom systemd services | `openclaw-gateway`, `gateway-self-heal`, `session-watcher` | `openclaw-gateway` only |
| Custom shell scripts touching OpenClaw state | 6 | 2 (auto-update, integrity-check) |
| Hardcoded Telegram bot tokens | 1 (in self-heal fallback) | 0 |
| Commands re-implementing native openclaw | `update`, `doctor`, plugin-install, session-clear, config-migration | none |
| Rollback story when an update fails | none | snapshot + health gate + Telegram alert |

The custom code that survived exists solely to add *rollback* around `openclaw update`. Every other responsibility is delegated to `openclaw` itself.
