# 10 — Skills and Agents in Claude Code

Claude Code has two extension points: **skills** (user-invokable slash commands) and **agents** (context-triggered specialists). They solve different problems and shouldn't be confused.

## Skills — user-invokable slash commands

A skill is a directory under `~/.claude/skills/<name>/` with a `SKILL.md` inside. The user invokes it by typing `/<name>` in Claude Code. The SKILL.md is loaded into context, and the assistant follows its instructions.

Use skills for:

- **Deliberate actions** — "I want to deploy to production" → `/ship`
- **Multi-phase workflows** — `/changelog` runs a multi-phase release-notes pipeline
- **Mode-setting** — `/carmack` puts the AI into empirical-debugging mode

Skills are *explicit*. The user chooses to invoke them. They're the most powerful extension point.

## Agents — context-triggered specialists

An agent is a markdown file under `~/.claude/agents/<name>.md` with a description of when to use it. Claude Code spawns the agent automatically when a task matches (via the Task tool with `subagent_type`). The agent runs in its own isolated context, returns a result, and disappears.

Use agents for:

- **Code review with a specific voice** — kieran-rails, kieran-python, kieran-typescript, julik-frontend, dhh-rails
- **Parallelizable research** — launch 3 explore agents simultaneously
- **Isolated context** — the agent's work doesn't pollute the main conversation

Agents are *implicit*. The main AI decides when to call them based on task shape.

## The per-domain specialist pattern

My setup has ~36 agents, and the most useful ones are named for specific reviewers with specific styles:

- `kieran-rails-reviewer` — DHH-style Rails review, questions every convention
- `kieran-python-reviewer` — strict Python taste (type hints, Pythonic patterns)
- `kieran-typescript-reviewer` — React 19 + TypeScript expertise
- `julik-frontend-races-reviewer` — specializes in UI race conditions and DOM timing
- `dhh-rails-reviewer` — the actual DHH viewpoint (anti-JavaScript-framework-contamination)

Why named-person agents work better than generic ones:

- "Review this code" is too vague; the AI doesn't know what to look for
- "Review this code as kieran-rails would" is specific; the AI has a *voice* to apply
- The agent's personality is in its file; updating it is a text edit

Each agent is 200-1000 tokens. Cheap. Composable. Reusable across every project.

## The super-skill pattern

Instead of maintaining 17 separate engineering skills, I have one: `/carmack`. It has a mode-detection table at the top:

```
| User intent contains... | Mode      | Reference files to load |
| bug, error, crash       | debug     | debug-patterns.md       |
| review, PR, check code  | review    | code-review-react.md, code-review-security.md |
| build, add, implement   | feature   | feature-implementation.md |
| lighthouse, core web    | lighthouse| lighthouse-optimization.md |
...
```

`/carmack` reads the user's request, picks a mode, loads *only* the relevant reference files, and does the work. The reference files total ~100 KB of documentation but only ~15 KB load per session.

This is the pattern: **one entry point, many implementations, load-on-demand**.

- Lower cognitive load — you remember `/carmack` for everything engineering-related
- Lower token cost — only load what the task needs
- Easier updates — new pattern? Add a reference file and a table row.

See [`claude-code/skills/README.md`](../claude-code/skills/README.md) for examples.

## The merge-into-super-skill checklist

When deciding whether to merge two existing skills into one super-skill:

- Do they share ~60%+ of their logic? → Merge.
- Does the user invoke them interchangeably? → Merge, use mode detection.
- Would merging mean one skill loads 10 KB+ of content most invocations don't need? → Keep separate.

Merging lifts the cognitive floor (fewer commands to remember) but raises the skill-level cost if done wrong (bloated context). Judge on a case-by-case basis.

## Skill composition

Skills can invoke each other. `/ship` internally runs `/carmack` for the safety audit phase. `/changelog` uses `/carmack` in review mode for final polish. Composition > monolithic skills.

This is the same pattern Unix tools use: small sharp tools that chain. Don't build one skill that does everything; build small skills that combine.

## Agent prompting: the "cold brief" rule

Agents have zero context from the parent conversation. Every agent prompt must be **fully self-contained**:

- Include all file paths
- Describe constraints (don't rely on "we discussed this")
- State verification steps
- Cap response length explicitly

The anti-pattern is: "based on your findings, fix the bug." That pushes synthesis onto the agent instead of doing it yourself. Write prompts that prove you understood: include file paths, line numbers, and what specifically to change.

See `~/.claude/skills/carmack/SKILL.md` (or wherever you keep your carmack super-skill) for the "cold brief" discipline in practice.

## Launching agents in parallel

For independent tasks, launch multiple agents in a single message. Example for repo exploration:

```
Agent 1: "explore the VPS-side setup, map directory layout, identify secrets"
Agent 2: "explore the local Mac setup, map skills/agents/hooks"
Agent 3: (none — two agents are enough; don't spawn for the sake of it)
```

Three agents max per batch; usually one is sufficient. Each agent is a fresh context window, a fresh cache write, and a fresh cost. Use sparingly.

## When to write a new skill vs agent

**Write a skill when:**

- You notice you're giving the AI the same multi-step instructions repeatedly
- The workflow has 3+ phases
- You want deterministic invocation (slash command)

**Write an agent when:**

- You want a specific review voice / expertise applied
- The work is parallelizable
- The work would pollute the main context if done inline

**Write neither when:**

- You'd only use it once (just ask directly)
- A real CLI tool already does the job

## File structure

```
~/.claude/
  skills/
    ship/
      SKILL.md              # description, invocation, behavior
      references/
        quality-gates.md    # supporting context
    carmack/
      SKILL.md
      references/           # mode-specific files
        debug-patterns.md
        code-review-react.md
        lighthouse-optimization.md
  agents/
    kieran-rails-reviewer.md
    kieran-python-reviewer.md
    julik-frontend-races-reviewer.md
    carmack-mode-engineer.md
```

Nothing fancy. Directories for skills (so they can have reference files), flat files for agents.
