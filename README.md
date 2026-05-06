# OpenClawBS

> **A reference architecture for running a long-lived personal AI agent that remembers things, doesn't lie, and doesn't silently break — based on my real OpenClaw stack.**

This is my OpenClaw setup, stripped of personal projects and secrets, published as patterns anyone can copy. It's not a product, not a framework, not a distribution — it's a small opinionated pile of shell scripts, launchd plists, markdown files, and reasoning about why I built it this way.

If you've tried to have an AI "remember" things and watched it confidently invent facts, or wired up an agent that silently stopped working because an OAuth token expired, or burned $40 in tokens before noticing an infinite loop — this setup is a direct answer to those failures.

---

## Actual live setup (sanitized)

This is what I'm actually running, without secrets:

- **Host/runtime:** Mac mini (Apple Silicon, macOS/Darwin arm64), Node 25.9.0, OpenClaw app `2026.5.4` (kept current via explicit, manual updates only).
- **Process supervisor:** macOS `launchd` LaunchAgent (`ai.openclaw.gateway`), loopback-only bind (`127.0.0.1:18789`), not publicly exposed. Reference plist: [`launchd/ai.openclaw.gateway.plist.template`](launchd/ai.openclaw.gateway.plist.template).
- **Primary model route:** `openai-codex/gpt-5.5`, with tested fallback aliases documented locally; model switches are explicit, verified, and reversible.
- **Workspace brain:** `~/clawd` with persistent markdown memory files (`SOUL.md`, `IDENTITY.md`, `USER.md`, `AGENTS.md`, `TOOLS.md`, `MEMORY.md`, daily notes).
- **Automation:** OpenClaw AI cron jobs only when reasoning is needed; deterministic monitors run as shell/Python via system cron/launchd to avoid paying full-agent context cost for simple checks.
- **Messaging:** Telegram for actionable alerts; cron jobs default to quiet delivery unless action is needed.
- **Auth pattern:** Local-first secrets discipline: API keys/tokens stay in chmod 600 env files and are never committed. Google Workspace uses host-local OAuth via `gog`; Composio remains a useful broker/fallback for non-Google SaaS and legacy flows.


### Recent improvements folded into the live setup

These are the changes that made the stack quieter, safer, and more useful in day-to-day operation:

- **Google Workspace moved to `gog` first.** Gmail, Calendar, Drive, Docs, Sheets, People, and Tasks use host-local OAuth instead of copied tokens. Each host performs its own OAuth flow; tokens are not moved between machines.
- **Cron cost control is shell-first.** Jobs that only run a script and inspect output stay in system cron/launchd. OpenClaw AI cron jobs use light context, explicit timeouts, and quiet delivery unless action is required.
- **Cron delivery is explicit.** OpenClaw cron jobs default to `delivery.mode: none`; jobs that need to notify send one intentional chat message themselves. This avoids duplicate digest noise.
- **Beads + Asana split is cleaner.** Beads tracks agent execution locally; Asana is for human-facing work. Tasks created for a human always get an assignee instead of becoming ownerless.
- **Video delivery is now size-aware.** Small generated videos can be sent directly; larger/high-quality renders create a chat-safe preview and upload the full file to Drive with an `anyone with link` permission. No keys or Drive IDs are baked into this repo.
- **OpenClaw native-first rule is enforced.** Before adding wrappers or services, check what OpenClaw already ships. This prevents duplicating native commands with brittle custom daemons.
- **Outage-only heartbeat posture.** Routine checks stay silent. The agent only interrupts for actionable issues, failures, approvals, or time-sensitive decisions.

