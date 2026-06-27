#!/usr/bin/env bash
# uninstall.sh -- remove the OSU SLURM dashboard auto-start service.
#
# Handles macOS (LaunchAgent) and Linux (systemd user service).
# Does NOT delete config.env, ssh_config, or data/ (your data stays).
# To fully clean up, remove the slurm-dash directory after running this.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Read SLURM_USER from config.env to derive service names.
if [ -f "$APP_ROOT/config.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$APP_ROOT/config.env"
    set +a
fi

SLURM_USER="${SLURM_USER:-}"
REMOVED=false

# ── Detect OS ─────────────────────────────────────────────────────
OS="$(uname -s)"

case "$OS" in
  Darwin)
    # ── macOS: LaunchAgent ──────────────────────────────────────────
    if [ -z "$SLURM_USER" ]; then
        echo "WARNING: SLURM_USER not found in config.env; trying to find plist by pattern." >&2
        # Fallback: look for any com.*.slurm-dash plist.
        found=$(ls "$HOME/Library/LaunchAgents"/com.*.slurm-dash.plist 2>/dev/null | head -1 || true)
        if [ -n "$found" ]; then
            PLIST_PATH="$found"
            PLIST_LABEL=$(basename "$found" .plist)
        else
            echo "No slurm-dash LaunchAgent found. Nothing to uninstall." >&2
            exit 0
        fi
    else
        PLIST_LABEL="com.${SLURM_USER}.slurm-dash"
        PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    fi

    if [ -f "$PLIST_PATH" ]; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        rm -f "$PLIST_PATH"
        echo "Unloaded and removed: $PLIST_LABEL"
        echo "  ($PLIST_PATH)"
        REMOVED=true
    else
        echo "Plist not found at $PLIST_PATH -- nothing to remove."
    fi

    # ── macOS: Watchdog LaunchAgent ────────────────────────────────
    if [ -n "$SLURM_USER" ]; then
        WD_PLIST_LABEL="com.${SLURM_USER}.slurm-dash-watchdog"
        WD_PLIST_PATH="$HOME/Library/LaunchAgents/${WD_PLIST_LABEL}.plist"
    else
        # Fallback: find by pattern.
        WD_PLIST_PATH=$(ls "$HOME/Library/LaunchAgents"/com.*.slurm-dash-watchdog.plist 2>/dev/null | head -1 || true)
        WD_PLIST_LABEL=$(basename "${WD_PLIST_PATH:-.}" .plist 2>/dev/null || true)
    fi
    if [ -n "${WD_PLIST_PATH:-}" ] && [ -f "$WD_PLIST_PATH" ]; then
        launchctl unload "$WD_PLIST_PATH" 2>/dev/null || true
        rm -f "$WD_PLIST_PATH"
        echo "Unloaded and removed: $WD_PLIST_LABEL"
        echo "  ($WD_PLIST_PATH)"
        REMOVED=true
    fi
    ;;

  Linux)
    # ── Linux (incl. WSL): systemd user service ─────────────────────
    UNIT_FILE="$HOME/.config/systemd/user/slurm-dash.service"

    if systemctl --user is-enabled slurm-dash &>/dev/null || [ -f "$UNIT_FILE" ]; then
        systemctl --user disable --now slurm-dash 2>/dev/null || true
        rm -f "$UNIT_FILE"
        echo "Stopped and removed systemd user service: slurm-dash"
        echo "  ($UNIT_FILE)"
        REMOVED=true
    else
        echo "No slurm-dash systemd user service found. Nothing to uninstall."
    fi

    # ── Linux: Watchdog systemd user service ───────────────────────
    WD_UNIT_FILE="$HOME/.config/systemd/user/slurm-dash-watchdog.service"
    if systemctl --user is-enabled slurm-dash-watchdog &>/dev/null || [ -f "$WD_UNIT_FILE" ]; then
        systemctl --user disable --now slurm-dash-watchdog 2>/dev/null || true
        rm -f "$WD_UNIT_FILE"
        echo "Stopped and removed systemd user service: slurm-dash-watchdog"
        echo "  ($WD_UNIT_FILE)"
        REMOVED=true
    fi

    systemctl --user daemon-reload 2>/dev/null || true
    ;;

  *)
    echo "No auto-start service to remove on $OS."
    ;;
esac

if $REMOVED; then
    echo ""
    echo "Your config.env, ssh_config, and data/ are preserved."
    echo "To fully clean up: rm -rf $APP_ROOT"
fi
