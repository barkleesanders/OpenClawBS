# Beads Sync

Sync your beads task database between two hosts via Tailscale SSH so an OpenClaw
agent on one host can read and write tasks (HOME-* issues) that are visible on
the other host too.

> **Status:** The reference deployment was Mac (source) → Linux VPS (target). The
> reference VPS was retired in April 2026, so this directory is preserved as a
> pattern for anyone running a two-host setup. The script in `sync.sh` is now
> host-agnostic — fill in `SOURCE_USER` / `SOURCE_HOST` for your topology.

## Why

Beads stores tasks in a local SQLite database (`~/.beads/issues.db`). When an
agent on host B creates a task, it goes into B's copy. When host A's `bd` CLI
lists tasks, it reads A's copy. Without sync, they diverge.

The sync script pulls the JSONL export from the source host and imports it on
the target host via SSH.

## How it works

```
Source host: ~/.beads/issues.jsonl
         |
    (rsync over Tailscale SSH)
         |
Target host: bd import  ← merges into target SQLite
```

Direction: Source → Target (one-way pull, run from the target). The other side
flows back when you run the inverse on the other host.

## Setup

1. Copy `sync.sh` to a stable path on the **target** host:
   ```bash
   cp sync.sh ~/tools/beads-sync.sh
   chmod +x ~/tools/beads-sync.sh
   ```

2. Set your source host details (or export as env vars):
   ```bash
   export SOURCE_USER=your-source-username   # e.g. macuser
   export SOURCE_HOST=100.x.y.z              # source's Tailscale IP
   ```

3. Test:
   ```bash
   ~/tools/beads-sync.sh
   ```

4. Automate every hour from the target host:

   **launchd (macOS target):** create `~/Library/LaunchAgents/com.local.beads-sync.plist`:
   ```xml
   <key>ProgramArguments</key>
   <array>
     <string>/bin/bash</string>
     <string>/Users/YOU/tools/beads-sync.sh</string>
   </array>
   <key>StartInterval</key>
   <integer>3600</integer>
   <key>EnvironmentVariables</key>
   <dict>
     <key>SOURCE_USER</key><string>your-source-username</string>
     <key>SOURCE_HOST</key><string>100.x.y.z</string>
   </dict>
   ```

   **systemd timer (Linux target):** drop a `beads-sync.service` + `beads-sync.timer`
   pair into `/etc/systemd/system/`. Set `Environment=SOURCE_USER=...` /
   `Environment=SOURCE_HOST=...` in the unit file.
