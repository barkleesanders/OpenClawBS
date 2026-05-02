#!/usr/bin/env bash
# install.sh — One-line bootstrap for OpenClawBS.
#
# Run this from any fresh machine (macOS canonical, Linux legacy):
#   curl -fsSL https://raw.githubusercontent.com/barkleesanders/OpenClawBS/main/install.sh | bash
#
# What it does:
#   1. Detects OS (macOS → launchd path, Linux → punts to legacy/quick-install.sh)
#   2. Verifies prerequisites (git, curl, brew on macOS)
#   3. Installs OpenClaw via brew if missing
#   4. Clones (or fast-forwards) the repo to ~/.openclaw-patterns
#   5. Renders the LaunchAgent + env-wrapper + env templates with your username
#   6. Seeds a fresh workspace at ~/clawd from workspace/ templates
#   7. Prints the remaining manual steps (fill secrets → bootstrap LaunchAgent)
#
# What it does NOT do:
#   - Start any services (no launchctl bootstrap, no systemctl start)
#   - Prompt for secrets, write secrets to disk, or transmit secrets anywhere
#   - Overwrite an existing ~/clawd workspace, env file, or LaunchAgent plist
#   - Touch your ~/.claude or any in-flight agent state
#
# Override defaults via env vars:
#   OPENCLAWBS_REPO_URL=...      (default: https://github.com/barkleesanders/OpenClawBS.git)
#   OPENCLAWBS_INSTALL_DIR=...   (default: ~/.openclaw-patterns)
#   OPENCLAWBS_WORKSPACE=...     (default: ~/clawd)
#
# Re-runnable. All file writes are no-clobber (cp -n) or guarded by file-exists checks.

set -euo pipefail

# --- Config -------------------------------------------------------------------
REPO_URL="${OPENCLAWBS_REPO_URL:-https://github.com/barkleesanders/OpenClawBS.git}"
INSTALL_DIR="${OPENCLAWBS_INSTALL_DIR:-${HOME}/.openclaw-patterns}"
WORKSPACE_DIR="${OPENCLAWBS_WORKSPACE:-${HOME}/clawd}"
OPENCLAW_HOME="${HOME}/.openclaw"
SERVICE_ENV_DIR="${OPENCLAW_HOME}/service-env"
LAUNCHAGENTS_DIR="${HOME}/Library/LaunchAgents"

# --- Output helpers -----------------------------------------------------------
bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "  → %s\n" "$*"; }
warn() { printf "  ⚠ %s\n" "$*" >&2; }
fail() { printf "  ✗ %s\n" "$*" >&2; exit 1; }
ok()   { printf "  ✓ %s\n" "$*"; }

# --- Detect OS ----------------------------------------------------------------
case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)  OS=linux ;;
    *)      fail "Unsupported OS: $(uname -s)" ;;
esac

