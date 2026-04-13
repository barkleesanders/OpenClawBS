#!/bin/bash
# pre-bash.sh — PreToolUse hook for the Bash tool in Claude Code
#
# Runs before EVERY bash command the AI tries to execute. Use it as a last-line
# safety gate for things that shouldn't happen. Exit 0 to allow; exit non-zero
# with a message to stderr to block.
#
# Install in ~/.claude/settings.json:
#   "hooks": {
#     "PreToolUse": [{
#       "matcher": { "tool": "Bash" },
#       "hooks": [
#         { "type": "command", "command": "$HOME/.claude/hooks/pre-bash.sh" }
#       ]
#     }]
#   }
#
# The hook receives the bash command as $1 (set by Claude Code).
# This is the one place in the whole stack where you can prevent a destructive
# command from running regardless of what the AI thinks is a good idea.

set -u

CMD="${1:-}"

# Block patterns that should ALMOST NEVER run unattended
# (Override by setting ALLOW_DANGEROUS=1 for a single command when you really mean it)
if [ "${ALLOW_DANGEROUS:-0}" != "1" ]; then
  case "$CMD" in
    *"rm -rf /"*|*"rm -rf ~"*|*"rm -rf \$HOME"*)
      echo "pre-bash: BLOCKED — 'rm -rf /' family. Set ALLOW_DANGEROUS=1 if you really mean it." >&2
      exit 1
      ;;
    *"git push --force"*|*"git push -f "*)
      echo "pre-bash: BLOCKED — force-push. Use 'git push --force-with-lease' or set ALLOW_DANGEROUS=1." >&2
      exit 1
      ;;
    *"DROP DATABASE"*|*"DROP TABLE"*|*"TRUNCATE TABLE"*)
      echo "pre-bash: BLOCKED — destructive SQL. Set ALLOW_DANGEROUS=1 if intended." >&2
      exit 1
      ;;
    *"curl"*"| bash"*|*"curl"*"| sh"*|*"wget"*"| bash"*|*"wget"*"| sh"*)
      echo "pre-bash: BLOCKED — piping curl/wget to a shell. Download, inspect, then run." >&2
      exit 1
      ;;
  esac
fi

exit 0
