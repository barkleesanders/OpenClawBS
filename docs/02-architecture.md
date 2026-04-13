# 02 — Architecture

Three layers. Each has one job. Failures in one don't cascade into another.

```
┌──────────────────────────┐      ┌──────────────────────────────────┐      ┌────────────────┐
│  Layer 1: Your laptop    │      │  Layer 2: VPS (always-on)        │      │  Layer 3:      │
│  (Claude Code)           │◄────►│  (OpenClaw gateway + cron brain) │◄────►│  Composio      │
│                          │      │                                  │      │  (auth broker) │
│  - Skills & agents       │      │  - Gateway (Node, systemd)       │      │                │
│  - Hooks                 │      │  - ~18 cron jobs                 │      │  - 24+ OAuth   │
│  - Local memory          │      │  - Workspace on disk             │      │    tokens      │
│  - Sync to VPS via SSH   │      │  - Memory guardian               │      │  - Auto-       │
│                          │      │  - Telegram bot                  │      │    refreshed   │
└──────────────────────────┘      └──────────────────────────────────┘      └────────────────┘
           ↓                                      ↓                                  ↓
    heavy reasoning                  persistent presence                   auth-as-a-service
    (short-lived)                    (24/7)                                (infinite TTL)
```

## Layer 1 — Claude Code on your laptop

Where the heavy work happens: writing code, refactoring, reviewing, reasoning. Claude Code is Anthropic's official CLI, and the laptop is where most AI minutes are burned.

Key components here (all in `~/.claude/`):

- **Skills** — slash-command specialists. `/carmack` debugs, `/ship` deploys with quality gates, `/browser` drives Chrome. You compose them like Unix tools.
- **Agents** — context-triggered specialists. Different review voices (kieran-rails, kieran-python, julik-frontend), different roles (backend-architect, security-sentinel, performance-oracle).
- **Hooks** — shell scripts that run on session events. `SessionStart` backs up config; `PreToolUse[Bash]` blocks dangerous commands; `Stop` enforces task completion; `PostToolUse[Edit]` lints.
- **Memory** — auto-managed typed markdown files (`feedback_*.md`, `project_*.md`, `reference_*.md`) indexed in `MEMORY.md`. Read at session start.

The laptop is *transient*. It sleeps when you close it. Long-running work gets handed to layer 2.

## Layer 2 — OpenClaw on a VPS

This is the always-on brain. Not powerful — a 3.7 GB Hetzner box at $5/month. But it's always reachable and never forgets.

Services:

- **`openclaw-gateway.service`** — a Node.js daemon. Holds the chat surfaces (Telegram bot, possibly WhatsApp, Discord), orchestrates tools, routes messages to the LLM. Uses ~1.5 GB RAM steady state.
- **systemd unit** — `Restart=always`, `NODE_OPTIONS=--max-old-space-size=3072`. No cgroup memory limit (the guardian handles that).
- **`memory-guardian.sh`** — every 5 minutes: checks RSS, available RAM, Chrome state JSON size. Restarts the gateway proactively before OOM. Alerts Telegram.
- **Cron jobs** — ~18 of them. Each is a small autonomous task: daily database backup, hourly token refresh, every-5-minute rate-limit check, nightly cleanup. Most are pure shell; a few use AI sessions with `--light-context`.
- **Workspace on disk** — `/root/.openclaw/workspace-main/` holds SOUL / USER / AGENTS / TOOLS / MEMORY. Every AI session that spawns here reads them first.

## Layer 3 — Composio (auth broker)

Composio holds OAuth tokens for every service the system talks to: Gmail, Google Drive, Calendar, Notion, Linear, GitHub, Reddit, Twitter, Instagram, LinkedIn, Cloudflare, and ~15 more. It auto-refreshes them server-side.

From our side: every time a cron job needs to hit Gmail (or whatever), it calls Composio's `/api/v3/connected_accounts` endpoint, gets a fresh `ya29.*` bearer token, and uses it directly against Gmail's REST API.

This layer exists because OAuth-token-expiration is a **design flaw** in the OAuth spec that causes ~80% of "my automation broke mysteriously" incidents. Composio solves it at the broker level, not per-service.

## How a request flows

Example: user sends "back up the database" via Telegram.

```
Telegram ──► Gateway (layer 2) ──► LLM decides: run daily-backup cron immediately
                                       │
                                       ▼
                               /usr/local/bin/backup.sh
                                       │
                          ┌────────────┴────────────┐
                          ▼                         ▼
                   export database           fetch OAuth token
                   to local file             from Composio API
                          │                         │
                          └────────────┬────────────┘
                                       ▼
                            upload to Google Drive
                            via Drive REST API
                                       │
                                       ▼
                          on success: write status file
                          on failure: Telegram alert
                                       │
                                       ▼
                                Gateway ──► Telegram: "done"
```

No state is held in the LLM during that flow. The database dump lives on disk. The Drive folder lives in Drive. The OAuth token is discarded after use (fetch fresh next run). The status file is the durable record.

## Why three layers instead of one

Could you put everything on one machine? Sure. But:

- **Laptops sleep.** Cron jobs that need to run at 4 AM can't live there.
- **VPS is not a great dev environment.** Editing code over SSH sucks; running the full IDE there is expensive.
- **Auth should be separated from logic.** If Composio fails, only auth breaks. If your VPS fails, only the always-on surface breaks. If your laptop fails, only active dev work breaks.

The three-layer split is about blast radius, not complexity for its own sake.

## What's NOT in this diagram

- **A database.** By design. SQLite files on the VPS for local state; everything else goes to Google Drive or services via Composio.
- **A message queue.** Cron is the message queue.
- **Kubernetes / Docker.** systemd is the orchestrator. Docker is available if you need it but deliberately not the default.
- **Observability stack.** Telegram + a status file + journald is enough at this scale. Grafana/Prometheus would be cargo-culting.

The power is in what's been left out. Every service you add is one more thing that can silently fail at 3 AM.
