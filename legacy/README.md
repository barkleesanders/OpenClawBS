# legacy/ — preserved Linux/VPS deployment patterns

This directory holds patterns that were the **primary** deployment for
OpenClawBS through April 2026, when the reference setup ran on a Hetzner Cloud
CX23 VPS managed via systemd. The reference VPS was retired on 2026-04-29 in
favor of a Mac mini running launchd ([`launchd/`](../launchd/) is the new
canonical deployment).

The files here are kept as a working starting point for anyone deploying
OpenClawBS on a Linux host (VPS, dedicated server, NAS, etc.). They are not
maintained against the live production system the way `launchd/` is, but they
were known-good as of late April 2026 and reflect a year of running on Hetzner
CX-series boxes.

## Contents

| Path | What it is |
|---|---|
| `scripts/install/quick-install.sh` | One-line installer for a fresh Linux VPS. Sets up `/usr/local/openclaw-patterns/`, `/etc/openclaw/`, and the systemd unit. Replace `REPLACE_ME_WITH_YOUR_USER` in `REPO_URL` before running. |
| `scripts/install/setup-env.sh.template` | Env-file template the installer drops at `/etc/openclaw/env.sh` (chmod 600). |
| `scripts/memory-guardian.sh` | Five-minute cron that watches gateway RSS / system MemAvailable / Chrome state file and proactively restarts via `systemctl` before the kernel OOM killer fires. Designed for ≤4 GB RAM hosts. |
| `systemd/openclaw-gateway.service` | systemd unit for the gateway. Pairs with the drop-in env override at `systemd/openclaw-gateway.service.d/env.conf.template`. |
| `docs/05-memory-guardian.md` | Essay-length walkthrough of the memory-guardian pattern, including its threshold tuning. Linux-specific (uses `/proc`, `systemctl`). |

## When the legacy path still makes sense

- You're running on a $5–$15/mo VPS and don't need iMessage / desktop integrations.
- You want geographic redundancy (Hetzner Falkenstein vs your apartment).
- You're already deep in a Linux toolchain and launchd would be the surprise.

If any of the above applies, start with `scripts/install/quick-install.sh`,
then read [`docs/00-security.md`](../docs/00-security.md) and the legacy
memory-guardian doc before bringing the gateway online.

## When to abandon the legacy path

- You start needing iMessage-connected automation, a webcam, or any local-Mac
  surface (Notes, Shortcuts, Keychain).
- Your cron density crosses ~30 jobs and the 4 GB VPS starts thrashing.
- Three years of CX43 ≈ a base Mac mini purchase. After that the math flips
  hard toward owning the hardware.
