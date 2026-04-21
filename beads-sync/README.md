# Beads Sync

Sync your beads task database from Mac to VPS so the OpenClaw agent on VPS
can read and write tasks (HOME-* issues) that are visible on your Mac too.

## Why

Beads stores tasks in a local SQLite database (`~/.beads/issues.db`). When the
VPS agent creates a task, it goes into the VPS copy. When your Mac's `bd` CLI
lists tasks, it reads the Mac copy. Without sync, they diverge.

The sync script exports the Mac JSONL file and imports it on VPS via SSH.
VPS changes flow back via beads' built-in JSONL format.

## How it works

```
Mac ~/.beads/issues.jsonl
         |
    (ssh pipe)
         |
VPS: bd import --merge  ← merges into VPS SQLite
```

Direction: Mac → VPS (one-way push from Mac). VPS agent writes new tasks;
those flow back on the next Mac `bd sync` (if you configure bidirectional sync).

## Setup

1. Copy `sync.sh` to `~/tools/beads-sync.sh` on your Mac:
   ```bash
   cp sync.sh ~/tools/beads-sync.sh
   chmod +x ~/tools/beads-sync.sh
   ```

2. Edit the script — set your VPS SSH details:
   ```bash
   VPS_HOST=YOUR_VPS_IP
   VPS_PORT=2222
   ```

3. Test:
   ```bash
   ~/tools/beads-sync.sh
   ```

4. Automate with launchd (Mac) to run every hour:
   ```xml
   <!-- ~/Library/LaunchAgents/com.local.beads-sync.plist -->
   <key>ProgramArguments</key>
   <array>
     <string>/bin/bash</string>
     <string>/Users/YOU/tools/beads-sync.sh</string>
   </array>
   <key>StartInterval</key>
   <integer>3600</integer>
   ```
