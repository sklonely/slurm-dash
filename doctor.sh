#!/usr/bin/env bash
# doctor.sh -- guided first-time SSH setup + connection check for slurm-dash.
#
# New users do NOT need to know the gateway / jump-host details. This walks the
# whole path  your machine -> gateway (access.engr) -> submit node  and fixes the
# common first-time problems (no key / key not authorized / off-network / 2FA).
#
# Modes:
#   ./doctor.sh            interactive (default): explain each issue, ask before fixing
#   ./doctor.sh --auto     fix without prompting where safe (still needs your OSU
#                          password ONCE for the key copy; 2FA still interactive)
#   ./doctor.sh --manual   diagnose only: print the exact commands, change nothing
#
# Re-run any time the connection breaks.

set -uo pipefail   # deliberately NOT -e: we handle failures, not abort on them

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
GATEWAY="access.engr.oregonstate.edu"

MODE=interactive
case "${1:-}" in
  --auto)   MODE=auto ;;
  --manual) MODE=manual ;;
  "")       MODE=interactive ;;
  *) echo "usage: $0 [--auto|--manual]" >&2; exit 2 ;;
esac

# ── load config ────────────────────────────────────────────────────
[ -f "$APP_ROOT/config.env" ] || { echo "✗ No config.env. Run ./install.sh first." >&2; exit 1; }
set -a; . "$APP_ROOT/config.env"; set +a
if [ -z "${SLURM_USER:-}" ]; then echo "✗ SLURM_USER is empty in config.env — set your OSU netID." >&2; exit 1; fi
SSH_IDENTITY="${SSH_IDENTITY:-~/.ssh/id_ed25519}"
SSH_ID="${SSH_IDENTITY/#\~/$HOME}"
CFG="$APP_ROOT/ssh_config"

ask() {  # ask "Q" -> 0=yes. auto=>yes, manual=>no, interactive=>prompt
  case "$MODE" in
    auto)   return 0 ;;
    manual) return 1 ;;
    *) local a; read -r -p "$1 [Y/n] " a; [ -z "$a" ] || [[ "$a" =~ ^[Yy] ]] ;;
  esac
}

echo "slurm-dash connection doctor   user=$SLURM_USER  key=$SSH_ID  mode=$MODE"
echo "Checks the whole path:  your machine -> gateway -> submit node."
echo

# ── 1) local SSH key ───────────────────────────────────────────────
if [ ! -f "$SSH_ID" ]; then
  echo "① No SSH private key at $SSH_ID"
  if [ "$MODE" = manual ]; then
    echo "   → ssh-keygen -t ed25519 -f \"$SSH_ID\" -N \"\""
    exit 1
  elif ask "   Generate an ed25519 key now (no passphrase, for unattended use)?"; then
    ssh-keygen -t ed25519 -f "$SSH_ID" -N "" >/dev/null && echo "   ✓ created $SSH_ID"
  else
    echo "   Skipped — cannot continue without a key." >&2; exit 1
  fi
else
  echo "① local key ✓  ($SSH_ID)"
fi

# ── 2) ssh_config (install.sh usually makes it; self-heal if missing) ─
if [ ! -f "$CFG" ]; then
  sed -e "s|__SLURM_USER__|$SLURM_USER|g" -e "s|__SSH_IDENTITY__|$SSH_ID|g" \
      "$APP_ROOT/ssh_config.example" > "$CFG"
  echo "② ssh_config generated"
else
  echo "② ssh_config ✓"
fi
mkdir -p "$HOME/.ssh/cm"

# ── 3) connection test + guided fix loop ───────────────────────────
classify() {  # prints OK | AUTH | NET | OTHER:::<stderr>
  local out
  out="$(ssh -F "$CFG" -o BatchMode=yes -o ConnectTimeout=12 dash-submit 'echo __DASH_OK__' 2>&1)"
  if [[ "$out" == *__DASH_OK__* ]]; then echo "OK"; return; fi
  case "$out" in
    *"Permission denied"*) echo "AUTH" ;;
    *"Could not resolve"*|*"Network is unreachable"*|*"timed out"*|*"Operation timed out"*|*"No route to host"*) echo "NET" ;;
    *"Host key verification failed"*) echo "HOSTKEY" ;;
    *) echo "OTHER:::$out" ;;
  esac
}

for attempt in 1 2 3; do
  echo "③ testing connection (attempt $attempt of 3)…"
  cls="$(classify)"
  case "$cls" in
    OK)
      echo "   ✅ Connected through the gateway to the submit node. You're all set."
      exit 0 ;;
    HOSTKEY)
      echo "   ✗ First-contact host key issue; seeding known_hosts…"
      ssh-keyscan -H access.engr.oregonstate.edu >> ~/.ssh/known_hosts 2>/dev/null
      continue ;;
    AUTH)
      echo "   ✗ Your key isn't authorized on the cluster yet."
      if [ "$MODE" = manual ]; then
        echo "     Run (type your OSU password once):"
        if command -v ssh-copy-id >/dev/null 2>&1; then
          echo "       ssh-copy-id -i \"${SSH_ID}.pub\" \"${SLURM_USER}@${GATEWAY}\""
        else
          echo "       cat \"${SSH_ID}.pub\" | ssh \"${SLURM_USER}@${GATEWAY}\" 'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'"
        fi
        echo "     (OSU's gateway + submit usually share your home dir, so this one copy normally covers both hops.)"
        exit 1
      elif ask "   Copy your public key to the cluster now? (you'll type your OSU password ONCE)"; then
        copy_ok=false
        if command -v ssh-copy-id >/dev/null 2>&1; then
          if ssh-copy-id -i "${SSH_ID}.pub" "${SLURM_USER}@${GATEWAY}"; then
            copy_ok=true
          fi
        else
          echo "   (ssh-copy-id not found; using manual key append)"
          if ssh "${SLURM_USER}@${GATEWAY}" 'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < "${SSH_ID}.pub"; then
            copy_ok=true
          fi
        fi
        if $copy_ok; then
          echo "   ✓ key copied (shared home usually covers gateway + submit). re-testing…"
          continue
        else
          echo "   ✗ key copy failed — check your netID/password and network." >&2; exit 1
        fi
      else
        echo "   Skipped." >&2; exit 1
      fi ;;
    NET)
      echo "   ✗ Can't reach $GATEWAY."
      echo "     The gateway is normally reachable only on the OSU network — connect to campus"
      echo "     Wi-Fi or the OSU VPN, then re-run ./doctor.sh."
      exit 1 ;;
    OTHER:::*)
      echo "   ✗ Couldn't connect. SSH said:"
      echo "${cls#OTHER:::}" | sed 's/^/       /'
      echo "     If that mentions Duo / 2FA / keyboard-interactive, the gateway wants interactive"
      echo "     auth that BatchMode can't do. Warm it up once, then re-run this doctor:"
      echo "       ssh -F \"$CFG\" -o BatchMode=no dash-gateway   # complete 2FA; the connection stays warm ~30 min"
      exit 1 ;;
  esac
done

echo "✗ Still not connected after retries. Run ./doctor.sh --manual for the exact commands." >&2
exit 1