# --- Banner -------------------------------------------------------------------
bold "OpenClawBS bootstrap (${OS})"
echo
cat <<EOF
This will:
  • Clone (or update) ${REPO_URL} → ${INSTALL_DIR}
  • Seed a workspace at ${WORKSPACE_DIR} (only if it doesn't exist)
EOF

if [ "$OS" = "macos" ]; then
cat <<EOF
  • Install OpenClaw via Homebrew if missing
  • Render LaunchAgent templates → ~/Library/LaunchAgents/ + ~/.openclaw/service-env/
  • chmod 600 the env file (so you can safely paste secrets into it)
EOF
fi

cat <<EOF

It will NOT:
  • Start any service or run launchctl/systemctl
  • Ask you for or write any secret
  • Overwrite existing config

EOF

# --- Step 1: Prerequisites ----------------------------------------------------
info "Checking prerequisites…"
command -v git  >/dev/null 2>&1 || fail "git not found. Install it and re-run."
command -v curl >/dev/null 2>&1 || fail "curl not found. Install it and re-run."

if [ "$OS" = "macos" ]; then
    if ! command -v brew >/dev/null 2>&1; then
        fail "Homebrew not found. Install from https://brew.sh then re-run this script."
    fi
    if ! command -v openclaw >/dev/null 2>&1; then
        info "Installing OpenClaw via Homebrew…"
        brew install openclaw || fail "brew install openclaw failed"
    fi
    ok "OpenClaw: $(openclaw --version 2>/dev/null | head -1)"
elif [ "$OS" = "linux" ]; then
    if ! command -v openclaw >/dev/null 2>&1; then
        warn "OpenClaw not found on this Linux host."
        warn "The legacy/Linux path uses a separate quick-install.sh under legacy/."
        echo
        info "Re-run this instead:"
        echo "  curl -fsSL https://raw.githubusercontent.com/barkleesanders/OpenClawBS/main/legacy/scripts/install/quick-install.sh | bash"
        exit 0
    fi
    ok "OpenClaw: $(openclaw --version 2>/dev/null | head -1)"
fi

# --- Step 2: Clone or update the repo ----------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
    info "Updating existing repo at $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only --quiet \
        || warn "git pull failed (network? local edits?) — continuing with current checkout"
else
    info "Cloning $REPO_URL → $INSTALL_DIR"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
fi
chmod +x "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR"/scripts/lib/*.sh \
         "$INSTALL_DIR"/scripts/templates/*.sh 2>/dev/null || true
ok "Repo at $INSTALL_DIR"

# --- Step 3: Bootstrap the workspace -----------------------------------------
if [ -d "$WORKSPACE_DIR" ] && [ -n "$(ls -A "$WORKSPACE_DIR" 2>/dev/null)" ]; then
    ok "Workspace already populated at $WORKSPACE_DIR (skipping)"
else
    info "Seeding workspace at $WORKSPACE_DIR"
    mkdir -p "$WORKSPACE_DIR/memory"
    for f in SOUL.md AGENTS.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md; do
        [ -f "$INSTALL_DIR/workspace/$f" ] && cp -n "$INSTALL_DIR/workspace/$f" "$WORKSPACE_DIR/$f"
    done
    [ -f "$INSTALL_DIR/workspace/IDENTITY.md.template" ] \
        && cp -n "$INSTALL_DIR/workspace/IDENTITY.md.template" "$WORKSPACE_DIR/IDENTITY.md"
    [ -f "$INSTALL_DIR/workspace/USER.md.template" ] \
        && cp -n "$INSTALL_DIR/workspace/USER.md.template" "$WORKSPACE_DIR/USER.md"
    [ ! -f "$WORKSPACE_DIR/MEMORY.md" ] && : > "$WORKSPACE_DIR/MEMORY.md"
    ok "Workspace seeded"
fi

# --- Step 4: macOS LaunchAgent templates (no auto-start) ---------------------
if [ "$OS" = "macos" ]; then
    info "Rendering launchd templates…"
    mkdir -p "$SERVICE_ENV_DIR" "$OPENCLAW_HOME/logs" "$LAUNCHAGENTS_DIR"
    USERNAME=$(id -un)

    PLIST_DEST="$LAUNCHAGENTS_DIR/ai.openclaw.gateway.plist"
    if [ ! -f "$PLIST_DEST" ]; then
        sed "s/YOUR_USERNAME/${USERNAME}/g" \
            "$INSTALL_DIR/launchd/ai.openclaw.gateway.plist.template" > "$PLIST_DEST"
        ok "Wrote $PLIST_DEST"
    else
        ok "$PLIST_DEST exists — leaving untouched"
    fi

    WRAPPER_DEST="$SERVICE_ENV_DIR/ai.openclaw.gateway-env-wrapper.sh"
    if [ ! -f "$WRAPPER_DEST" ]; then
        cp "$INSTALL_DIR/launchd/ai.openclaw.gateway-env-wrapper.sh.template" "$WRAPPER_DEST"
        chmod 700 "$WRAPPER_DEST"
        ok "Wrote $WRAPPER_DEST (mode 700)"
    else
        ok "$WRAPPER_DEST exists — leaving untouched"
    fi

    ENV_DEST="$SERVICE_ENV_DIR/ai.openclaw.gateway.env"
    if [ ! -f "$ENV_DEST" ]; then
        cp "$INSTALL_DIR/launchd/ai.openclaw.gateway-env.template" "$ENV_DEST"
        chmod 600 "$ENV_DEST"
        ok "Wrote $ENV_DEST (mode 600 — paste secrets here)"
    else
        ok "$ENV_DEST exists — leaving untouched (your secrets are safe)"
    fi
fi

# --- Done ---------------------------------------------------------------------
echo
bold "Bootstrap complete."
echo

if [ "$OS" = "macos" ]; then
cat <<EOF
Next steps (manual — nothing is running yet):

  1. Fill in your secrets:
       \$EDITOR ${SERVICE_ENV_DIR}/ai.openclaw.gateway.env

     Required: COMPOSIO_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
     Optional: DRIVE_ROOT_FOLDER_ID, OPENAI_API_KEY, ANTHROPIC_API_KEY

  2. Bootstrap the LaunchAgent (gateway will start + bind 127.0.0.1:18789):
       launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist

  3. Verify (in any order):
       launchctl print gui/\$(id -u)/ai.openclaw.gateway | grep state
       lsof -nP -iTCP:18789 -sTCP:LISTEN
       openclaw config        # interactive — confirm model + workspace

  4. Walk through (or hand to your agent):
       ${WORKSPACE_DIR}/IDENTITY.md   # the agent's name + voice
       ${WORKSPACE_DIR}/USER.md       # who you are
       ${WORKSPACE_DIR}/AGENTS.md     # operating rules

  5. Read:
       ${INSTALL_DIR}/README.md
       ${INSTALL_DIR}/launchd/README.md

Update later with:
  git -C ${INSTALL_DIR} pull
EOF
fi

if [ "$OS" = "linux" ]; then
cat <<EOF
Next steps (manual — nothing is running yet):

  1. Run the legacy/Linux installer for systemd unit + /etc/openclaw/env.sh:
       sudo bash ${INSTALL_DIR}/legacy/scripts/install/quick-install.sh

  2. Walk through (or hand to your agent):
       ${WORKSPACE_DIR}/IDENTITY.md
       ${WORKSPACE_DIR}/USER.md
       ${WORKSPACE_DIR}/AGENTS.md

  3. Read:
       ${INSTALL_DIR}/README.md
       ${INSTALL_DIR}/legacy/README.md
EOF
fi
