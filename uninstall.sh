#!/usr/bin/env bash
# uninstall.sh -- remove the OSU SLURM dashboard LaunchAgent.
#
# Does NOT delete config.env, ssh_config, or data/ (your data stays).
# To fully clean up, remove the slurm-dash directory after running this.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# Read SLURM_USER from config.env to derive the plist label.
if [ -f "$APP_ROOT/config.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$APP_ROOT/config.env"
    set +a
fi

SLURM_USER="${SLURM_USER:-}"

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
else
    echo "Plist not found at $PLIST_PATH -- nothing to remove."
fi

echo ""
echo "Your config.env, ssh_config, and data/ are preserved."
echo "To fully clean up: rm -rf $APP_ROOT"
