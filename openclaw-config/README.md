# OpenClaw Config

Configuration files for the OpenClaw agent workspace on VPS.

## Files

### `HARD_RULES.md`

Operational rules injected into the agent's workspace AGENTS.md (or read at
session start). These rules make the agent behave predictably for long-running
autonomous work:

- Beads task tracking is MANDATORY before starting any Telegram-triggered work
- All cron completions must close their beads issue
- Telegram messages follow specific formatting rules
- No action without user approval on destructive operations

Copy to `~/.openclaw/workspace-main/HARD_RULES.md` on VPS and reference it
from your `AGENTS.md`:

```markdown
## Operating Rules
See HARD_RULES.md for mandatory operating procedures.
```

### `cron-nr-watcher.json`

OpenClaw cron configuration for the NR Document Watcher. This is a single job
extracted as a template — fill in your values and register with:

```bash
openclaw cron add --from-file /path/to/cron-nr-watcher.json
```

Before using, replace all `YOUR_*` placeholders with real values.

The cron runs every 4 hours, invokes the NR orchestrator, analyzes any new
docs, and sends gap analysis + deficiency letter drafts via Telegram.

## Usage

```bash
# On VPS, after editing values:
cp HARD_RULES.md ~/.openclaw/workspace-main/HARD_RULES.md
openclaw cron add --from-file cron-nr-watcher.json
openclaw cron list   # verify it registered
```
