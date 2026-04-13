# OpenClawBS

**A reference architecture for running a long-lived personal AI agent that remembers things, doesn't lie, doesn't silently break, and fits on a $5 VPS.**

This is my OpenClaw setup, stripped of personal projects and secrets, published as patterns anyone can copy. It's not a product, not a framework, not a distribution — it's a small opinionated pile of shell scripts, systemd units, markdown files, and reasoning about why I built it this way.

If you've tried to have an AI "remember" things and watched it confidently invent facts, or wired up an agent that silently stopped working because an OAuth token expired, or burned $40 in tokens before noticing an infinite loop — this setup is a direct answer to those failures.

---

## 🔒 SECURITY SETUP — DO THIS FIRST

**An AI agent with tool access is a privileged process.** It will hold API keys for ~24 services, run shell commands on your VPS, and probably talk to chat surfaces that can receive prompts from anyone. Before you install any of this, lock the server down. This is not optional.

Full playbook: **[`docs/00-security.md`](docs/00-security.md)**. Minimum viable hardening (30 min, free):

1. **Tailscale before you do anything else.** Do not expose SSH to the public internet. Install Tailscale on the VPS and your laptop, get a shared tailnet, then only SSH via the Tailscale IP (`100.x.y.z`). Tailscale is free for personal use and takes ~5 minutes.
2. **Move SSH off port 22.** Edit `/etc/ssh/sshd_config`: `Port 2222`. Stops 99% of drive-by brute-force attempts. Not security-through-obscurity — log-noise reduction.
3. **Kill password auth.** In `/etc/ssh/sshd_config`: `PasswordAuthentication no`, `PubkeyAuthentication yes`, `PermitRootLogin prohibit-password`. Only SSH keys, never passwords.
4. **UFW firewall, default-deny.** Allow outbound. Inbound: only your Tailscale interface (for SSH) + whatever ports your public services need (if any — prefer Cloudflare Tunnel instead).
5. **No public IP for OpenClaw services.** Your gateway listens on `127.0.0.1` only. Anything that needs to be reachable from outside Tailscale goes through a **Cloudflare Tunnel** (`cloudflared`). Your VPS never advertises a public port.
6. **Secrets in chmod 600 files, never in git.** Every `.env` / `-env.sh` file is mode 600, owned by root, listed in `.gitignore`. The Composio API key and Telegram bot token are the two biggest disasters if leaked — treat them accordingly.
7. **Separate user for agent automation (not root, ideally).** If you must run as root for systemd reasons, at minimum use a systemd drop-in with `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=true`.
8. **Chat-surface input is untrusted.** If your Telegram bot accepts messages from anyone, treat every incoming message as hostile input. Rate-limit it. Don't pipe message content into shell. Don't let the agent execute arbitrary code from chat without an allowlist.
9. **Backups verify themselves.** The backup cron in this repo includes a preflight check + end-to-end verification — so "no alerts" genuinely means "working" instead of "failing silently."
10. **Enable automatic security patches.** `unattended-upgrades` on Debian/Ubuntu. Review the defaults; reboot weekly if required. Vulnerabilities in OpenSSH / systemd / curl are rarer than you think but devastating when exploited.

**Do NOT run the one-line installer below until steps 1–4 are done.** If you skip the security setup, you're putting an always-on process with broad tool access on a box exposed to the entire internet. That ends badly.

---

## Where to run it

