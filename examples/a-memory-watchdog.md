# Example: Memory watchdog for any long-running service

`memory-guardian.sh` is written for the OpenClaw gateway, but the pattern generalizes to any systemd-managed long-running process on a small VPS. This walkthrough adapts it for a generic service.

## Why you'd want this

Long-running Node/Python/Ruby processes grow over time. They don't always leak dramatically — often it's just the GC falling behind, a cache not being evicted, or a browser process not being cleaned up. The kernel OOM killer eventually notices at an inconvenient hour and picks the biggest process, which is usually the one you care about most.

The guardian catches the drift before the kernel does, restarts gracefully, and alerts you.

## Adapting the script

Copy the template:

```bash
sudo cp /usr/local/openclaw-patterns/scripts/memory-guardian.sh /usr/local/bin/my-service-guardian.sh
sudo "$EDITOR" /usr/local/bin/my-service-guardian.sh
```

Change these constants near the top:

```bash
# Service to guard
GATEWAY_SERVICE="my-service.service"

# Thresholds — adjust for your VPS size
MAX_RSS_MB=3200            # Restart if RSS exceeds this
MIN_AVAIL_MB=200            # Restart if system free RAM drops below this
```

For a 16 GB VPS: `MAX_RSS_MB=12000 MIN_AVAIL_MB=1000`.
For a 1 GB VPS: `MAX_RSS_MB=700 MIN_AVAIL_MB=100`.

Remove the Chrome-specific checks if your service doesn't use browser automation:

```bash
# Delete lines that reference chrome-state.json and stale chrome processes
# Or leave them — they're no-ops if the file doesn't exist
```

## Install

```bash
sudo chmod +x /usr/local/bin/my-service-guardian.sh

# Schedule every 5 minutes
sudo crontab -e
```

Add:

```cron
*/5 * * * * . /etc/openclaw/env.sh && /usr/local/bin/my-service-guardian.sh >> /var/log/my-service-guardian.log 2>&1
```

## Tune the thresholds

First week:

```bash
# Collect RSS data without triggering restarts
# Temporarily set MAX_RSS_MB very high and log only
tail -f /var/log/my-service-guardian.log | grep "RSS="
```

Watch the steady-state RSS for a few days. Set `MAX_RSS_MB` to ~2x steady state. That's the sweet spot: high enough not to trigger on normal variation, low enough to catch real growth before OOM.

## Telegram alerts

The guardian alerts on every restart it triggers, with:

- Severity (`CRITICAL` for OOM-prevention, `WARNING` for partial recovery)
- The reason (RSS=3300 > limit 3200, or System RAM=120 < minimum 200)
- Timestamp + runtime
- Post-restart available RAM

You want to see ~zero of these per week in steady state. If you see one every day, the underlying service has a real leak — go fix it, don't just crank the threshold.

## What it doesn't do

- Won't recover from actual OOM kills that happen in between checks (5 min is the resolution)
- Won't help if the service crashes for reasons unrelated to memory
- Won't replace proper profiling for real leaks

It's a safety net, not a fix for broken code.

## Observability

Quick glance at guardian health:

```bash
# Last 20 check results
tail -20 /var/log/my-service-guardian.log

# Restart events in the last month
grep RESTART /var/log/my-service-guardian.log

# RSS trend
grep "Gateway RSS" /var/log/my-service-guardian.log | awk -F'RSS=' '{print $2}' | awk '{print $1}' | sort -n | uniq -c | tail -10
```

## Generalization beyond systemd

The same pattern works for Docker containers, systemd user services, supervisord-managed processes, anything with a PID. Adapt `is_gateway_active()` and `restart_gateway()` to your orchestrator:

```bash
# Docker version
is_service_active() { docker inspect --format='{{.State.Running}}' my-container 2>/dev/null | grep -q true; }
restart_service() { docker restart my-container; }
```

The rest of the script (memory checks, alerts, lock file, verification wait) stays identical.
