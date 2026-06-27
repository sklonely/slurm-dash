#!/usr/bin/env bash
# run.sh -- universal foreground runner for slurm-dash.
#
# Works on macOS, Linux, and WSL. No service manager needed.
# Ctrl-C to stop.

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"

# ── config.env required ───────────────────────────────────────────
if [ ! -f "$APP_ROOT/config.env" ]; then
    echo "ERROR: config.env not found." >&2
    echo "" >&2
    echo "  Run ./install.sh first (it will create config.env for you)," >&2
    echo "  or copy manually:" >&2
    echo "    cp config.example.env config.env" >&2
    echo "    \$EDITOR config.env   # set SLURM_USER" >&2
    exit 1
fi

set -a
# shellcheck disable=SC1091
. "$APP_ROOT/config.env"
set +a

if [ -z "${SLURM_USER:-}" ]; then
    echo "ERROR: SLURM_USER is empty in config.env. Set it to your OSU netID." >&2
    exit 1
fi

export SLURM_USER
export SLURM_GROUP="${SLURM_GROUP:-eecs}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8899}"

echo "Dashboard → http://localhost:${DASHBOARD_PORT}  (Ctrl-C to stop)"

exec python3 "$APP_ROOT/server.py"
