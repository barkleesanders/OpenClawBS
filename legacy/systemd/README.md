# systemd/

Reference systemd unit for the OpenClaw gateway, plus a drop-in pattern for keeping secrets out of the main unit file.

## Files

- **`openclaw-gateway.service`** — main unit. Generic, safe to keep in git. Defines restart policy, port cleanup on start, logging, heap size.
- **`openclaw-gateway.service.d/env.conf.template`** — drop-in override. Copy this to `env.conf` (not `.template`), chmod 600, fill in. This is where `EnvironmentFile` and any sandbox flags go.

## Install

```bash
sudo cp openclaw-gateway.service /etc/systemd/system/openclaw-gateway.service
sudo mkdir -p /etc/systemd/system/openclaw-gateway.service.d
sudo cp openclaw-gateway.service.d/env.conf.template \
        /etc/systemd/system/openclaw-gateway.service.d/env.conf
# Edit env.conf as needed, then:
sudo chmod 600 /etc/systemd/system/openclaw-gateway.service.d/env.conf
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-gateway
```

## Why the drop-in split

Two reasons:

1. **You can track `openclaw-gateway.service` in git without leaking secrets.** The unit file is the same across every machine; the `env.conf` is per-machine and stays out of version control.
2. **You can change environment variables without editing the unit.** `systemctl daemon-reload && systemctl restart openclaw-gateway` picks up new vars without touching the main definition.

## Memory policy

The unit deliberately has **no cgroup memory limit**. Instead:

- `NODE_OPTIONS=--max-old-space-size=3072` caps V8 heap at 3 GB (safe on a 3.7 GB RAM VPS)
- `scripts/memory-guardian.sh` runs every 5 minutes and triggers `systemctl restart` before the kernel's OOM killer does

This is a deliberate trade: cgroup limits produce harder-to-debug kills and can mask real memory growth; the guardian gives you a Telegram alert + graceful restart + forensic logs instead.

## Restart policy

```
Restart=always
RestartSec=15s
StartLimitIntervalSec=600
StartLimitBurst=15
```

Up to 15 restarts in any 10-minute window before systemd stops trying. The guardian kicks in at the ~5-minute mark for issues systemd can't see (RSS trending up but not crashing, browser state balooning, etc.).
