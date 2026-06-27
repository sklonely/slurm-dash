#!/usr/bin/env bash
# install.sh -- set up the OSU SLURM dashboard.
#
# What it does:
#   1. Creates config.env from config.example.env if missing (then stops).
#   2. Reads config.env and validates SLURM_USER is set.
#   3. Generates ssh_config from ssh_config.example with the user's identity.
#   4. Detects the OS and installs an appropriate auto-start service:
#      - macOS:  LaunchAgent (runs server.py on login, KeepAlive).
#      - Linux:  systemd user service (if systemd is available).
#      - WSL without systemd: prints instructions for ./run.sh.
#   5. Prints the URL.
#
# Idempotent: safe to re-run after changing config.env.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Optional mode, forwarded to the SSH doctor preflight.
DOCTOR_FLAG=""
case "${1:-}" in
  --auto)   DOCTOR_FLAG="--auto" ;;
  --manual) DOCTOR_FLAG="--manual" ;;
  "")       ;;
  *) echo "usage: $0 [--auto|--manual]" >&2; exit 2 ;;
esac

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

# ── Step 3.5: SSH preflight (guided) ───────────────────────────────
# New users don't need to know the gateway/jump-host details — doctor.sh checks
# the whole path and fixes the common first-time problems. Non-fatal: install
# proceeds even if SSH isn't working yet (dashboard just shows no data until it is).
echo ""
echo "── Checking SSH (your machine → gateway → submit node) ──"
if bash "$APP_ROOT/doctor.sh" $DOCTOR_FLAG; then
  :
else
  echo ""
  echo "⚠ SSH not working yet — installing anyway; the dashboard will show no data"
  echo "  until it connects. Fix it then re-run:  ./doctor.sh"
fi

# ── Step 4: data directory ─────────────────────────────────────────
mkdir -p "$APP_ROOT/data"

# ── Step 5: auto-start service (OS-dependent) ─────────────────────
OS="$(uname -s)"
IS_WSL=false
if [ "$OS" = "Linux" ] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    IS_WSL=true
fi

case "$OS" in
  Darwin)
    # ── macOS: LaunchAgent ──────────────────────────────────────────
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
    ;;

  Linux)
    # ── Linux (incl. WSL): systemd user service if available ────────
    if systemctl --user show-environment >/dev/null 2>&1; then
        # systemd user bus is usable.
        UNIT_DIR="$HOME/.config/systemd/user"
        UNIT_FILE="$UNIT_DIR/slurm-dash.service"
        mkdir -p "$UNIT_DIR"

        cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=OSU SLURM Dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env python3 ${APP_ROOT}/server.py
WorkingDirectory=${APP_ROOT}
Environment=SLURM_USER=${SLURM_USER}
Environment=SLURM_GROUP=${SLURM_GROUP}
Environment=DASHBOARD_PORT=${DASHBOARD_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT

        systemctl --user daemon-reload
        systemctl --user enable --now slurm-dash

        # Best-effort: linger keeps the user service alive after logout.
        loginctl enable-linger "$USER" 2>/dev/null || true

        echo ""
        echo "systemd user service installed: slurm-dash"
        echo "  unit: $UNIT_FILE"
        echo "  log:  journalctl --user -u slurm-dash -f"
        echo ""
        echo "Dashboard is running at:"
        echo "  http://localhost:${DASHBOARD_PORT}"
        echo ""
        echo "To stop:  systemctl --user disable --now slurm-dash"
        echo "To uninstall completely:  ./uninstall.sh"
    else
        # No usable systemd (common in WSL without [boot] systemd=true).
        echo ""
        if $IS_WSL; then
            echo "WSL detected but systemd is not available."
            echo "Auto-start requires systemd. To enable it:"
            echo "  1. Add to /etc/wsl.conf:"
            echo "       [boot]"
            echo "       systemd=true"
            echo "  2. From PowerShell:  wsl --shutdown"
            echo "  3. Reopen your Ubuntu terminal and re-run ./install.sh"
            echo ""
        else
            echo "systemd user bus not available -- cannot install auto-start service."
            echo ""
        fi
        echo "For now, start the dashboard manually:"
        echo "  ./run.sh                                        # foreground (Ctrl-C to stop)"
        echo "  nohup ./run.sh > data/server.log 2>&1 &         # background"
        echo ""
        echo "Dashboard will be at:  http://localhost:${DASHBOARD_PORT}"
    fi
    ;;

  *)
    echo ""
    echo "Unsupported OS ($OS) for auto-start."
    echo "Start the dashboard manually:  ./run.sh"
    echo ""
    echo "Dashboard will be at:  http://localhost:${DASHBOARD_PORT}"
    ;;
esac
