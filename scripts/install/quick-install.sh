#!/bin/bash
# quick-install.sh — Bootstrap OpenClawBS on a fresh Linux VPS.
#
# Usage (from README):
#   curl -fsSL https://raw.githubusercontent.com/<YOUR-GH-USER>/OpenClawBS/main/scripts/install/quick-install.sh | bash
#
# What this does:
#   1. Clones/updates the repo to /usr/local/openclaw-patterns
#   2. Installs scripts to /usr/local/bin and marks them executable
#   3. Creates /etc/openclaw/ and drops the env.sh template (chmod 600)
#   4. Installs the systemd unit + drop-in template (does NOT start anything)
#   5. Prints next steps
#
# This script does NOT:
#   - start any services
#   - fill in any secrets
#   - contact Composio or Telegram
#   - modify your crontab
#
# Run once, then edit /etc/openclaw/env.sh and follow the printed steps.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/REPLACE_ME_WITH_YOUR_USER/OpenClawBS.git}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/openclaw-patterns}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
ETC_DIR="${ETC_DIR:-/etc/openclaw}"

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "  → %s\n" "$*"; }

bold "OpenClawBS quick-install"
echo

# --- 1. Clone or pull ---
if [ -d "$INSTALL_DIR/.git" ]; then
  info "Updating existing clone at $INSTALL_DIR"
  $SUDO git -C "$INSTALL_DIR" pull --ff-only
else
  info "Cloning to $INSTALL_DIR"
  $SUDO git clone "$REPO_URL" "$INSTALL_DIR"
fi

# --- 2. Install scripts to /usr/local/bin ---
info "Linking scripts into $BIN_DIR"
$SUDO ln -sf "$INSTALL_DIR/scripts/composio-drive.sh"     "$BIN_DIR/composio-drive.sh"
$SUDO ln -sf "$INSTALL_DIR/scripts/memory-guardian.sh"    "$BIN_DIR/memory-guardian.sh"
$SUDO ln -sf "$INSTALL_DIR/scripts/templates/cron-wrapper.sh" "$BIN_DIR/cron-wrapper.sh"
$SUDO chmod +x "$INSTALL_DIR"/scripts/*.sh "$INSTALL_DIR"/scripts/lib/*.sh "$INSTALL_DIR"/scripts/templates/*.sh

# --- 3. Env file skeleton ---
info "Creating $ETC_DIR (mode 700)"
$SUDO mkdir -p "$ETC_DIR"
$SUDO chmod 700 "$ETC_DIR"

if [ ! -f "$ETC_DIR/env.sh" ]; then
  info "Dropping env.sh template at $ETC_DIR/env.sh (mode 600)"
  $SUDO cp "$INSTALL_DIR/scripts/install/setup-env.sh.template" "$ETC_DIR/env.sh"
  $SUDO chmod 600 "$ETC_DIR/env.sh"
else
  info "$ETC_DIR/env.sh already exists — leaving untouched"
fi

# --- 4. Systemd unit (install but don't enable) ---
info "Installing systemd unit (not enabled yet)"
$SUDO cp "$INSTALL_DIR/systemd/openclaw-gateway.service" /etc/systemd/system/openclaw-gateway.service

if [ ! -d /etc/systemd/system/openclaw-gateway.service.d ]; then
  $SUDO mkdir -p /etc/systemd/system/openclaw-gateway.service.d
fi
if [ ! -f /etc/systemd/system/openclaw-gateway.service.d/env.conf ]; then
  $SUDO cp "$INSTALL_DIR/systemd/openclaw-gateway.service.d/env.conf.template" \
           /etc/systemd/system/openclaw-gateway.service.d/env.conf
  $SUDO chmod 600 /etc/systemd/system/openclaw-gateway.service.d/env.conf
fi
$SUDO systemctl daemon-reload

echo
bold "Install complete."
echo
cat <<EOF
Next steps (manual — nothing is running yet):

  1. Edit the env file and fill in your secrets:
       ${SUDO} \$EDITOR $ETC_DIR/env.sh

     Required:  COMPOSIO_API_KEY, TG_TOKEN, TG_CHAT, DRIVE_FOLDER_ID

  2. Confirm Composio auth works (after filling in COMPOSIO_API_KEY):
       source $ETC_DIR/env.sh
       bash $INSTALL_DIR/scripts/lib/composio-token.sh preflight googledrive

  3. (Optional) Schedule memory-guardian (requires systemd OpenClaw gateway):
       (crontab -l 2>/dev/null; echo "*/5 * * * * COMPOSIO_API_KEY=... TG_TOKEN=... TG_CHAT=... $BIN_DIR/memory-guardian.sh >> /var/log/memory-guardian.log 2>&1") | crontab -

  4. (Optional) Start the gateway when you're ready:
       ${SUDO} systemctl enable --now openclaw-gateway

  5. Read the docs:
       $INSTALL_DIR/README.md
       $INSTALL_DIR/docs/02-architecture.md

Files installed:
  $INSTALL_DIR/                          (the repo)
  $BIN_DIR/composio-drive.sh             (symlink)
  $BIN_DIR/memory-guardian.sh            (symlink)
  $BIN_DIR/cron-wrapper.sh               (symlink)
  $ETC_DIR/env.sh                        (edit this)
  /etc/systemd/system/openclaw-gateway.service
  /etc/systemd/system/openclaw-gateway.service.d/env.conf

Nothing was started. Nothing sent anywhere. No secrets were generated.
EOF
