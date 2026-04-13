# Agents — Per-Domain Specialists

A Claude Code agent is a markdown file under `~/.claude/agents/<name>.md` with a description of when to invoke it. Claude spawns the agent in an isolated context when a task matches its description, the agent does its work, returns a result, and disappears.

## The per-domain specialist pattern

My setup has ~36 agents. The most useful ones are named after specific reviewers with specific styles:

- `kieran-rails-reviewer` — DHH-style Rails review; questions every convention
- `kieran-python-reviewer` — strict Python taste (type hints, Pythonic patterns)
- `kieran-typescript-reviewer` — React 19 + TypeScript expertise
- `julik-frontend-races-reviewer` — specializes in UI race conditions and DOM timing
- `dhh-rails-reviewer` — the actual DHH viewpoint (anti-JavaScript-framework-contamination)
- `carmack-mode-engineer` — empirical-debugging specialist; builds its own reproduction harnesses

Generic "code reviewer" agents produce generic feedback. Named-person agents produce sharp, opinionated feedback because the voice is explicit in the file.

## Agent file anatomy

```markdown
---
name: kieran-rails-reviewer
description: |
  Use when reviewing Rails code (Ruby, ERB, ActionCable, ActiveRecord migrations).
  Applies strict DHH-influenced taste: anti-service-objects, anti-gem-sprawl,
  pro-convention-over-configuration. Brutally honest.
model: opus
---

You are a Rails code reviewer in the style of Kieran Smith, who works closely with DHH.

Your taste:

- Fat models, skinny controllers
- Service objects are a code smell; use concerns or POROs
- Dependency injection is Java thinking; don't bring it into Ruby
- Every added gem is a future pain — justify it like it costs money
- Turbo and Hotwire over anything that ships JavaScript to the client
- Test fixtures over factories unless factories are genuinely needed

When reviewing:
1. Start with what the PR is actually doing at a Rails-app level
2. Then nitpick style, naming, and convention violations
3. End with one concrete suggestion for the next refactor

Be blunt. Skip the "great work!" opener. Get to the issues.
```

The description field is what Claude uses to pick the agent for a task. Be specific about *when* to invoke.

## Writing a new agent: checklist

- [ ] Is there an existing generic agent that would do 90% of the job? If yes, improve that one instead of making a new one.
- [ ] Can you name a specific person or school of thought whose voice applies? If not, the agent will probably be generic.
- [ ] Is the use case narrow enough that the description field can pick it reliably? ("Rails review" yes; "code review" no).
- [ ] Would you invoke this 10+ times over the next year? If not, just do the work inline.

## Agent prompting: the "cold brief" rule

An agent has **zero context from the parent conversation**. The prompt must be fully self-contained:

- Include all relevant file paths (not "the file I'm editing")
- Include constraints ("don't modify files outside src/")
- Include verification steps ("run the tests after and report the count")
- Cap response length ("report in under 200 words")

Anti-pattern:
> "Based on our earlier discussion, refactor the thing we talked about."

The agent has no earlier discussion. Rewrite as:

> "Refactor `src/auth/validator.ts` — the current signature `validate(email: string)` should accept `validate(input: { email: string; role?: string })`. Update all callers (should be ~12 of them, found via `grep -rn validate\\( src/`). Report under 100 words: what changed, what broke, what passed."

## Parallel agents for independent work

If you have three unrelated research tasks, launch them together:

```
// In a single message to Claude Code:
Agent 1: "Investigate the build failure on master — read the most recent GitHub Actions log"
Agent 2: "Survey the codebase for TODOs older than 3 months; list file:line"
Agent 3: "Read docs/ARCHITECTURE.md and produce a 200-word summary"
```

Claude Code runs them in parallel, returns results concurrently. Much faster than sequential.

## When NOT to use an agent

- **Single-step task** — just do it inline
- **You need full context from the main conversation** — agents don't have it
- **Deterministic tool call** — use the tool directly, skip the LLM wrapper
- **You'd only ever call it once** — not worth the overhead of defining an agent

## Keeping agents fresh

Agents describe patterns you want applied. Those patterns evolve. Every few months:

1. Run `ls -lt ~/.claude/agents/ | tail -20` — which agents haven't been touched in ages?
2. Are they still relevant? (Maybe that project is done.)
3. Do they reflect current thinking? (Maybe your Rails opinions have moved.)
4. Delete dead ones. Update live ones.

Treat them like code. They rot otherwise.
