# memory/

Daily raw notes go here as `YYYY-MM-DD.md`.

AGENTS.md defines the pattern:

- **Daily notes:** `memory/YYYY-MM-DD.md` — raw log of what happened that day (decisions, bugs, things the agent did, things the human said)
- **Long-term:** `../MEMORY.md` at the workspace root — the curated essence, indexed by typed memory files

The agent creates today's file on its own when it has something to record. Over time, it reviews the daily files during heartbeats and distills anything worth keeping long-term into `MEMORY.md`.

Think of it like a human's journal (raw, chronological, disposable) vs their long-term memory (curated, organized, durable).

This README can be deleted once the pattern is in use.
