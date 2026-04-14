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
| Seed a bearer setup-token non-interactively | `printf "$TOKEN\r" \| openclaw models auth paste-token --provider anthropic --profile-id anthropic:oauth` (see 2026-04-14 entry for why `\r` not `\n`) |
| Set the default model | `openclaw models set <provider>/<model>` |
| Model invocation (long-running installs) | Prefer `anthropic/*` provider + `anthropic:oauth` (setup-token) over `claude-cli/*`. The direct-API path uses the Anthropic SDK with `Bearer` auth + `claude-code-20250219` + `oauth-2025-04-20` beta headers — Hermes pattern, no subprocess, no `--resume` / `--session-id` bug surface. |
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
- **Custom wrapper at `/usr/local/bin/<tool>` shadowing the npm-installed binary.** You will forget it exists within 60 days and spend a day debugging a ghost. `/usr/local/bin` precedes `/usr/bin` on every Debian-family box, so the wrapper intercepts every shell-level invocation while the service that calls the tool via its own resolution path sails past the wrapper — leaving your tests green and prod silently broken, or vice-versa.

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
- **10:49 PT** — Telegram bot still replying "⚠️ Something went wrong while processing your request." Root cause: a **second** custom bandaid that the earlier sweep missed. `/usr/local/bin/claude` was a 1152-byte bash wrapper (v2) that intercepted `--resume <id>` and `--session-id <id>` flags and stripped them if the matching `{id}.jsonl` was missing under `/root/.claude/projects/`. Its companion `/usr/local/bin/claude-real` was an 89-byte shell shim that exec'd `node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js`. The wrapper was **dead code for direct gateway calls** — OpenClaw's CLI provider spawns claude through Node's own resolution path, which landed on the npm-symlinked `/usr/bin/claude` either way — but it was **actively wrong for any script invoking `claude` via $PATH**, silently converting an attempted `--resume` into a brand-new session and logging the strip to `/root/.openclaw/logs/claude-wrapper.log`. The wrapper log captured the smoking gun: `STRIPPED: --resume=f6613253 | orig_args: --resume f6613253-fcc4-4c33-9570-23da5e7464de --print hi` at 10:51:16 PT. Separately, `agent:main:main.cliSessionBindings['claude-cli'].sessionId` held a ghost id (`f6613253-fcc4-4c33-9570-23da5e7464de`) with no matching jsonl; the gateway kept passing that ghost id on every user turn, producing Claude's native `No conversation found with session ID: …` error, which bubbled up as "Something went wrong" in Telegram.
- **11:00–11:02 PT** — Retired both files to `/root/.openclaw/retired-claude-wrapper-20260414-110102/` (`claude.wrapper`, `claude-real.copy`, plus a README and a snapshot of the wrapper log for forensics). `/usr/bin/claude` and `/bin/claude` remain as symlinks to `/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js` (md5 `348c4a9cf0a6d1337c4b36e9bf3d8ed1`, Claude Code 2.1.104). `which claude` now returns `/usr/bin/claude`. The stale `cliSessionBinding` self-corrected on the next turn: OpenClaw's cli-provider attempts `--resume`, claude-code's native behavior returns `No conversation found`, the provider promotes to `--session-id <new-uuid>` which creates a fresh session and writes the jsonl. The updated binding (`576f17ce-8727-4867-8f80-b298cfbb96ec`) has a matching jsonl on disk. No manual surgery on `sessions.json` was needed — `openclaw gateway restart` + `openclaw health` confirmed clean state. `openclaw sessions reset` does not exist as a subcommand (checked); the closest native clear path remains `openclaw doctor --fix --non-interactive`, which was not required this round.

### Why the previous sweep missed it

The earlier "native-first" cleanup only inspected `/root/.openclaw/scripts/`, `/etc/systemd/system/`, and root's crontab — all the places where custom *OpenClaw* bandaids live. The claude wrapper lived in `/usr/local/bin/`, one level of abstraction removed: a custom wrapper around the *CLI provider* that OpenClaw delegates inference to. The lesson: when auditing for custom wrappers, audit the whole `/usr/local/bin/` and `/usr/local/sbin/` tree for shadow-binaries of anything on the critical path, not just the application whose name you're chasing.

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

