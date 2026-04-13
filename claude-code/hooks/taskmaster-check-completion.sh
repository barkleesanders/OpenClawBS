#!/bin/bash
# taskmaster-check-completion.sh — Stop-hook gate for Claude Code
#
# This is the hook that prevents "the AI said it was done but lied" failures.
# It runs when Claude Code tries to end a session. If anything is unresolved,
# it exits non-zero and Claude Code will force the AI to continue.
#
# Install in ~/.claude/settings.json:
#   "hooks": {
#     "Stop": [{
#       "hooks": [
#         { "type": "command", "command": "$HOME/.claude/hooks/taskmaster-check-completion.sh" }
#       ]
#     }]
#   }
#
# The hook is allowed to block up to 3 times in a row (gives the AI
# three chances to actually finish its work). After that we let it stop
# to avoid infinite loops on genuinely stuck tasks.

set -u
SELF_NAME="taskmaster"

STATE_DIR="${HOME}/.claude/.taskmaster-state"
mkdir -p "$STATE_DIR"

BLOCK_COUNT_FILE="$STATE_DIR/block-count"
MAX_BLOCKS=3

# Read current block count
if [ -f "$BLOCK_COUNT_FILE" ]; then
  count=$(cat "$BLOCK_COUNT_FILE" 2>/dev/null || echo 0)
else
  count=0
fi

# -------- Check for unresolved work --------

issues=""

# 1. Pending beads (if beads is installed in this repo)
if command -v bd >/dev/null 2>&1; then
  if [ -d .beads ] || bd list --status=open 2>/dev/null | grep -q .; then
    open_count=$(bd list --status=in_progress 2>/dev/null | grep -cE '^[a-zA-Z0-9_-]+-[0-9]+' || echo 0)
    if [ "${open_count:-0}" -gt 0 ]; then
      issues="${issues}  - ${open_count} beads issue(s) still in_progress\n"
    fi
  fi
fi

# 2. Uncommitted changes in a clean-tree context (optional, only if .claude/strict-git exists)
if [ -f .claude/strict-git ] && command -v git >/dev/null 2>&1; then
  if git rev-parse --git-dir >/dev/null 2>&1; then
    if ! git diff --quiet HEAD 2>/dev/null; then
      issues="${issues}  - Git working tree has uncommitted changes\n"
    fi
  fi
fi

# 3. Recent tool errors in session transcript (heuristic — look for the last
#    100 lines of the transcript if we can find it)
# (The Claude Code settings.json transcript env var would be used here if
#  available; falls back to no-op if not.)

# -------- Decide --------

if [ -z "$issues" ]; then
  # Nothing unresolved — allow stop
  echo 0 > "$BLOCK_COUNT_FILE"
  exit 0
fi

count=$((count + 1))
echo "$count" > "$BLOCK_COUNT_FILE"

if [ "$count" -ge "$MAX_BLOCKS" ]; then
  # Three strikes — let the AI stop to avoid an infinite block loop
  echo "[$SELF_NAME] ($count/$MAX_BLOCKS) Unresolved but letting stop proceed:" >&2
  printf "%b" "$issues" >&2
  echo 0 > "$BLOCK_COUNT_FILE"
  exit 0
fi

# Block the stop — print a structured reason the AI can act on
cat >&2 <<EOF
[$SELF_NAME] ($count/$MAX_BLOCKS) Stop blocked — unresolved work:

$(printf "%b" "$issues")

Before stopping, please:
  1. Resolve the above items, or
  2. Document in beads why they're deferred, or
  3. Explicitly confirm with the user that deferral is OK.

If everything truly is done, re-run and the block count resets.
EOF

exit 1
