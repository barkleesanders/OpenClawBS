# 05 — Memory Guardian: OOM Prevention on a Small VPS

## Why this exists

On a 3.7 GB VPS, the OpenClaw gateway process grows to ~1.5 GB steady state and occasionally spikes to 2.5 GB+. Chrome sessions (for browser automation) each eat another 200-500 MB. A small SQLite database grows over time. None of this individually crashes anything — but the slow drift eventually hits the kernel OOM killer at 3 AM, the OOM killer picks "biggest process" (the gateway), and the Telegram bot goes dark until I notice in the morning.

The fix is a stupidly simple cron script that checks four things every 5 minutes and restarts the gateway before the kernel has to.

See [`scripts/memory-guardian.sh`](../scripts/memory-guardian.sh).

## What it checks

1. **Gateway process alive** — `systemctl is-active openclaw-gateway.service`. If not, restart.
2. **Gateway RSS** — `/proc/<pid>/status`'s `VmRSS:`. If > `MAX_RSS_MB` (default 3200 MB), restart.
3. **System available memory** — `/proc/meminfo`'s `MemAvailable:`. If < `MIN_AVAIL_MB` (default 200 MB), kill stale Chrome processes, drop caches, restart gateway.
4. **Chrome state file** — `chrome-state.json` size. If > `MAX_CHROME_STATE_MB` (default 10 MB), truncate to `{}`.

## What it does on trigger

1. Use `systemctl restart` (never `kill -9`) — respects systemd's restart semantics
2. Drop kernel caches (`sync && echo 3 > /proc/sys/vm/drop_caches`)
3. Kill stale Chrome processes (any `chrome.*agent-browser` older than 1 hour)
4. Wait up to 90 seconds for the Telegram provider to reconnect (verified via journalctl grep)
5. If reconnection succeeds: send a Telegram "Gateway Auto-Recovery" message with the reason, runtime, RAM snapshot
6. If reconnection fails after 2 retries: send a "Recovery PARTIAL" warning and let a human take over

## Lock-file safety

The script takes a file lock at `/tmp/memory-guardian.lock`. If a previous run is still going (shouldn't happen, but could under load), the new run exits immediately. The lock self-expires after 5 minutes in case something crashes while holding it.

## Why the thresholds are what they are

- **`MAX_RSS_MB=3200`** is well above steady state (~1500 MB). Triggers only for real issues, not noise.
- **`MIN_AVAIL_MB=200`** is tight but not panicked. At 200 MB free, you've got maybe 5 minutes before OOM. Enough time to do a clean restart.
- **`MAX_CHROME_STATE_MB=10`** — observed that beyond 10 MB, the file represents stale session data that slows restart. Truncating loses some auto-login state but is never fatal.

Tune these to your VPS. On a 16 GB box, `MAX_RSS_MB=12000` / `MIN_AVAIL_MB=1000` is more sensible.

## Why not cgroups

systemd can enforce memory limits via `MemoryMax=`. Why don't we?

**Because cgroup OOM kills produce harder-to-debug symptoms.** A cgroup-killed process leaves no trace in its own logs. You have to cross-reference `journalctl -u systemd-oomd` with the process logs to understand what happened. By contrast, the guardian:

- Logs every check (the trend is visible)
- Telegram-alerts every restart (you know when it happened)
- Waits for verification (the new process actually comes up)
- Has controlled restart timing (not whenever the kernel feels like it)

Cgroups *work*, but the forensics are worse.

## Install

```bash
sudo cp scripts/memory-guardian.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/memory-guardian.sh

# Add to cron (as root, since it uses systemctl):
sudo crontab -e
# Add this line:
*/5 * * * * TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... /usr/local/bin/memory-guardian.sh >> /var/log/memory-guardian.log 2>&1
```

Or put the env vars in `/etc/openclaw/env.sh` and source it:

```cron
*/5 * * * * . /etc/openclaw/env.sh && /usr/local/bin/memory-guardian.sh >> /var/log/memory-guardian.log 2>&1
```

## Observing it

```bash
# Recent guardian activity
tail -f /var/log/memory-guardian.log

# Guardian-triggered restarts in the last day
grep RESTART /var/log/memory-guardian.log | grep "$(date +%Y-%m-%d)"

# Gateway RSS trend (quick visual)
grep "Gateway RSS" /var/log/memory-guardian.log | tail -20
```

If you see `RESTART` more than ~once a day, something else is wrong — investigate the underlying memory growth. The guardian is a safety net, not a substitute for fixing actual leaks.

## Generalization

This pattern works for any long-running process on a resource-constrained server:

- Swap `openclaw-gateway.service` for any systemd unit name
- Adjust the thresholds
- Keep the lock-file + Telegram-verification pattern

It's about 8 KB of shell for ~97% less "woke up to a dead service" incidents.