**2026-04-14 (follow-up sweep, 11:22–11:40 PT)** — Completed the remaining shadow-wrapper retirement and performed the exhaustive `/usr/local/bin`, `/usr/local/sbin`, `/etc/systemd/system`, `/root/.openclaw`, and `/root/clawd/scripts` audit that earlier sessions had only sampled.

Retired in this sweep:

- `/usr/local/bin/openclaw` — 111 B bash wrapper (`export TZ=America/Los_Angeles; exec /usr/bin/node /usr/lib/node_modules/openclaw/dist/entry.js`) shadowing the native `/usr/bin/openclaw` npm symlink. The TZ export was a no-op (system timezone already `America/Los_Angeles` per `timedatectl` and `/etc/timezone`), and the entry path (`dist/entry.js`) was stale — the real entry is `openclaw.mjs`. Systemd never reached the wrapper because the unit uses absolute `/usr/bin/openclaw`.
- `/usr/local/bin/openclaw-pst` — 70 B alias of the same TZ-export pattern wrapping `/usr/bin/openclaw` directly. Same redundancy.
- `/usr/local/bin/switch-model` — symlink pointing at a missing target (`/root/.openclaw/scripts/switch-model.sh`). Dead code. Native replacement: `openclaw models` / `openclaw models auth`.
- `/root/clawd/scripts/openclaw-watchdog.sh` (+ `.bak`) — re-implemented gateway health polling. Last log line 2026-03-21; no longer in crontab (active watchdog is `telegram-watchdog.sh`, which is scoped to Telegram connectivity). Native replacement: `openclaw doctor` plus systemd `Restart=always`.
- `/root/clawd/scripts/openclaw-rescue.sh` — config backup/restore. Only called by the retired `openclaw-watchdog.sh.bak`. Native replacement: `openclaw doctor --repair` / `--force`.
- `/root/clawd/scripts/upgrade-openclaw.sh` — re-implemented `openclaw update`. Zero active references. Native replacement: `openclaw update` (already wrapped by the thin `auto-update.sh`).
- `/root/clawd/scripts/check-openclaw-update.sh` — re-implemented `openclaw update --dry-run` via raw npm registry HTTP. Zero references. Its comment ("no npm CLI needed — it's broken on this box") was a stale 2026-03 artifact; npm is fine now.
- `/root/clawd/scripts/pre-upgrade-backup.sh` — only called by the retired `upgrade-openclaw.sh`. Orphan.
- `/etc/systemd/system/openclaw-gateway.service.d/env.conf.backup-20260202-175734` — 67 B stale drop-in backup containing `Environment="ANTHROPIC_API_KEY=sk-ant-proxy-placeholder"` from the pre-sandbox proxy architecture. Not loaded by systemd (verified via `DropInPaths`) but a footgun — a rename to `.conf` would silently activate it.
- `/etc/systemd/system/openclaw-gateway.service.d/env.conf.bak-20260412-160317` — 133 B stale drop-in backup missing the `EnvironmentFile=` line that loads `/root/.openclaw/.env`. Also not loaded but another footgun in the same directory.

Timezone drop-in decision: **not needed**. `timedatectl` shows `America/Los_Angeles`, `/etc/timezone` agrees, and the crontab sets `TZ=America/Los_Angeles` explicitly. The retired wrappers' `export TZ=…` was a no-op.

All retirements moved to `/root/.openclaw/retired-shadow-wrappers-20260414-112230/` (with `phase5-clawd-scripts/` and `phase5-systemd-stale-backups/` subdirs), each with a README documenting rationale and rollback path. No systemd reload or gateway restart was needed — nothing still-loaded was touched.

Post-sweep verification: `systemctl is-active openclaw-gateway` → `active`; `openclaw health` → `telegram: ok (@bsclaudebot) (330ms)`; 2-minute journal scan for `ERR_|No conversation|Fail|error` → zero matches; Telegram out-of-band notification delivered (`message_id: 8737`).

Out-of-scope flag: `/usr/local/bin/node-pst` (70 B) wraps `node` with the same LA-timezone export. Not an openclaw shadow, so out of scope for this rule. Candidate for a future general-cleanup pass if TZ inheritance ever becomes relevant.

### Updated net result (2026-04-14 11:40 PT)

