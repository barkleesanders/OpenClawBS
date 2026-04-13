# claude-code/

Laptop-side patterns — how the Claude Code layer complements the VPS.

## Contents

- **`CLAUDE.md.sanitized`** — excerpts from my global `~/.claude/CLAUDE.md` that are generic-useful. Copy sections into your own `CLAUDE.md`.
- **`settings.json.sanitized`** — hook configuration, permission structure, plugin enablement. Keys and personal paths removed.
- **`hooks/`** — the three hook scripts that matter most: Stop (task completion gate), PreToolUse[Bash] (safety), SessionStart (backup).
- **`agents/README.md`** — pattern for per-domain specialist agents.
- **`skills/README.md`** — pattern for super-skills with mode detection.

## Install order

1. Copy `hooks/*.sh` to `~/.claude/hooks/` and `chmod +x` them
2. Merge relevant sections of `CLAUDE.md.sanitized` into your `~/.claude/CLAUDE.md`
3. Merge the hook configuration from `settings.json.sanitized` into your `~/.claude/settings.json`
4. Read `agents/README.md` and `skills/README.md` for patterns; write your own

Each of these is optional. Pick what's useful.
