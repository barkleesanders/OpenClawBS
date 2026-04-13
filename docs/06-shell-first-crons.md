# 06 — Shell-First Crons: Cost Discipline

## The math

Every AI session on this system costs approximately **$0.19 in prompt cache writes** (the 52K-token workspace system prompt, written to cache on each cold session).

A cron job running an AI session every 5 minutes is:

```
12 runs/hour × 24 hours × 30 days × $0.19 = $1,641/month
```

For a job that mostly exists to run `curl -s https://example.com | grep "healthy"`.

Two AI-driven crons converted to pure shell in April 2026 saved ~$56/day — real money from a small refactor.

## The rule

**If the work the cron does is "grep, parse, compare, alert" — use shell. Reserve AI sessions for genuine reasoning, writing, or judgment calls.**

Most "smart" cron jobs don't actually need AI. They need:

- Check if a file/URL/service exists or responds → `curl -sf`, `test -f`
- Parse a JSON response for a value → `python3 -c "import sys,json; print(json.load(sys.stdin)['field'])"` or `jq`
- Compare today's value to yesterday's → a single `diff` or subtraction
- Send an alert → `curl` to Telegram

None of that is AI work. An LLM doing it is slower, more expensive, and *less* reliable than 10 lines of bash.

## The order of preference (repeat of the philosophy)

1. **Pure shell** — fastest, cheapest, most deterministic
2. **Python** — when you need regex, JSON manipulation, or library support
3. **A real CLI tool** — `gh`, `aws`, `rclone`, `jq`, whatever wraps the API you need
4. **An MCP call via the gateway** — if the cron needs an authenticated service call
5. **An AI session** — only if real reasoning is involved

Almost every "task" can be solved at levels 1-3. Level 4 and 5 should be rare.

## When to use AI in a cron

- **Classification with gray areas** — "is this email a high-priority request or a low-priority update?" where rules don't fully capture it
- **Writing** — morning brief synthesizing overnight events into a paragraph
- **Decision under ambiguity** — "three things are slightly off; which is most urgent?"
- **One-shot reasoning** — "given these 20 numbers, is there an anomaly?"

Even then, pass `--light-context` to skip the full workspace prompt:

```bash
openclaw cron add --light-context "classify overnight email importance" ...
```

Light context drops the per-session cost from ~$0.19 to ~$0.02.

## Real examples from this setup

**Pure shell (cheap):**
- Rate limit check — every 5 min, curl to API, parse remaining-quota header, alert if < 10%
- Utility outage monitor — every 30 min, curl to RSS feed, check for new items with my address
- Upstream status page monitor — every 30 min, curl to status.io JSON, alert on change

**AI (warranted):**
- Morning brief — once a day, 5 AM, synthesizes overnight email + calendar + Reddit into a paragraph
- Client attention check — once a day, decides if any client relationships need outreach today based on last-contacted signals
- Conversion anomaly detector — hourly, looks at ad conversion trend and flags unusual patterns

**The split is roughly 3:1 shell-to-AI.** Could easily be 4:1 — every AI cron is worth questioning.

## A template for any cron

See [`scripts/templates/cron-wrapper.sh`](../scripts/templates/cron-wrapper.sh). It adds:

- File lock (prevents overlapping runs)
- Timeout (kills runaway jobs)
- Telegram alert on failure (with exit code + runtime)
- Status log (per-job, rotatable)

Usage:

```bash
# In crontab:
0 4 * * * /usr/local/bin/cron-wrapper.sh my-backup /path/to/actual-backup.sh
```

The wrapper never adds AI to a shell job. It adds *observability* to a shell job.

## Detecting which of your crons should drop AI

For each AI-driven cron, ask:

1. Does the job's output depend on model judgment, or could a rule replicate it?
2. If the model were replaced with "always output OK", would the job still be useful 95% of the time?
3. When the model does flag something, is that flag actionable without human review?

If #2 is yes and #3 is "the AI's opinion doesn't actually change what I do" — drop AI, write 10 lines of shell.

## Observability for shell crons

Shell jobs should still feel observable. The pattern:

```bash
#!/bin/bash
set -euo pipefail
source /etc/openclaw/env.sh
source /usr/local/openclaw-patterns/scripts/lib/alert.sh

START_EPOCH=$(date +%s)
LOG=/var/log/my-cron.log

# ... do the work ...

if [ "$something_wrong" ]; then
  alert CRITICAL "check name" "Specific error detail here"
  exit 1
fi

echo "[$(date)] OK" >> "$LOG"
```

Same alert function as the AI crons. Same Telegram surface. Same visibility. Just without the token cost.

## The meta point

Cost discipline isn't austerity for its own sake. Every dollar an AI cron wastes is a dollar you don't spend on the AI sessions that actually benefit from reasoning. Same principle as not paying a senior consultant to sort your inbox.
