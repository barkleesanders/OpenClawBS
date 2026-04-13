#!/bin/bash
# backup-config.sh — SessionStart hook that commits & pushes your Claude Code
# config to a private GitHub repo whenever you start a session.
#
# Why: ~/.claude/ contains hours of agent-tuning work. Losing it to a disk
# failure or accidental `rm -rf` is avoidable with a 2-line safety net.
#
# Install in ~/.claude/settings.json:
#   "hooks": {
#     "SessionStart": [{
#       "hooks": [
#         { "type": "command", "command": "$HOME/.claude/hooks/backup-config.sh" }
#       ]
#     }]
#   }
#
# First-time setup:
#   cd ~/.claude && git init
#   git remote add origin git@github.com:YOUR_USER/claude-code-config.git  # PRIVATE repo
#   # Make sure .gitignore excludes session tokens / caches / projects/
#
# The hook is silent on no-ops and never blocks session start.

set -u

CLAUDE_DIR="${HOME}/.claude"
cd "$CLAUDE_DIR" || exit 0

# Skip if this isn't a git repo (first-time users)
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Skip if nothing to commit
if git diff --quiet && git diff --cached --quiet; then
  exit 0
fi

# Commit any changes with a timestamped message
TS=$(date '+%Y-%m-%d %H:%M:%S')
git add -A 2>/dev/null || true
git commit -m "auto-backup: $TS" --no-verify >/dev/null 2>&1 || true

# Push in the background so session start isn't delayed by network
(git push origin HEAD --no-verify >/dev/null 2>&1 &)

exit 0
