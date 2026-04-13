# Skills — User-Invokable Slash Commands

A Claude Code skill is a directory under `~/.claude/skills/<name>/` with a `SKILL.md` inside. The user invokes it by typing `/<name>` in Claude Code. The SKILL.md is loaded into context, and the assistant follows its instructions.

## The super-skill pattern

Instead of maintaining 17 separate engineering skills (`/debug`, `/review`, `/feature`, `/lighthouse`, `/browser`, `/git-safety`, `/rust-patterns`, ...), have **one** skill with a mode-detection table at the top:

```markdown
---
name: carmack
description: Universal engineering agent. Debug, build, review, ship.
---

# /carmack — Engineering Agent

When invoked, match the user's request against this mode table and load ONLY the relevant reference files.

| User intent pattern                                  | Mode           | Reference files to read |
|------------------------------------------------------|----------------|-------------------------|
| bug, error, crash, failing, 500, timeout, leak       | debug          | references/debug-patterns.md |
| review, PR, check code, audit                        | review         | references/code-review-react.md, references/code-review-security.md |
| build, add, implement, feature, create               | feature        | references/feature-implementation.md |
| lighthouse, perf audit, core web vitals              | lighthouse     | references/lighthouse-optimization.md |
| browser, CDP, screenshot                             | browser        | references/browser-automation.md |
| git, commit, push, branch, secrets                   | git            | references/git-workflow.md |
...

Then do the work according to the mode's conventions.
```

Each reference file is ~5-15 KB. The SKILL.md itself is ~3 KB. Total load per invocation: 8-18 KB depending on mode, instead of 100+ KB if everything were always loaded.

## Why super-skills beat many skills

- **Lower cognitive load** — you remember `/carmack` for all engineering work, not 17 different slash commands
- **Lower token cost** — only the relevant references load
- **Composition** — the skill can invoke other skills (`/ship` uses `/carmack` internally for the audit phase)
- **Easier to extend** — new pattern? Add a reference file and a table row, not a whole new skill

## Skill file anatomy

```
~/.claude/skills/carmack/
  SKILL.md                           # Entry point with mode table
  references/
    debug-patterns.md                # Loaded for debug mode
    code-review-react.md             # Loaded for review mode
    feature-implementation.md        # Loaded for feature mode
    browser-automation.md            # Loaded for browser mode
    git-workflow.md                  # Loaded for git mode
    lighthouse-optimization.md       # Loaded for lighthouse mode
    ...
```

SKILL.md loads on every invocation. The reference files load selectively based on mode.

## The SKILL.md frontmatter

```yaml
---
name: carmack
description: Universal engineering agent — debug, build, review, ship. Use instead of individual skills for any software engineering task.
model: opus
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
  - Glob
  - Grep
  - Task
---
```

The `description` is what Claude shows the user when listing skills. Make it precise — you want the user to know when to invoke `/carmack` vs `/ship` vs `/browser`.

## Merging existing skills — the checklist

Deciding whether to merge two existing skills into one super-skill:

- Do they share 60%+ of their logic? → Merge
- Do users invoke them interchangeably? → Merge, use mode detection
- Would merging mean one skill loads 10 KB+ of content most invocations don't need? → Keep separate

Merging lifts the cognitive floor (fewer commands to remember) but raises the skill-level cost if done wrong (bloated context).

## Example super-skills from this setup

- **`/carmack`** — universal engineering (17 reference files, 10 modes)
- **`/ship`** — production deployment with safety gates (4 reference files, 3 audit tiers)
- **`/browser`** — browser automation (chrome-cdp for live sessions + agent-browser for headless, picked by mode)
- **`/changelog`** — multi-phase release-notes generator (scan commits → categorize → draft → polish)

Each one replaces 3-10 smaller skills that existed before the merge.

## Skill composition

Skills can invoke each other:

- `/ship` runs `/carmack` for the safety audit phase
- `/changelog` uses `/carmack` in review mode for final polish
- `/ralph` (autonomous feature implementation) calls `/review` after each phase

This is the Unix philosophy applied to skills: small sharp tools that chain.

## Writing a new skill

```bash
mkdir -p ~/.claude/skills/myskill/references
cat > ~/.claude/skills/myskill/SKILL.md <<'EOF'
---
name: myskill
description: What it does and when to use it.
---

# /myskill

When invoked, do this specific thing.

If the work is big enough to warrant mode detection, use the table pattern:

| Intent | Mode  | References to load |
| ...    | ...   | ...               |

Then do the work.
EOF
```

That's it. No registration, no plugin system. Claude Code discovers it automatically.

## What NOT to make a skill for

- **Single-shot actions** — just ask directly
- **Things that are already a shell command** — run the command, don't wrap it
- **Tasks you'd do once every six months** — not worth the overhead

Skills pay off at 10+ invocations. Below that, it's premature optimization.
