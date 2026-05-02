# HARD_RULES.md — non-negotiable

Read this every session **before** AGENTS.md. Short on purpose.

## 1. Dates

- Today's date is in `memory/YYYY-MM-DD.md` (auto-written 00:01 PT). Read today + yesterday.
- Cron user messages always include a `Current time: ...` line — trust that over your training-data intuition.
- Do not report a date from training data. If unsure, `date +%F` or read the memo file.

## 2. Task tracking (MANDATORY — every turn)

`bd` (beads) is the ONLY task tracker. On macOS Homebrew it lives at `/opt/homebrew/bin/bd`; on Linux it's typically `/usr/local/bin/bd`. Confirm with `command -v bd` if unsure. Never use TodoWrite, markdown checklists, or MEMORY.md for tasks.

Mode: **strict-forced** by default — track every actionable request and skip only pure non-actionable chatter.

**For every actionable user message, run these commands. Each one is a SEPARATE exec call — do NOT chain with && or |.**

Create the issue (run from the workspace root that holds the right `.beads/` DB):
```bash
BEADS_ACTOR=openclaw bd create --title="<1-line task>" --description="<context>" --type=task --priority=2 > /tmp/bd_issue.txt 2>/dev/null
```

Extract the ID:
```bash
ISSUE=$(grep "Created issue:" /tmp/bd_issue.txt | grep -oE "[a-zA-Z]+-[a-z0-9]+" | head -n 1 || echo "")
echo "BEADS_ISSUE=$ISSUE"
```

Claim it:
```bash
[ -n "$ISSUE" ] && BEADS_ACTOR=openclaw bd update "$ISSUE" --claim 2>/dev/null
```

... do the work ...

Close it:
```bash
[ -n "$ISSUE" ] && BEADS_ACTOR=openclaw bd close "$ISSUE" --reason="<what was done>" 2>/dev/null
```

**Why explicit working dir matters:** beads resolves the `.beads/` database from the CWD upward. Multi-host setups (e.g. Mac + remote agent) typically share a single shared workspace prefix (e.g. `~/clawd`) so both sides write to the same logical issue tracker. If you `cd` into a subproject with its own `.beads/`, you'll create issues in that scoped DB instead.

**Why tempfile (not pipe):** Cron sessions sometimes run in a PTY. Piping `bd create | grep` can lose stdout. Writing to `/tmp/bd_issue.txt` then grepping is reliable.

**Why `grep "Created issue:"`:** bd output includes warning lines. The `Created issue:` line always contains the ID. This avoids matching warning text.

Skip beads ONLY for: one-word replies, heartbeat ACKs (`HEARTBEAT_OK`), silent cron completions (`NO_REPLY`).

Cross-session memory: `bd remember "insight"` → persists across sessions. `bd memories <keyword>` → search. NOT `MEMORY.md`.

## 3. External actions

- Email / tweet / Slack / public post → ASK first. Show recipient, subject, body.
- Internal (read files, run scripts, organize) → go ahead.
- `trash` > `rm`. Never `rm -rf` without confirmation.

## 4. Native-first

- Prefer `openclaw <cmd>` over custom wrappers. Retired wrappers live in `~/.openclaw/retired-*`.
- Pure shell tasks → host scheduler (`launchd` on macOS, `systemd` timer on Linux). AI tasks (reasoning/writing) → `openclaw cron`.
- Recurring tasks → host scheduler or `openclaw cron`, NOT in-session.

## 5. Cron context mode

- Default: **full context** (omit `--light-context`). Flat-rate model plans make full context effectively free and give crons access to skills + workspace.
- `--light-context` only when cron fires ≤ every 5 minutes.

## 6. Verification

- "Service started" ≠ "service working". Test with real traffic.
- After config change: re-read the file, re-run the thing that was broken, confirm the symptom is gone.
- Lowest-level fixes beat high-level workarounds. Understand the mechanism before patching.

## 7. No fabrication

- Never invent phone numbers, case citations, people, or facts not present in a source the user provided.
- When in doubt, omit or say "I'd need to check".