| | Before (2026-04-14 00:00) | After first sweep (10:45) | After follow-up sweep (11:40) |
|---|---|---|---|
| `auto-update.sh` length | 383 lines | 237 lines | 237 lines |
| Custom systemd services | `openclaw-gateway`, `gateway-self-heal`, `session-watcher` | `openclaw-gateway` only | `openclaw-gateway` only |
| Custom shell scripts touching OpenClaw state | 6 | 2 | **2** (`auto-update.sh`, `openclaw-integrity-check.sh`) |
| `/usr/local/bin` openclaw-shadowing wrappers | 3 (`openclaw`, `openclaw-pst`, `switch-model`) | 3 (still present) | **0** |
| Stale drop-in `.bak` files in `*.service.d/` | 2 | 2 | **0** |
| Orphan openclaw-flavored scripts in `/root/clawd/scripts` | 5 (`openclaw-watchdog.sh(+ .bak)`, `openclaw-rescue.sh`, `upgrade-openclaw.sh`, `check-openclaw-update.sh`, `pre-upgrade-backup.sh`) | 5 (still present) | **0** |
| Hardcoded Telegram bot tokens in openclaw helpers | 1 | 0 | 0 |

Net state after this sweep: **exactly two custom shell wrappers** remain, both documented as reference implementations in [`scripts/templates/`](../scripts/templates/) — `openclaw-auto-update.sh` (snapshot+rollback around `openclaw update`) and `openclaw-integrity-check.sh` (ExecStartPre runtime-chunk guard). Everything else is either native `openclaw` or unrelated to OpenClaw.

**2026-04-14 (structural fix, 13:51–13:55 PT)** — The wrapper retirement at 11:00 exposed the deeper bug it had been masking. The real failure class was **OpenClaw's CLI provider passes `--resume <fresh-uuid>` on the first message of every rotated session**, expecting `claude --resume` to auto-create the jsonl. Claude Code 2.1.104 rejects that: `--resume` requires an existing transcript, `--session-id` creates a fresh one. Behavior verified directly on the VPS:

- `claude --resume <fresh-uuid> --print hi` → `No conversation found with session ID: <uuid>` (exit 1)
- `claude --session-id <fresh-uuid> --print hi` → `Hi! How can I help you today?` (exit 0)

The retired `/usr/local/bin/claude` wrapper had been silently *masking* this by stripping `--resume` when the corresponding jsonl was missing, converting it into a new session. Removing the wrapper at 11:00 exposed the upstream contract mismatch — every Telegram turn emitted the native `No conversation found` error → gateway → `⚠️ Something went wrong while processing your request.` for the rest of the day.

