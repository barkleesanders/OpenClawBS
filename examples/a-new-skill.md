# Example: Building a new Claude Code skill

Walkthrough of building a small skill end-to-end, using the conventions from this repo.

## The scenario

You find yourself typing the same multi-step request into Claude Code over and over:

> "Before I commit, please: run biome check, run the tests, check if there are any lint warnings, summarize any issues, and tell me what commands to run to fix them."

That's a skill. Let's call it `/precommit`.

## Step 1 — Create the skill directory

```bash
mkdir -p ~/.claude/skills/precommit
```

## Step 2 — Write `SKILL.md`

```markdown
---
name: precommit
description: |
  Pre-commit sanity check. Runs biome, tests, and lint on the current repo;
  summarizes issues; suggests fix commands. Invoke before `git commit`.
allowed-tools:
  - Bash
  - Read
---

# /precommit

Before committing, run a pre-commit sweep on the current repo.

## Steps

1. **Run biome** (if the project uses it):
   ```bash
   bun x biome check . 2>&1 | tail -30
   ```
   If biome isn't in the project, skip and mention it wasn't found.

2. **Run the test suite** with a 2-minute timeout:
   ```bash
   timeout 120 npm test 2>&1 | tail -30
   ```
   Never run `npm test` without a timeout — hanging test workers eat RAM.

3. **Check for `TODO` / `FIXME` / `XXX` added in this commit**:
   ```bash
   git diff HEAD | grep -E '^\+.*(TODO|FIXME|XXX)' | head -10
   ```

## Report

Report in this format:

- **Biome:** (count of errors / warnings, one-line summary)
- **Tests:** (pass/fail count, one-line summary)
- **New TODOs:** (count + list if <5)
- **Suggested next step:** either "Ready to commit" or a specific command

Keep it under 200 words. If any step fails, include the exact command to fix it.

## When not to run

- On a fresh clone that hasn't been built yet — mention dependencies need installing first
- If `package.json` is missing — this isn't a Node project; adapt or skip

## Error handling

If any command returns non-zero, still continue to the next step. Report failures explicitly — don't hide them.
```

## Step 3 — Test it

Open Claude Code in any project and run `/precommit`. Claude loads the SKILL.md and follows its instructions.

First invocation will reveal what's unclear. Iterate on SKILL.md until the output is exactly what you want.

## Step 4 — Consider super-skill consolidation

After a month of use, you notice you also have:

- `/gitsafety` — checks for secrets in staged diff
- `/typecheck` — runs `tsc --noEmit`
- `/lintfix` — runs biome with `--fix`

These are all "pre-push sanity" things. Consolidate into `/precommit` with mode detection:

```markdown
| User intent                          | Mode         | Steps to run |
|--------------------------------------|--------------|--------------|
| default (no args)                    | full-sweep   | biome + tests + type-check + secrets |
| "just types" / "type check"          | types-only   | tsc --noEmit |
| "secrets" / "safety"                 | security     | git diff | grep for API keys |
| "fix"                                | auto-fix     | biome --fix + prettier --write |
```

Now you have one skill for all pre-commit concerns, selectively loaded.

## Step 5 — Reference files (if the skill grows)

When a skill's instructions exceed ~400 lines, split into reference files:

```
~/.claude/skills/precommit/
  SKILL.md                         # entry point with mode table
  references/
    full-sweep.md                  # detailed full-sweep instructions
    security-checks.md             # secret detection patterns
    auto-fix-playbook.md           # biome/prettier config reference
```

The SKILL.md is ~2 KB; each reference is loaded only when its mode is triggered. Same pattern as `/carmack`.

## What makes a good skill

- **Explicit invocation** — the user chooses when to run it
- **Deterministic behavior** — same invocation should produce similar output
- **Short SKILL.md** — load-time cost matters; aim for <4 KB
- **Clear error cases** — document what to do when things go wrong
- **Composable** — can invoke other skills or be invoked by them

## What makes a bad skill

- **"Do the thing"** without specifying what "the thing" means
- **Inline LLM reasoning for deterministic checks** — if it's just "run X", wrap it in a shell script, not a skill
- **Dependency on external state not mentioned in SKILL.md** — skills should be self-contained
- **Redundant with an existing skill** — merge instead

## Iterating on a skill

Edit the SKILL.md. That's it. No build step, no restart, no cache to clear. Next `/<name>` invocation picks up the new version.

Treat SKILL.md like code: commit changes, keep a history, review diffs before pushing to your `~/.claude/` backup repo. `backup-config.sh` handles the push automatically on next session start.

## When to retire a skill

```bash
ls -lt ~/.claude/skills/ | tail -10
```

Anything you haven't touched in 6+ months, haven't invoked in 3+ months — probably dead. Delete or archive. Live skills stay alive because you keep using them.

Dead skills in the list make it harder to find the live ones. Treat them like dotfiles that rotted.
