# OpenClaw Operations Templates

Reference scripts for running OpenClaw on a small VPS. Each one is a
thin wrapper around OpenClaw's native commands — follow the
[Native-First rule](../../docs/12-openclaw-native-first.md) when
adapting them to your box.

## Files

| File | Purpose |
|------|---------|
| `openclaw-auto-update.sh` | Daily update wrapper. Calls `openclaw update` natively, snapshots `/usr/lib/node_modules/openclaw` first, runs a post-update health gate, rolls back from snapshot on failure, alerts Telegram out-of-band. |
| `openclaw-integrity-check.sh` | systemd `ExecStartPre` guard. Catches the "chunk-hash mismatch after crashed install" failure mode and restores from snapshot before the gateway starts. |
| `openclaw-integrity.conf` | Drop-in that wires the integrity check into `openclaw-gateway.service`. Does NOT modify the main unit. |

## Install

```bash
# Auto-update script (runs daily via cron)
install -m 755 openclaw-auto-update.sh /root/.openclaw/scripts/auto-update.sh
( crontab -l 2>/dev/null; echo '0 0 * * * /root/.openclaw/scripts/auto-update.sh >> /root/.openclaw/logs/auto-update.log 2>&1' ) | crontab -

# Integrity guard
sudo install -m 755 openclaw-integrity-check.sh /usr/local/sbin/openclaw-integrity-check.sh
sudo mkdir -p /etc/systemd/system/openclaw-gateway.service.d
sudo install -m 644 openclaw-integrity.conf /etc/systemd/system/openclaw-gateway.service.d/integrity.conf
sudo systemctl daemon-reload
```

## Telegram alerts

Both scripts read Telegram credentials by sourcing a shell file that
exports `TG_TOKEN` and `TG_CHAT`. Default location is
`/root/clawd/scripts/notify-telegram.sh` — override via the
`NOTIFY_TELEGRAM_SH` env var. If the file is absent or the creds are
missing, alerts are a silent no-op (not a failure).

## Config via env

All tunable paths / ports / hosts are env-overridable at the top of
each script. Defaults match the OpenClaw VPS reference install
(`/usr/lib/node_modules/openclaw`, port 18789, service
`openclaw-gateway.service`).

## Why so thin

These scripts delegate 99% of the work to `openclaw update`,
`openclaw doctor`, and the OpenClaw-managed gateway service. The
*only* value we add is a rollback path that OpenClaw doesn't ship
natively. Everything else (package install, plugin sync, config
migration, gateway restart, health checks) is openclaw's native
behavior. See [`docs/12-openclaw-native-first.md`](../../docs/12-openclaw-native-first.md)
for the rule and the incident that motivated this design.