**Cheapest VPS that works:** [**Hetzner Cloud CX22**](https://www.hetzner.com/cloud/) — ~€4.30/mo (~$5), 2 vCPU, 4 GB RAM, 40 GB SSD. This is what I use. Everything in this repo is tuned for that size of machine.

Don't overbuy. The memory-guardian will tell you when to upgrade. Full sizing guidance (when to move to CX32 / CX42, when a Mac Mini at home starts making more sense than climbing the tier ladder): **[`docs/11-vps-sizing.md`](docs/11-vps-sizing.md)**.

## One-line install (AFTER security setup)

```bash
curl -fsSL https://raw.githubusercontent.com/<YOUR-GH-USER>/OpenClawBS/main/scripts/install/quick-install.sh | bash
```

That clones the repo to `/usr/local/openclaw-patterns/`, installs the scripts, sets up the systemd unit, and prints next steps for filling in your env file. No daemons start without your confirmation. Read the script before running if you're cautious — it's under 100 lines.

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
- `USER.md` — who you are (name, timezone, preferences)
- `AGENTS.md` — how the agent operates (rules for this workspace)
- `TOOLS.md` — local infrastructure notes (your SSH hosts, device names, APIs)
- `MEMORY.md` — curated long-term memories, indexed by typed files (`feedback_*.md`, `project_*.md`, `reference_*.md`)
- `memory/YYYY-MM-DD.md` — daily raw notes, like a journal

Every session the agent reads these first. When something new happens worth remembering, it writes to the right file. The ephemeral session dies; the files remain. This is the same pattern humans use: short-term working memory + long-term storage. See [`workspace/`](workspace/) for the templates.

### Failure 3: The AI silently dies in production

OAuth tokens expire. RAM creeps up. Background jobs accumulate zombies. None of these crash the system loudly — they slowly degrade it until something important stops working and nobody notices for days.

**The fix here: three layers of defense.**

1. **Composio-first auth** ([`docs/04-composio-first-auth.md`](docs/04-composio-first-auth.md)): never hold an OAuth token yourself. Let Composio auto-refresh them. Fetch fresh tokens on every cron run. Tokens *cannot* expire from your perspective.
2. **Memory guardian** ([`scripts/memory-guardian.sh`](scripts/memory-guardian.sh)): every 5 minutes, a dumb shell script checks RSS, available RAM, and disk growth. Restarts the gateway proactively. Telegram alerts you with context.
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

A cron job isn't "scheduled script" here — it's a mini-agent that wakes up, checks something, acts if needed, and goes back to sleep. The ~18 cron jobs on my VPS together form a continuous background heartbeat. Some are pure shell (cheap, fast, deterministic). A few need AI reasoning and pass `--light-context` to skip the 52K-token system prompt.

The discipline: **every cron alerts Telegram on failure, writes status on success, and has a timeout.** Failures never go unnoticed. Successes stay quiet.

See [`scripts/templates/cron-wrapper.sh`](scripts/templates/cron-wrapper.sh) — a wrapper that adds locking, timeout, alerting, and log rotation to any cron line.

### Stop hook — the "you're not done yet" enforcer

When an AI session tries to end, a `Stop` hook runs. It's just a shell script. If it exits 0, the session ends. If it exits non-zero, the AI is forced to continue with an error message.

My Stop hook checks:
- Any pending tasks in beads still open? → not done
- Any recent tool errors unresolved? → not done
- Did the AI explicitly address the user's request? → if not, not done

**This is the single most important pattern for preventing "AI said it was done but lied."** The AI can't unilaterally decide it's finished. See [`claude-code/hooks/taskmaster-check-completion.sh`](claude-code/hooks/taskmaster-check-completion.sh).

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
[ Your laptop ]              [ Cheap VPS, always-on ]        [ Composio ]
 Claude Code               OpenClaw gateway (Node)           auth broker
 skills, agents,      ⇄    cron agents, workspace,       ⇄   24+ services
 hooks, memory            memory-guardian, alerts            auto-refreshed tokens
```

- **Laptop (Claude Code)** does heavy reasoning, skill composition, code editing
- **VPS (OpenClaw)** is the always-on brain — crons run, memory persists, Telegram bot replies
- **Composio** is the OAuth broker for the ~24 services the agent talks to

Each layer has exactly one job. Simple enough to reason about; resilient because failures in one layer don't cascade.

---

## The five patterns, one sentence each

1. **Workspace-as-brain** — Fixed markdown files (SOUL/USER/IDENTITY/AGENTS/TOOLS/MEMORY) are the agent's persistent home. ([`docs/03-workspace.md`](docs/03-workspace.md))
2. **Composio-first auth** — Never hold OAuth tokens; let Composio auto-refresh them. ([`docs/04-composio-first-auth.md`](docs/04-composio-first-auth.md))
3. **Memory guardian** — 5-minute OOM watchdog with proactive restart + Telegram alerts. ([`docs/05-memory-guardian.md`](docs/05-memory-guardian.md))
4. **Shell-first crons** — AI sessions are expensive; use shell/Python first, AI only when genuine reasoning is needed. ([`docs/06-shell-first-crons.md`](docs/06-shell-first-crons.md))
5. **Rich failure alerts** — Every cron failure gets a Telegram message with severity, step, UTC time, runtime, error detail, and log tail. ([`docs/07-telegram-alerts.md`](docs/07-telegram-alerts.md))

---

## Repo layout

```
docs/         — Philosophy & architecture essays (the "why")
workspace/    — Markdown templates for the agent's home directory
scripts/      — Reusable shell: composio-drive, memory-guardian, alert, backup/cron templates
  install/    — One-line installer + env.sh template
  lib/        — alert.sh, composio-token.sh (sourceable helpers)
  templates/  — backup-template.sh, cron-wrapper.sh (fork + fill in)
systemd/      — Gateway unit file + drop-in env override template
claude-code/  — Laptop-side: hooks, CLAUDE.md sections, agent/skill patterns
examples/     — End-to-end walkthroughs
```

Every file in `scripts/` and `systemd/` is either runnable as-is or a template you fill in. No personal values are baked in.

---

## What this isn't

- **Not a product.** No installer (well, one opt-in line), no support, no guarantees.
- **Not production-grade security.** Threat model: "VPS I run alone." Shared infra? Add hardening.
- **Not opinionated about the AI backend.** Works with whatever model OpenClaw runs.
- **Not a replacement for [OpenClaw](https://github.com/openclaw/openclaw).** OpenClaw is the runtime; this is the config around it.

## How to adopt piecewise

**Start with security** → [`docs/00-security.md`](docs/00-security.md) is step one, regardless of which patterns you end up using. Don't skip it.

Then pick any of these patterns; they're independent:

- **Resilient Drive backup** → [`scripts/composio-drive.sh`](scripts/composio-drive.sh) + [`scripts/templates/backup-template.sh`](scripts/templates/backup-template.sh) + [`scripts/lib/alert.sh`](scripts/lib/alert.sh)
- **OOM prevention on small VPS** → [`scripts/memory-guardian.sh`](scripts/memory-guardian.sh) — works with any systemd service
- **Typed persistent memory for a different agent** → [`workspace/`](workspace/) structure — applies to any runtime
- **Stop-hook gate for Claude Code** → [`claude-code/hooks/`](claude-code/hooks/)
- **Full setup** → Read [`docs/00-security.md`](docs/00-security.md) first, then [`docs/02-architecture.md`](docs/02-architecture.md)

## License

MIT. Do whatever.

## Related

- [Composio](https://composio.dev) — the auth broker this setup is built around
- [Beads](https://github.com/steveyegge/beads) — the task tracker the Stop hook uses
- [Ghidra](https://ghidra-sre.org/) — when you need to reverse-engineer an undocumented API
- [OpenClaw](https://github.com/openclaw/openclaw) — the underlying runtime this setup configures ([npm](https://www.npmjs.com/package/openclaw))
- Claude Code — Anthropic's CLI, layer 1 of the stack
