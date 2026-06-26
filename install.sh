#!/usr/bin/env bash
# install.sh -- set up the OSU SLURM dashboard on macOS.
#
# What it does:
#   1. Creates config.env from config.example.env if missing (then stops).
#   2. Reads config.env and validates SLURM_USER is set.
#   3. Generates ssh_config from ssh_config.example with the user's identity.
#   4. Installs a macOS LaunchAgent that runs server.py on login (KeepAlive).
#   5. Prints the URL.
#
# Idempotent: safe to re-run after changing config.env.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── Step 1: config.env ─────────────────────────────────────────────
if [ ! -f "$APP_ROOT/config.env" ]; then
    cp "$APP_ROOT/config.example.env" "$APP_ROOT/config.env"
    echo "Created config.env from config.example.env."
    echo ""
    echo "  >>> Edit config.env and set SLURM_USER to your OSU netID, then re-run:"
    echo "  >>>   \$EDITOR config.env && ./install.sh"
    echo ""
    exit 0
fi

# ── Step 2: read and validate ──────────────────────────────────────
# Source config.env: only export lines matching KEY=VALUE (ignore comments).
set -a
# shellcheck disable=SC1091
. "$APP_ROOT/config.env"
set +a

if [ -z "${SLURM_USER:-}" ]; then
    echo "ERROR: SLURM_USER is empty in config.env. Set it to your OSU netID." >&2
    exit 1
fi

SLURM_GROUP="${SLURM_GROUP:-eecs}"
SSH_IDENTITY="${SSH_IDENTITY:-~/.ssh/id_ed25519}"
DASHBOARD_PORT="${DASHBOARD_PORT:-8899}"

echo "Installing slurm-dash for user: $SLURM_USER"
echo "  group:    $SLURM_GROUP"
echo "  SSH key:  $SSH_IDENTITY"
echo "  port:     $DASHBOARD_PORT"

# ── Step 3: generate ssh_config ────────────────────────────────────
# Expand ~ in SSH_IDENTITY to an absolute path for the SSH config.
SSH_IDENTITY_EXPANDED="${SSH_IDENTITY/#\~/$HOME}"

sed \
    -e "s|__SLURM_USER__|$SLURM_USER|g" \
    -e "s|__SSH_IDENTITY__|$SSH_IDENTITY_EXPANDED|g" \
    "$APP_ROOT/ssh_config.example" > "$APP_ROOT/ssh_config"

echo "Generated ssh_config."

# ── Step 4: data directory ─────────────────────────────────────────
mkdir -p "$APP_ROOT/data"

# ── Step 5: LaunchAgent ────────────────────────────────────────────
PLIST_LABEL="com.${SLURM_USER}.slurm-dash"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

# Unload old version if present (ignore errors on first install).
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>${APP_ROOT}/server.py</string>
  </array>

  <key>WorkingDirectory</key>
  <string>${APP_ROOT}</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>SLURM_USER</key>
    <string>${SLURM_USER}</string>
    <key>SLURM_GROUP</key>
    <string>${SLURM_GROUP}</string>
    <key>DASHBOARD_PORT</key>
    <string>${DASHBOARD_PORT}</string>
  </dict>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${APP_ROOT}/data/server.log</string>
  <key>StandardErrorPath</key>
  <string>${APP_ROOT}/data/server.log</string>

  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
PLIST

launchctl load "$PLIST_PATH"

echo ""
echo "LaunchAgent installed: $PLIST_LABEL"
echo "  plist: $PLIST_PATH"
echo "  log:   $APP_ROOT/data/server.log"
echo ""
echo "Dashboard is running at:"
echo "  http://localhost:${DASHBOARD_PORT}"
echo ""
echo "To stop:  launchctl unload $PLIST_PATH"
echo "To uninstall completely:  ./uninstall.sh"
