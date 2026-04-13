# 08 — Typed Memory System

The agent's long-term memory isn't a database. It's a directory of small markdown files, each typed and tagged with frontmatter, all indexed by a single `MEMORY.md`.

## Why this pattern exists

The problem with "just tell the AI": prompt context is ephemeral, expensive, and the AI forgets mid-session anyway.

The problem with "write a plugin / database": you're now maintaining a schema, a migration path, and a query language for what is fundamentally "a pile of small facts."

Markdown files in a directory split the difference. Searchable with grep. Editable in any editor. Diffable in git. Loadable with `cat`.

## The files

```
memory/
  MEMORY.md                              # index, always loaded at session start
  feedback_composio_first_auth.md        # a typed memory file
  feedback_email_approval.md             # another one
  project_db_backup_migration.md       # postmortem + migration record
  reference_vps_hostnames.md             # infrastructure pointers
  user_working_preferences.md            # about the user
```

## MEMORY.md — the index

Short. Pinned at the top of context every session. Each entry is one line:

```markdown
# Memory

## 🔑 Composio-First Auth (MANDATORY — 2026-04-13)
- [Composio-First Rule](feedback_composio_first_auth.md) — ALWAYS check Composio before any new OAuth/CLI flow

## Email Rules
- [Sender Address](feedback_email_sender_address.md) — use the exact address the user specifies
- [Approval Before Send](feedback_email_approval.md) — never send email without explicit approval

## Backup Infrastructure
- [Backup Composio Migration](project_backup_composio_migration.md) — rclone → Composio migration record
```

The index *is not* the memory. It's a table of contents. Never put facts here — put them in typed files and link to them.

## Typed memory files

Each file has frontmatter and a structured body.

### `feedback_*.md` — rules the agent learned

```markdown
---
name: composio-first-auth
description: For any cron/tool that needs auth to a third-party service, check Composio FIRST.
type: feedback
---

**Composio is the preferred auth source for all tooling — crons, scripts, agents.**

## Why (2026-04-13)
rclone's Google Drive OAuth expired 2026-04-07 and silently broke 6 days of backups.
Composio auto-refreshes tokens server-side. Migrating eliminated the failure mode.

## How to apply
Before setting up any new service auth, check Composio first...

[rest of rule]
```

Key sections:

- **`name` / `description` in frontmatter** — short enough to show in `MEMORY.md`-level index
- **`Why:`** — the incident or reason that produced the rule; helps future agents judge edge cases
- **`How to apply:`** — when this rule triggers and what to do

### `project_*.md` — incident postmortems + migration records

```markdown
---
name: db-backup-composio-migration
description: Backup cron migrated from rclone to Composio-fetched OAuth on 2026-04-13.
type: project
---

Backup cron migrated from rclone to Composio-managed Google Drive auth on 2026-04-13.

**Why:** rclone OAuth expired 2026-04-07, silently failed 6 days of backups.

## Cron + paths
- Cron: `0 4 * * * /root/.openclaw/scripts/db-backup.sh`
- VPS: <hostname>
- Helper: `/root/.openclaw/scripts/composio-drive.sh`
- Rollback: `/root/.openclaw/scripts/db-backup.sh.bak-rclone-20260413`

## Folder IDs
- D1 dumps: <id>
- R2 documents: <id>

## Known limitations
- Composio UPLOAD_FILE requires s3key (5MB cap) — the helper bypasses with direct Drive REST
```

These are long enough to be useful during future debugging; short enough that you'll actually write one. They contain the kind of detail that would otherwise only live in someone's head.

### `reference_*.md` — infrastructure pointers

```markdown
---
name: vps-primary
description: SSH, auth, architecture, services, known rules for the OpenClaw VPS
type: reference
---

- SSH: `ssh -p 2222 root@<tailscale-ip>` (only root, <user> removed on 2026-04-01)
- OpenClaw home: `/root/.openclaw/`
- Composio env: `/etc/openclaw/env.sh` (chmod 600)
- Gateway: systemd unit `openclaw-gateway.service`
- Memory guardian: `*/5 * * * * /usr/local/bin/memory-guardian.sh`
- Backup: `0 4 * * * /root/.openclaw/scripts/my-backup.sh`
```

These should be dense. "Where is X?" should be answered in one glance.

### `user_*.md` — about the user

```markdown
---
name: user-working-preferences
description: Stylistic and collaboration preferences that apply to every interaction
type: user
---

- Prefers terse responses over verbose ones
- Deeply opinionated about not adding comments in code (never add comments)
- Uses zsh on macOS, Rust + TypeScript most often
- Works on personal infra at ~/VPS-related projects
- Interrupts often — short responses per tool call, longer synthesis at end
```

Agents read this at session start and *behave* accordingly. 1K tokens of preferences saves 10K tokens of "let me remind you I prefer..." repeated every session.

## Frontmatter discipline

Every memory file has these three fields at minimum:

```yaml
---
name: short-slug
description: One-line summary shown in the index.
type: feedback | project | reference | user
---
```

Optional:

- `superseded_by: path/to/new-file.md` — the record was replaced; prefer the new one
- `verified_at: YYYY-MM-DD` — last time the claims in this file were confirmed
- `decays_after: YYYY-MM-DD` — treat as stale after this date

A session-start hook can mark files older than N days as "possibly stale; verify before asserting." This is how you prevent a 2-year-old memory from being used as ground truth.

## Session-start workflow

```
1. Read MEMORY.md (the index)
2. For each applicable rule (based on current task), read the linked file
3. Behave according to what's in the file
4. If something happens during the session worth remembering:
   a. Decide: is it a rule (feedback), an event (project), a pointer (reference), or user-specific (user)?
   b. Write the appropriate typed file
   c. Add a one-line entry to MEMORY.md pointing to it
5. Before ending, confirm with the user that any new memory is accurate
```

## What NOT to put in memory

- Things derivable from code (the agent can just read the code)
- Git history (run `git log` instead)
- Ephemeral task state (use beads, not memory)
- Anything in CLAUDE.md (already loaded every session)

Memory is for the *non-obvious* facts — the ones you'd otherwise have to tell the agent every session.

## Garbage collection

Once a month:

1. `grep -l 'SUPERSEDED' memory/*.md` — files marked obsolete
2. Are any of them safe to delete entirely? (Check referrers first.)
3. `ls -lt memory/*.md | tail` — oldest files, haven't been touched in ages
4. For each: is this still true? Still useful? If not, delete or mark stale.

Treat memory like a human treats a journal: periodically re-read, distill, prune. Don't let it turn into a hoarder's attic.

## Comparison to alternatives

- **vs RAG over a knowledge base:** RAG is for search over large corpora. Memory is for small, authoritative rules. Different use case.
- **vs fine-tuning:** Fine-tuning bakes facts into weights permanently. Memory is edit-in-place. Every rule here is one file-edit away from changing.
- **vs vector DB:** Vector search is overkill for <100 memory files. Grep + frontmatter is sufficient and debuggable.

At any scale under ~500 memory files, this pattern beats anything more complex.
