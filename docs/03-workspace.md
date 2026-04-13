# 03 — The Workspace: SOUL / USER / IDENTITY / AGENTS / TOOLS / MEMORY

The workspace is a directory of markdown files that the agent treats as its home. It's loaded on every session start. Updated when anything significant happens. The agent survives restarts, migrations, and crashes because its state lives here, not in prompt context.

## The files

See [`workspace/`](../workspace/) for runnable templates. Summary:

### `SOUL.md` — Who the agent is

Generic for every user; about the agent itself, not you. Values, vibe, boundaries, continuity principles. Starts from the template and evolves over time as the agent learns what works.

> _"Be genuinely helpful, not performatively helpful. Skip the 'Great question!' — just help. Actions speak louder than filler words. Have opinions. You're allowed to disagree, prefer things, find stuff amusing or boring."_

This is the agent's *personality*. It's what makes interactions feel like talking to *someone* instead of a stateless LLM.

### `USER.md` — Who you are

Name, pronouns, timezone, notes. Built up over time by the agent as it learns about you. Starts empty in the template.

### `IDENTITY.md` — The agent's specific identity

Name, vibe, emoji, avatar. Filled in during the BOOTSTRAP conversation on first run. This is where the agent becomes *this particular* agent (not just "an AI").

### `AGENTS.md` — The operating rules

How to behave in this workspace. Session startup order (read SOUL → USER → memory). Safety rules. Cron design guidelines. Group-chat etiquette. Heartbeat policy.

This file is the closest thing to a system prompt — but it lives on disk, can be edited anytime, and is ~3KB instead of 52KB.

### `TOOLS.md` — Local infrastructure notes

Your camera names, SSH hosts, TTS voice preference, speaker nicknames, anything environment-specific. Also the Composio-first auth rule (the most important entry).

Think of it as the agent's index card of "stuff specific to this setup."

### `BOOTSTRAP.md` — First-run birth certificate

Only exists on first-run. Guides the first conversation: "Hi, who are we? What should I call you? What's your timezone?" The agent fills in USER.md / IDENTITY.md based on the answers, then deletes BOOTSTRAP.md.

### `HEARTBEAT.md` — Rotating check list

Empty by default. A place for the agent to jot "things to check periodically" (unread emails, upcoming calendar, weather). Used by the heartbeat cron to rotate through checks without creating 10 separate cron jobs.

### `MEMORY.md` — The long-term index

Entry per memory. ~150 chars each. Links to a typed memory file that has the full content. MEMORY.md itself should never hold the facts — it's just a table of contents.

### `memory/YYYY-MM-DD.md` — Daily raw notes

Freeform journal. "What happened today." Decisions, bugs, things the user said, things the agent tried. Reviewed during heartbeats and distilled into MEMORY.md over time.

## The typed-memory pattern

MEMORY.md entries point to files by type:

- **`feedback_*.md`** — Rules the agent has learned. "Never send email from address X using provider Y." Each has a `Why:` and `How to apply:` line so future agents understand the *reason*.
- **`reference_*.md`** — Pointers to infrastructure. "VPS is at hostname X, SSH port 22. Tunnel at URL Y."
- **`project_*.md`** — Incident postmortems + migration records. "On date X, Y broke because Z. Fix was W. Here's what to check if it recurs."
- **`user_*.md`** — About you. Preferences, expertise, collaborators. Grows over time.

Why this structure:

1. **Frontmatter timestamps.** Each file has `--- type: feedback ---` frontmatter. Session-start tooling can mark files older than N days as stale so the agent knows to verify before asserting.
2. **Typed lookup.** "Find all `feedback_*.md`" is grep-friendly. "Find all memories about auth" is a glob.
3. **Atomic updates.** Editing one memory doesn't change any other. Merge conflicts are minimal.
4. **Garbage collection.** Superseded memories get marked SUPERSEDED (not deleted) with a forward pointer. Clear audit trail of how the rules evolved.

## Why not just use a database

- SQLite means schema migrations.
- Markdown is human-readable and human-editable.
- git diff shows what changed.
- grep works.
- A power outage or corrupt row doesn't lose everything.

The tradeoff is you can't do fancy queries. That's fine — at this scale grep is plenty, and anything bigger belongs in a real system.

## How this enables token savings

Without this pattern, a typical session wastes ~3-5K tokens re-establishing basics: "I use zsh on macOS, my VPS is at X, I prefer TypeScript strict mode, I use beads for task tracking, I don't like explanatory comments in code..."

With this pattern, all of that lives in `AGENTS.md` + `TOOLS.md` + `MEMORY.md`. Maybe 1K tokens total. Loaded once at session start. Free for the rest of the session.

On a daily-agent-use setup, that's ~60% prompt savings that compound forever.

## How this prevents hallucination

The AI is much less likely to invent facts when the ground truth is *right there in a file it just read*. "Use the email pattern from feedback_email_sender.md" is grounded; "use whatever you think is right" is not.

Combined with the Stop-hook check, this means:
- The AI knows the rules (they're in files).
- The AI can't pretend the rules don't exist (they're loaded every session).
- The AI can't pretend work is done while rules are being violated (the hook checks).

## Bootstrapping a new workspace

```bash
mkdir -p ~/.my-agent-workspace/memory
cp -r OpenClawBS/workspace/* ~/.my-agent-workspace/
cd ~/.my-agent-workspace
# Fill in IDENTITY.md.template → IDENTITY.md (or let first-run do it)
# Fill in USER.md.template → USER.md
# Delete BOOTSTRAP.md once the agent has introduced itself
```

That's it. Point your agent at this directory as its home and it starts accumulating continuity immediately.
