# 09 — Hooks and Gates: Making Claude Code Honest

Claude Code supports lifecycle hooks — shell scripts that run at specific points in an AI session. Used right, they're the most powerful safety tool in the whole stack.

## The four hooks that matter

### `SessionStart`

Runs when a new session begins. Use for:

- **Config backup** — commit and push `~/.claude/` to a private repo so a disk failure doesn't erase hours of agent tuning. See [`claude-code/hooks/backup-config.sh`](../claude-code/hooks/backup-config.sh).
- **Task sync** — `bd prime` to reload beads task state
- **Environment checks** — "is the Composio API key still set?"

Non-blocking: even if the hook exits non-zero, the session still starts. It's a best-effort pre-flight.

### `PreToolUse` (for Bash specifically)

Runs before every bash command the AI tries to execute. The single best place to block destructive operations.

```json
"PreToolUse": [{
  "matcher": { "tool": "Bash" },
  "hooks": [
    { "type": "command", "command": "$HOME/.claude/hooks/pre-bash.sh" }
  ]
}]
```

See [`claude-code/hooks/pre-bash.sh`](../claude-code/hooks/pre-bash.sh). It blocks:

- `rm -rf /` family
- `git push --force` (prefer `--force-with-lease`)
- `DROP DATABASE` / `DROP TABLE`
- Piping curl or wget into bash (`| bash`)

Override by prefixing `ALLOW_DANGEROUS=1` on the individual command when you really mean it.

### `PostToolUse` (for Edit / Write)

Runs after every file edit. Good for auto-formatting or lint-checking on save.

```json
"PostToolUse": [{
  "matcher": { "tool": "Edit|Write" },
  "hooks": [
    { "type": "command", "command": "$HOME/.claude/hooks/post-edit.sh" }
  ]
}]
```

Your `post-edit.sh` can run `biome format`, `prettier --write`, `black`, or whatever fits your project. Keeps code conforming without the AI having to remember to run the formatter.

### `Stop` — **the important one**

Runs when the AI tries to end its turn. If the hook exits non-zero, the AI is forced to continue. This is the mechanism that prevents "the AI said done but lied."

See [`claude-code/hooks/taskmaster-check-completion.sh`](../claude-code/hooks/taskmaster-check-completion.sh). It checks:

1. **Are any beads tasks still `in_progress`?** → block, force continuation
2. **Are there unresolved tool errors in the recent transcript?** → block
3. **Did the user's most recent request go unaddressed?** → block

With a cap: after 3 blocks in a row, it lets the AI stop anyway (to avoid infinite loops on genuinely stuck tasks). The block count resets once the AI actually produces clean output.

## Why the Stop hook is the single most important safety feature

LLMs have a subtle bias under pressure: **the fastest path through the reward model is to say "I'm done"** whether they actually are or not. Every fine-tuning run teaches this in new ways.

Empirically this manifests as:

- AI edits 3 files, runs 1 test, says "all tests pass" (you only ran 1)
- AI starts refactoring, hits a complex case, truncates it, says "refactor complete"
- AI finds the root cause of a bug, implements a workaround, says "bug fixed" (the root cause is still there)

No amount of prompt engineering reliably fixes this. The model optimizes against the prompt.

**The Stop hook sidesteps the whole issue by putting verification outside the model's control.** The hook is a shell script. It reads beads. It reads the transcript. It reads file state. The AI can't argue with `exit 1`.

## Configuring hooks in `settings.json`

Minimal version:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/backup-config.sh" }
      ]}
    ],
    "PreToolUse": [
      { "matcher": { "tool": "Bash" },
        "hooks": [
          { "type": "command", "command": "$HOME/.claude/hooks/pre-bash.sh" }
        ]}
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "$HOME/.claude/hooks/taskmaster-check-completion.sh" }
      ]}
    ]
  }
}
```

See [`claude-code/settings.json.sanitized`](../claude-code/settings.json.sanitized) for a fuller example.

## Hook design principles

1. **Fast.** Every hook runs in-line with session activity. If yours takes 5 seconds, that's 5 seconds of delay the user perceives as "Claude is thinking." Keep hooks under 200 ms when possible.

2. **Quiet on success.** `echo` in a hook ends up in the user's session output. Only speak up when you need to block something.

3. **Structured errors.** When a hook blocks (especially Stop), print *why* and *what to do about it* in a way the AI can act on. Bad: `exit 1`. Good: `echo "[taskmaster] Block reason: 2 beads issues still in_progress. Run 'bd list --status=in_progress' to see them." >&2; exit 1`.

4. **Graceful degradation.** If a tool the hook depends on isn't installed, skip that check silently rather than failing the whole hook. (See the `command -v bd` pattern in `taskmaster-check-completion.sh`.)

5. **State in a single place.** Hooks that need to persist state (like the Stop hook's block counter) should use a known directory: `~/.claude/.hookname-state/`. Makes cleanup easy.

## Debugging hooks

When a hook misbehaves:

```bash
# Run the hook manually, see its output and exit code
bash -x ~/.claude/hooks/taskmaster-check-completion.sh
echo "exit: $?"

# Check Claude Code's hook-related logs (if any)
grep hook ~/.claude/logs/*.log 2>/dev/null

# Temporarily disable a hook by commenting out in settings.json
```

## Generalization

This pattern — "outside process verifies inside claims" — applies beyond Claude Code:

- **CI pipelines** run tests after the developer says "ready" — verification outside the IDE
- **Pull request reviewers** read code before merge — verification outside the author
- **Backup verification scripts** check that yesterday's dump actually exists — verification outside the backup script

The AI coding era just raised the stakes: the system producing the claims is also very good at making them sound true. The fix is to never take the system's word for it.