The Linux/VPS path that this repo originally documented still works and is preserved under [`legacy/`](legacy/) for anyone deploying on a Hetzner/OVH/DO box. See ["Where to run it"](#where-to-run-it) for the tradeoff.

---

## 🔒 SECURITY SETUP — DO THIS FIRST

**An AI agent with tool access is a privileged process.** It will hold API keys for ~24 services, run shell commands on your host, and probably talk to chat surfaces that can receive prompts from anyone. Before you install any of this, lock the box down. This is not optional.

Full playbook: **[`docs/00-security.md`](docs/00-security.md)**. Minimum viable hardening:

1. **Tailscale before you do anything else.** Don't expose SSH (or your gateway) to the public internet. Install Tailscale on your host and your laptop, get a shared tailnet, then only reach the host via the Tailscale IP (`100.x.y.z`). Free for personal use, ~5 min to set up.
2. **Move SSH off port 22.** On Linux: edit `/etc/ssh/sshd_config`: `Port 2222`. On macOS: System Settings → General → Sharing → Remote Login. Stops 99% of drive-by brute-force attempts.
3. **Kill password auth** (Linux): `PasswordAuthentication no`, `PubkeyAuthentication yes`. macOS sshd defaults to keys-only when configured via Sharing.
4. **Firewall, default-deny on inbound.** Linux: `ufw`. macOS: System Settings → Network → Firewall, set "Block all incoming connections" except the apps you allow.
5. **No public IP for OpenClaw services.** The gateway listens on `127.0.0.1` only. Anything that needs to be reachable from outside Tailscale goes through a **Cloudflare Tunnel** (`cloudflared`). Your host never advertises a public port.
6. **Secrets in chmod 600 files, never in git.** Every `.env` / env-wrapper file is mode 600, listed in `.gitignore`. The Composio API key and Telegram bot token are the two biggest disasters if leaked — treat them accordingly.
7. **Run as your user, not root** (Linux). On macOS, the LaunchAgent already runs under your user (`gui/$(id -u)`), not root.
8. **Chat-surface input is untrusted.** If your Telegram bot accepts messages from anyone, treat every incoming message as hostile input. Rate-limit it. Don't pipe message content into shell. Don't let the agent execute arbitrary code from chat without an allowlist.
9. **Backups verify themselves.** Backup crons in this repo include a preflight check + end-to-end verification — so "no alerts" genuinely means "working" instead of "failing silently."
10. **Enable automatic security patches.** macOS: System Settings → General → Software Update → Automatically install. Linux: `unattended-upgrades`.

**Do NOT install the gateway until steps 1–4 are done.** If you skip the security setup, you're putting an always-on process with broad tool access on a box exposed to the internet. That ends badly.

---

## Where to run it

> **A reference architecture you can run on a local Mac mini (the canonical path) or a cheap Linux VPS (the legacy path), depending on your threat model and budget.**

**Recommendation:** start on a Mac mini if you have one, or any other always-on macOS host. The original setup ran on a [**Hetzner Cloud CX23**](https://www.hetzner.com/cloud/) — **€3.99/mo** (~$4.50), 2 vCPU, 4 GB RAM — and that path still works (see [`legacy/`](legacy/)), but the Mac path wins once you need desktop integrations, local browser/media workflows, or your cron density gets high enough that reliability matters more than the cheapest possible VM.

### Mac mini (canonical, since 2026-04-29)

| Plan | RAM | Price | When it's right |
|------|-----|-------|-----------------|
| [**Mac Mini M4 base**](https://www.apple.com/shop/buy-mac/mac-mini) | 16 GB | $599 once (+~$3/mo power) | **Default.** OpenClaw gateway + chat alerts + browser automation + media workflows + mixed AI/shell cron load fits comfortably. |
| [Mac Mini M4 Pro](https://www.apple.com/shop/buy-mac/mac-mini) | 24-64 GB | $1,399-$4,000 once | Serious local inference (up to 70B LLM) + high-concurrency automation. |

### Linux VPS (legacy, still supported)

| Plan | RAM | Price/mo | When it's right |
|------|-----|----------|-----------------|
| [**Hetzner CX23**](https://www.hetzner.com/cloud/) | 4 GB | **€3.99** (~$4.50) | Tight budget, no need for desktop/iMessage integrations. |
| Hetzner CX33 | 8 GB | €6.49 (~$7.30) | Multi-browser automation, small database, more AI crons. |
| Hetzner CX43 | 16 GB | €11.99 (~$13.50) | 7-8B local LLM, real data storage. *Crossover with Mac mini purchase ≈ 3 years.* |

Full crossover math + sizing notes in [`docs/11-vps-sizing.md`](docs/11-vps-sizing.md).

## Install

### One-liner (canonical, macOS or Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/barkleesanders/OpenClawBS/main/install.sh | bash
```

That single line installs OpenClaw via Homebrew (macOS) if needed, clones this repo to `~/.openclaw-patterns`, seeds a fresh agent workspace at `~/clawd`, and on macOS renders the LaunchAgent + env-wrapper + env templates with your username already substituted in. **Nothing starts. No secrets are prompted, written, or transmitted.** When it finishes, it prints the remaining manual steps (fill the env file, bootstrap the LaunchAgent).

The script is **idempotent** — re-run it anytime to update. It is **non-destructive** — your existing workspace, env file, and LaunchAgent plist are left alone if they already exist.

You can also hand the one-liner to an agent (Claude Code, OpenClaw, Codex) and ask it to run + follow up. The agent has everything it needs from the printed next-steps and the repo itself.

**Override defaults** (rarely needed):

```bash
OPENCLAWBS_INSTALL_DIR=~/code/OpenClawBS \
OPENCLAWBS_WORKSPACE=~/myagent \
curl -fsSL https://raw.githubusercontent.com/barkleesanders/OpenClawBS/main/install.sh | bash
```

Read the script before running if you're cautious — it's [under 200 lines](install.sh) and does exactly what's documented above.

### Manual install (if you'd rather see the steps)

- **macOS / launchd** — full walkthrough: [`launchd/README.md`](launchd/README.md)
- **Linux / systemd** — `curl -fsSL https://raw.githubusercontent.com/barkleesanders/OpenClawBS/main/legacy/scripts/install/quick-install.sh | bash` (full walkthrough: [`legacy/README.md`](legacy/README.md))

---

## Why this way of thinking matters (the whole point)

LLM agents fail in three predictable ways when you run them long-term. This setup is designed to make each one structurally impossible, not just rare.

### Failure 1: The AI lies that it's done

You ask an agent to "fix the build and ship it." It runs `npm test`, most tests pass, it declares success. In reality three tests were skipped, two failed silently, and the deploy never happened. The agent is genuinely unsure, but the fastest path through its reward function is to say "done."

**The fix here: a Stop hook.** Before the AI can end its turn, a shell script runs and checks whether the claimed work actually happened — pending tasks exist? tests failing? files were edited but never saved? If the hook returns non-zero, the AI is forced to keep working. It can't just say "done"; something external has to confirm done.

See [`claude-code/hooks/taskmaster-check-completion.sh`](claude-code/hooks/taskmaster-check-completion.sh). The pattern is: **outside process verifies inside claims.**

### Failure 2: The AI forgets across sessions

Every session starts with no memory. You can pour context into the prompt, but you hit the 200K-token ceiling, and the AI starts hallucinating once summarization kicks in. Worse, what the AI *wrote down* in-session disappears when the session ends.

**The fix here: files on disk are the source of truth; session context is disposable.**

- `SOUL.md` — who the agent is (principles, personality, continuity)
- `IDENTITY.md` — agent identity context (handles, public-facing voice, tone)
- `USER.md` — who you are (name, timezone, preferences)
- `AGENTS.md` — how the agent operates (rules for this workspace)
- `TOOLS.md` — local infrastructure notes (your SSH hosts, device names, APIs)
- `MEMORY.md` — curated long-term memories, indexed by typed files (`feedback_*.md`, `project_*.md`, `reference_*.md`)
- `memory/YYYY-MM-DD.md` — daily raw notes, like a journal

Every session the agent reads these first. When something new happens worth remembering, it writes to the right file. The ephemeral session dies; the files remain. This is the same pattern humans use: short-term working memory + long-term storage. See [`workspace/`](workspace/) for the templates.

### Failure 3: The AI silently dies in production

OAuth tokens expire. RAM creeps up. Background jobs accumulate zombies. None of these crash the system loudly — they slowly degrade it until something important stops working and nobody notices for days.

**The fix here: three layers of defense.**

1. **Brokered or host-local OAuth** ([`docs/04-composio-first-auth.md`](docs/04-composio-first-auth.md)): avoid hand-rolled refresh logic. Use a broker like Composio for SaaS integrations, or a host-local CLI like `gog` for Google Workspace. Never copy OAuth tokens between machines.
2. **Memory guardian (Linux only)** ([`legacy/scripts/memory-guardian.sh`](legacy/scripts/memory-guardian.sh)): a 5-minute cron that checks RSS, available RAM, and disk growth, and proactively restarts the gateway via `systemctl` before the kernel OOM killer fires. **macOS doesn't need this** — launchd respawns crashed processes cleanly and the M-series memory pressure handling is gentler than Linux's. Pattern is preserved for the VPS path.
3. **Rich failure alerts** ([`scripts/lib/alert.sh`](scripts/lib/alert.sh)): when a cron fails, the Telegram message includes severity, step, UTC time, runtime, the actual error, and the last 5 log lines. So when you wake up, you already know where to look.

---

## The tools and why they're here (plain English)

### Ghidra — the "it's a blob and I don't trust docs" tool

[Ghidra](https://ghidra-sre.org/) is a reverse-engineering suite from the NSA (yes, really). Normally used for malware analysis. Here it's used occasionally when a service's API is undocumented and scraping the UI is unreliable — you download the service's mobile app, open it in Ghidra, find the private API endpoints, then call them directly.

**Why this matters:** most AI-browser-automation pipelines are fragile because they re-scrape a website every time. If you reverse-engineer the underlying API once, you never scrape again. One afternoon of Ghidra work replaces weeks of broken Playwright scripts. It's only needed occasionally, but when you need it, nothing else works as well.

### Unbrowse — the "stop scraping the same page every cron run" tool

Unbrowse is an agent browser that learns the shadow APIs a website calls under the hood. First time your agent visits a page, Unbrowse records every XHR. After ~3 runs, it caches the API routes and stops rendering the HTML entirely — just hits the JSON endpoints directly.

**Why this matters:** browser rendering burns ~3 seconds and ~200 MB of RAM per page load. Multiply by hourly cron jobs, and a small VPS drowns. Unbrowse progressively replaces browser calls with <2ms cached API hits. Same result, 1000× cheaper.

### CLI tools as first-class agent surfaces

Every service you talk to a lot should have a CLI wrapper. Not because the AI needs it — because **the CLI is deterministic, testable, and cheap**. When the AI needs to check Linear issues, it should shell out to `linear-cli list` rather than fumbling through a web UI or even an MCP server.

The pattern: **shell > Python > AI session**. Shell is free and fast. Python is cheap and flexible. An AI session costs ~$0.19 and has non-determinism built in. Use the cheapest thing that works.

### Cron jobs as autonomous mini-agents

A cron job is not automatically an AI session. Some jobs are mini-agents that wake up, read context, decide, act, and go back to sleep. Others are pure shell checks that should never pay the cost of a full model turn. Shell/Python jobs live in system cron or launchd; genuine reasoning jobs live in `openclaw cron`.

The discipline: **every cron has a timeout, logs enough evidence to debug, and only alerts when action is needed.** Failures never go unnoticed. Successes stay quiet.

See [`scripts/templates/cron-wrapper.sh`](scripts/templates/cron-wrapper.sh) — a wrapper that adds locking, timeout, alerting, and log rotation to any cron line.

### Stop hook — the "you're not done yet" enforcer

When an AI session tries to end, a `Stop` hook runs. It's just a shell script. If it exits 0, the session ends. If it exits non-zero, the AI is forced to continue with an error message.

My Stop hook checks:
- Any pending tasks in beads still open? → not done
- Any recent tool errors unresolved? → not done
- Did the AI explicitly address the user's request? → if not, not done

**This is the single most important pattern for preventing "AI said it was done but lied."** The AI can't unilaterally decide it's finished. See [`claude-code/hooks/taskmaster-check-completion.sh`](claude-code/hooks/taskmaster-check-completion.sh). On the live system this lives at `~/.claude/skills/taskmaster/hooks/check-completion.sh` — keeping it under a skill directory means it gets indexed by the skill loader and stays versioned with the skill.

### Prompts as source-of-truth, not context-filler

Most AI setups pour everything into the prompt and hope. This setup does the opposite: **the prompt points to files; the files are the truth.**

When a Claude Code session starts, it's told:
- "Read AGENTS.md first — that's your operating rules"
- "Read MEMORY.md — that's your long-term memory index"
- "Check recent memory files before asserting facts"

The prompt is short. The knowledge lives in files. You can update a fact once (edit the file) instead of re-teaching it every session. And because files can have frontmatter timestamps, old facts get marked stale automatically instead of persisting as hallucinations.

### Beads — the "what are we actually doing" tracker

[Beads](https://github.com/steveyegge/beads) is a local-first task tracker (like GitHub issues but for your own work). Instead of `TodoWrite` which lives only in-session, beads stores tasks in a SQLite DB that survives everything.

Workflow:
- Before coding: `bd create --title="Fix the thing" --type=bug --priority=2`
- Starting: `bd update <id> --claim`
- Done: `bd close <id>`
- Find work: `bd ready`

Why: the Stop hook checks beads for unresolved tasks before letting the AI end. This closes the loop — the AI can't declare completion while tasks are still open. Tasks are structured enough that a shell script can verify them, which is exactly what the hook does.

### Source-of-truth discipline = token savings

Because files on disk are canonical, you don't need to keep re-explaining things to the AI. A typical failure mode is: "let me remind you that our codebase uses X, Y, Z..." — paying 3K tokens every session to re-teach facts that should be persistent.

With this setup, those facts live in `AGENTS.md` / `TOOLS.md` / `MEMORY.md` / `feedback_*.md`. Each file is ~150-500 tokens. Loaded once at session start. Free for the rest of the session. And they're editable — when reality changes, one file edit fixes every future session.

Rough math on a 6-month old project: without this pattern, ~40% of every session is re-establishing context. With it, ~5%. On a daily-AI-use setup, that's real money.

---

## The three-layer architecture

```
[ Your laptop ]              [ OpenClaw host (Mac mini canonical, VPS legacy) ]   [ Composio ]
 Claude Code                 OpenClaw gateway (Node, launchd or systemd)          auth broker
 skills, agents,        ⇄    cron agents, workspace,                         ⇄    24+ services
 hooks, memory               Telegram bot, alerts                                 auto-refreshed tokens
```

- **Laptop (Claude Code)** does heavy reasoning, skill composition, code editing
- **OpenClaw host** is the always-on brain — crons run, memory persists, Telegram bot replies
  - **Mac mini path:** `launchd` LaunchAgent supervises the gateway; `openclaw cron` handles reasoning work; system `crontab`/launchd handles deterministic shell jobs; browser, media, Drive, and desktop workflows run locally.
  - **Linux VPS path (legacy):** systemd unit supervises the gateway; `memory-guardian.sh` watchdogs OOM; otherwise identical.
- **OAuth/tool brokers** provide service access without committing secrets: `gog` for Google Workspace on the host; Composio or service-specific CLIs for other SaaS.

Each layer has exactly one job. Simple enough to reason about; resilient because failures in one layer don't cascade.

---

## The patterns, one sentence each

1. **Workspace-as-brain** — Fixed markdown files (SOUL/IDENTITY/USER/AGENTS/TOOLS/MEMORY) are the agent's persistent home. ([`docs/03-workspace.md`](docs/03-workspace.md))
2. **OAuth without token copying** — Prefer host-local or brokered OAuth; never commit or move raw tokens between machines. ([`docs/04-composio-first-auth.md`](docs/04-composio-first-auth.md))
3. **Memory guardian (Linux only)** — 5-minute OOM watchdog with proactive systemd restart + Telegram alerts. ([`legacy/docs/05-memory-guardian.md`](legacy/docs/05-memory-guardian.md))
4. **Shell-first crons** — AI sessions are expensive; use shell/Python first, AI only when genuine reasoning is needed. ([`docs/06-shell-first-crons.md`](docs/06-shell-first-crons.md))
5. **Actionable failure alerts** — Alert only on failures or decisions, with severity, step, time, runtime, error detail, and log tail. ([`docs/07-telegram-alerts.md`](docs/07-telegram-alerts.md))
6. **OpenClaw native-first** — Before any custom script, cron, or service unit, check what `openclaw` does natively. Custom wrappers are last resort. ([`docs/12-openclaw-native-first.md`](docs/12-openclaw-native-first.md))

---

## Repo layout

```
docs/              — Philosophy & architecture essays (the "why")
workspace/         — Markdown templates for the agent's home directory
launchd/           — macOS LaunchAgent + env-wrapper templates (canonical deployment)
scripts/           — Cross-platform shell: Drive upload, alert, backup/cron templates
  lib/             — alert.sh, composio-token.sh (sourceable helpers)
  templates/       — backup-template.sh, cron-wrapper.sh (fork + fill in)
  composio-drive.sh — Upload files to Drive through a configured OAuth path (template; no secrets committed)
claude-code/       — Laptop-side: hooks, CLAUDE.md sections, agent/skill patterns
examples/          — End-to-end walkthroughs
records-monitor/   — NextRequest CPRA/FOIA document watcher + Drive uploader + gap analysis
beads-sync/        — Two-host beads task database sync script (host-agnostic)
openclaw-config/   — HARD_RULES.md (agent operating rules) + cron job templates
legacy/            — Linux/VPS deployment patterns (systemd unit, quick-install.sh, memory-guardian.sh)
.env.example       — Template for all required secrets (copy to .env, never commit .env)
```

Every file in `scripts/`, `launchd/`, `legacy/`, `records-monitor/` is either runnable as-is or a template you fill in. No personal values are baked in — all secrets are replaced with `YOUR_*` placeholders.

---

## What this isn't

- **Not a product.** No installer (well, two opt-in ones), no support, no guarantees.
- **Not production-grade security.** Threat model: "host I run alone." Shared infra? Add hardening.
- **Not opinionated about the AI backend.** Works with whatever model OpenClaw runs.
- **Not a replacement for [OpenClaw](https://github.com/openclaw/openclaw).** OpenClaw is the runtime; this is the config around it.

## How to adopt piecewise

**Start with security** → [`docs/00-security.md`](docs/00-security.md) is step one, regardless of which patterns you end up using. Don't skip it.

Then pick any of these patterns; they're independent:

- **Resilient Drive backup** → [`scripts/composio-drive.sh`](scripts/composio-drive.sh) + [`scripts/templates/backup-template.sh`](scripts/templates/backup-template.sh) + [`scripts/lib/alert.sh`](scripts/lib/alert.sh)
- **OOM prevention on small VPS (Linux)** → [`legacy/scripts/memory-guardian.sh`](legacy/scripts/memory-guardian.sh) — works with any systemd service
- **Typed persistent memory for a different agent** → [`workspace/`](workspace/) structure — applies to any runtime
- **Stop-hook gate for Claude Code** → [`claude-code/hooks/`](claude-code/hooks/)
- **Autonomous CPRA/FOIA document management** → [`records-monitor/`](records-monitor/) — polls NextRequest, downloads docs, uploads to Drive, analyzes gaps, drafts deficiency letters
- **Two-host task sync** → [`beads-sync/`](beads-sync/) — keeps beads tasks in sync across two hosts via Tailscale SSH
- **Agent operating rules** → [`openclaw-config/HARD_RULES.md`](openclaw-config/HARD_RULES.md) — beads tracking, Telegram discipline, safety gates
- **Mac mini full setup** → Read [`docs/00-security.md`](docs/00-security.md) first, then [`launchd/README.md`](launchd/README.md)
- **Linux VPS full setup** → Read [`docs/00-security.md`](docs/00-security.md) first, then [`legacy/README.md`](legacy/README.md)

## License

MIT. Do whatever.

## Related

- [Composio](https://composio.dev) — useful brokered OAuth layer for SaaS integrations
- [Beads](https://github.com/steveyegge/beads) — the task tracker the Stop hook uses
- [Ghidra](https://ghidra-sre.org/) — when you need to reverse-engineer an undocumented API
- [OpenClaw](https://github.com/openclaw/openclaw) — the underlying runtime this setup configures ([npm](https://www.npmjs.com/package/openclaw))
- Claude Code — Anthropic's CLI, layer 1 of the stack
