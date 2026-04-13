# 01 — Philosophy

Five ideas underlie every decision in this setup. If you disagree with any of them, most of the rest of this repo will seem overbuilt. If you agree with all five, most of the rest will feel obvious.

## 1. Files on disk are the source of truth. Sessions are disposable.

An AI session is a temporary lens on persistent state, not a state of its own. Whatever the session "knows" dies when the session ends. Whatever is written to a file survives forever.

So: write down what matters, as soon as it matters, in the simplest file that can hold it. Don't accumulate knowledge in prompt context. Don't re-teach the same facts session after session. Edit a file once; every future session inherits the update.

Concrete: `SOUL.md`, `USER.md`, `AGENTS.md`, `TOOLS.md`, `MEMORY.md`, `memory/YYYY-MM-DD.md`. Flat markdown. Read at session start. Written at session end. No schemas, no databases, no migrations.

## 2. The cheapest reliable thing that works is the right tool.

For routine work, the order of preference is:

1. **Shell** — deterministic, ~0 cost, instant
2. **Python** — slightly more flexible, still cheap, still deterministic
3. **A CLI tool** — if it exists for the thing you want, use it
4. **An MCP server** — when you need the AI to call an API during a session
5. **An AI session** — only when real reasoning, writing, or judgment is required

Every AI session here costs ~$0.19. Doing "check if this URL responds" with an AI session is like hiring a consultant to read your email. Reserve AI for what only AI can do. Use it sparingly and it stays magical.

## 3. Fail loud, succeed quiet.

Every cron that matters alerts Telegram on failure with context: severity, step, timestamp, runtime, error detail, log tail. When it succeeds, it writes a status file and says nothing.

This is the opposite of logging everything. The point is that your attention is finite. You want an interrupt for actual problems and nothing else. Successful runs are noise.

## 4. Outside processes verify inside claims.

LLMs will optimize for appearing-done over actually-being-done when under pressure. The fix is to put verification *outside* the model's control. The Stop hook runs a shell script; the shell script checks beads; the AI can't talk it out of blocking if there's unresolved work.

This generalizes: every important assertion should have an external check. "Tests pass" → run the tests. "Deployment succeeded" → curl the health endpoint. "Backup worked" → list the Drive folder. The AI's word is an opinion; the shell script is a fact.

## 5. Continuity via files means the AI survives everything.

Upgrades, restarts, context compaction, crashes, migrations — none of these should matter. When the agent comes back, it reads its files and resumes. No re-onboarding, no context repopulation, no "let me catch you up."

The test: if you delete the running process entirely and start a fresh one, how long until it's fully productive again? With this setup: about 5 seconds (the time to read the workspace files). Without it: hours, maybe days.

---

If all five of those resonate, the rest of this repo is just specific applications of those ideas. If they don't, you'll probably want a different architecture — and that's fine.