The structural fix is **eliminating the subprocess path entirely** — following the [Hermes Agent](https://github.com/nousresearch/hermes-agent) reference: read the Claude Code OAuth access token, call `https://api.anthropic.com/v1/messages` directly via the Anthropic SDK with `Bearer <token>` + `anthropic-beta: claude-code-20250219,oauth-2025-04-20` headers. No `claude` binary, no `--resume` vs `--session-id`, no jsonl on disk.

OpenClaw 2026.4.14 already ships this path natively as the `setup-token` auth method on the bundled `@openclaw/anthropic-provider` plugin (`/usr/lib/node_modules/openclaw/dist/extensions/anthropic/`). It is not surfaced in `openclaw.plugin.json` (which only advertises `cli` and `api-key`) but is fully registered at runtime (`register.runtime-B5HGf6Xw.js` lines 280–297). Token validation: must start with `sk-ant-oat01-` and be ≥80 chars — the Claude CLI's `accessToken` at `/root/.claude/.credentials.json` already fits. The OAuth beta headers are already embedded in `stream-wrappers-PlFj0B1V.js` lines 14–17.

Migration (all native, no JSON surgery on the auth profiles):

1. Backed up `openclaw.json` and `auth-profiles.json` with a timestamp suffix.
2. `printf "$TOKEN\r" | openclaw models auth paste-token --provider anthropic --profile-id anthropic:oauth`
   - `\n` alone does NOT submit — `@clack/prompts` reads stdin in raw mode, one char at a time, and needs `\r` (carriage return) as the Enter keypress.
   - Produced: `{ type: "token", provider: "anthropic", token: "sk-ant-oat01-..." }` in `auth-profiles.json`, plus a matching `anthropic:oauth -> { provider: "anthropic", mode: "token" }` entry in `openclaw.json`'s `auth.profiles`.
3. `openclaw models set anthropic/claude-sonnet-4-6`
4. A minimal `agents.defaults.models` map update (Python one-shot, not hand-edit) to move the `Sonnet 4.6`/`Opus 4.6` aliases and `cacheRetention: short` params from their `claude-cli/*` keys onto the `anthropic/*` keys, removing the stale `claude-cli/*` entries. Configured `fallbacks: ["claude-cli/claude-sonnet-4-6"]` so the old path stays available for rollback.
5. `systemctl restart openclaw-gateway` — gateway came up in 8 s with `[gateway] agent model: anthropic/claude-sonnet-4-6`.
6. Direct API smoke test with the Hermes headers: `HTTP 200` from `api.anthropic.com/v1/messages`, returned `OPENCLAW_MIGRATION_OK`.
7. `openclaw models status` shows `anthropic usage: 5h 89% left` — the OAuth usage quota endpoint is reachable, so the Bearer+beta path is live.

Why `\r` and not `\n`: `openclaw models auth paste-token` runs `text()` from `@clack/prompts`, which puts stdin into raw mode (each char redraws the TUI) and treats `\r` as the submit signal. Piping `\n` leaves the prompt waiting forever. Documented here because the first attempt silently hung for 10 s and wrote nothing — a footgun for anyone scripting the same migration.

**Before / after:**

| | Before (13:40 PT) | After (13:55 PT) |
|---|---|---|
| `agents.defaults.model.primary` | `claude-cli/claude-sonnet-4-6` | `anthropic/claude-sonnet-4-6` |
| `agents.defaults.model.fallbacks` | `[]` | `["claude-cli/claude-sonnet-4-6"]` |
| Invocation path | spawn `claude --resume <uuid>` as subprocess | HTTPS POST `api.anthropic.com/v1/messages` with `Bearer` + `oauth-2025-04-20` |
| Error class possible | `No conversation found with session ID: <uuid>` → Telegram `⚠️ Something went wrong` | Not representable — there is no `--resume` flag in the request shape |
| `auth-profiles.json` | `anthropic:claude-cli` (OAuth, method=claude-cli) | `anthropic:claude-cli` (preserved) + `anthropic:oauth` (token=sk-ant-oat01-..., method=setup-token) |
| Cron jobs (`/root/.openclaw/cron/jobs.json`) | already referenced `anthropic/*` models (44 refs, 0 `claude-cli/*`) | unchanged — zero cron migration needed |
| Subprocess count during a Telegram turn | 1 (`node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js`) | 0 |

**Residual concerns:**

- **Access token expires in ~4 h.** OpenClaw's `type: "token"` credential format does not carry a refresh token, and Claude CLI refreshes its access token on its own schedule at `/root/.claude/.credentials.json`. Short-term: if the anthropic:oauth profile expires, the configured fallback `claude-cli/claude-sonnet-4-6` takes over (the subprocess path with its known bug surface). Longer-term fix: a re-seed cron that runs `printf "$(jq -r .claudeAiOauth.accessToken /root/.claude/.credentials.json)\r" | openclaw models auth paste-token --provider anthropic --profile-id anthropic:oauth` nightly. Not in place yet — flagged for follow-up.
- `openclaw models status --probe --probe-provider anthropic` returned `unknown · 10s ↳ Context engine "lossless-claw" factory returned an invalid ContextEngine: info.id must match registered id "lossless-claw".` — a probe-harness bug in the `lossless-claw` plugin's factory check, unrelated to the anthropic API auth. Direct API test (`curl` with the same token) returned HTTP 200 with a valid completion, confirming the token + headers path works. Worth filing upstream as a probe issue separately.
- `agents.defaults.models` no longer lists the `claude-cli/claude-opus-4-5`, `claude-cli/claude-sonnet-4-5`, `claude-cli/claude-haiku-4-5` entries. They had no `anthropic/*` equivalent migrated because the provider config in `openclaw.json` only lists `claude-sonnet-4-6` and `claude-haiku-4-5` under `models.providers.anthropic.models`. If we ever want `Sonnet 4.5` or `Haiku 4.5` aliases back, either add the model entries to `models.providers.anthropic.models` in `openclaw.json` or restore from the timestamped `.bak` files.
