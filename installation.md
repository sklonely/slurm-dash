# slurm-dash — Installation & Smoke-Test Guide (for AI agents)

You are an AI coding agent installing **slurm-dash** (a self-hosted OSU College of
Engineering SLURM dashboard) on the user's machine. Follow these steps **in order**
and **verify after each one** before continuing. Two steps need the human — they are
marked **[ASK USER]**; do not try to do them yourself.

---

## Communicating with the user

Keep the user informed throughout — never work silently:

1. **Report each stage.** Before a step, say which stage you're on and what you're about to
   do; after it, say the result, then continue. Use a short progress line, e.g.:
   ```
   [2/6 Configure] writing config.env, setting your netID … ✓ (SLURM_USER=<netid>)
   [3/6 SSH]       needs you to do one thing — see below
   ```
2. **At any human-needed step, explain clearly** — never just pause. State (a) WHAT you need
   and WHY you can't do it yourself, (b) the EXACT action (which window, which command),
   (c) what SUCCESS looks like, (d) ask them to report back — then **you re-verify** with a
   read-only check before continuing (don't just trust "done").

The two human-in-the-loop points are the **netID** (step 2) and the **OSU password + Duo**
(step 3). Everything else you do yourself.

---

## 0. Preconditions

```bash
uname -s            # Darwin = macOS · Linux = Linux or WSL
python3 --version   # need 3.9+
ssh -V ; git --version
```

- **Native Windows is NOT supported** (no bash, no SSH ControlMaster). If you are on
  native Windows, tell the user to install WSL2 (`wsl --install` in PowerShell, pick
  Ubuntu), then run everything **inside the Ubuntu/WSL shell** and continue there.
- On Linux/WSL, install anything missing with your package manager:
  ```bash
  if command -v apt >/dev/null; then sudo apt update && sudo apt install -y git python3 openssh-client;
  elif command -v dnf >/dev/null; then sudo dnf install -y git python3 openssh-clients;
  elif command -v pacman >/dev/null; then sudo pacman -S --needed git python openssh;
  elif command -v zypper >/dev/null; then sudo zypper install -y git python3 openssh; fi
  ```

## 1. Get the code

- If the repo is already on disk, `cd` into it and skip the clone.
- Otherwise:
  ```bash
  git clone https://github.com/sklonely/slurm-dash.git && cd slurm-dash
  ```
  This repo is public; `git clone` works without auth. If the clone fails, it's a
  network or missing-git issue (check `git --version` and connectivity), not a
  permissions issue.

## 2. Configure  **[ASK USER: OSU netID]**

```bash
cp -n config.example.env config.env
```
Ask the user for their **OSU netID**, then set it (the dashboard only needs this one value):
```bash
NETID="the_netid_the_user_gave_you"   # <-- substitute the real value

# Linux/WSL:
sed -i  "s/^SLURM_USER=.*/SLURM_USER=$NETID/" config.env
# macOS:
sed -i '' "s/^SLURM_USER=.*/SLURM_USER=$NETID/" config.env

# Verify it is set to a real value (not a placeholder):
grep '^SLURM_USER=' config.env
grep -qE '^SLURM_USER=$' config.env && echo "STILL EMPTY — substitute the real netID"
```
(Optional: `SLURM_GROUP`, `SSH_IDENTITY`, `DASHBOARD_PORT` — sensible defaults exist.
Gateway/partitions/rates are baked in for the OSU cluster.)

## 3. SSH connection  **[ASK USER: OSU password, once]**

The dashboard reaches the cluster over two hops (your machine → `access.engr.oregonstate.edu`
→ a submit node) via ProxyJump. The doctor sets this up for the user — they do **not** need
to know the jump-host details.

`./doctor.sh --auto` generates an SSH key if absent, copies your **public** key onto your
OSU ENGR account, and tests the path. The key copy is the **one and only** time a password
is needed: `access.engr` is OSU's shared **public** jump host, and the key lands in your
shared `/nfs/stak` home (which the HPC nodes also mount), so **one copy authorizes both
hops**. After that every connection is key-only — **no password, no Duo, ever again** (key
auth bypasses Duo).

**This step needs the human (password + Duo) and you usually cannot do it yourself** —
ssh-copy-id prompts for the OSU password on a real terminal + a Duo approval on the user's
phone; an agent has neither. `doctor.sh` detects a missing terminal and **stops with a
hand-off instead of hanging**. So tell the user clearly (template):

> This connects the dashboard to the cluster. Your SSH key needs to go onto your OSU account
> **once**, which needs your **OSU password + a Duo approval** — I can't type your password or
> approve Duo for you. Please open **your own terminal** and run:
> `cd <install-dir> && ./doctor.sh --auto`
> It asks your OSU password (type it **there**, never to me — I never see it), then Duo
> (approve on your phone). When you see `✅ Connected through the gateway to the submit node`,
> tell me. You only do this once. (Want the exact raw commands instead? `./doctor.sh --manual`
> prints them and changes nothing.)

If the key is **already** authorized (re-install), `--auto` just connects with no prompt and
you can run it yourself.

**After the user reports back, re-verify — don't trust "done":**
```bash
./doctor.sh --manual    # read-only; needs no terminal; prints the current state
```
Only continue to step 4 when it prints `✅ Connected`. Otherwise relay the matching fix:

| doctor says | what it means | tell the user to |
|---|---|---|
| `✅ Connected` | key works through both hops | nothing — continue to step 4 |
| `AUTH` | key not yet authorized on your OSU account | run `./doctor.sh --auto` in their terminal (OSU password once + Duo) |
| `NET` → *DNS can't resolve* | offline / captive-portal Wi-Fi not logged into | get online (open any site / accept the Wi-Fi portal), then retry |
| `NET` → *port 22 blocked* | their network blocks outbound SSH — common on hotel/guest/corp Wi-Fi | switch network (a phone hotspot usually works); OSU VPN only if that's the sole option |
| `NET` → *reachable but failed* | transient, or the submit node behind the gateway | wait, re-run; if it persists, share the `--manual` SSH error |
| Duo / 2FA (in `OTHER`) | the gateway wants interactive 2FA | run `ssh -F ssh_config -o BatchMode=no dash-gateway` once to complete Duo, then retry |

Note: `access.engr` is **publicly reachable** (a shared OSU jump host), so a NET failure is a
your-side network issue — **not** "you must be on VPN". VPN only helps if your local network
blocks outbound port 22.

## 4. Install (auto-start service)

```bash
./install.sh
```
Auto-detects the OS: macOS -> LaunchAgent, Linux/WSL with systemd -> systemd user service,
WSL without systemd -> it tells you to start manually with `./run.sh`. Non-fatal if SSH is not
ready yet (it installs anyway; the dashboard just shows no data until the connection works).

If the output said to start it manually (WSL without systemd), do it now BEFORE verifying:
```bash
nohup ./run.sh > data/server.log 2>&1 &
```
Then wait ~3 seconds for the server to come up.

## 5. Verify it serves

If you changed `DASHBOARD_PORT` in config.env, use that port below instead of 8899.

Startup is async; use a retry loop:
```bash
for i in $(seq 1 10); do
  python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8899/api/config',timeout=2)" 2>/dev/null && break || sleep 1
done
```
Then assert the value is real (not a placeholder):
```bash
python3 -c "import json,urllib.request as u; d=json.load(u.urlopen('http://127.0.0.1:8899/api/config',timeout=5)); assert d.get('user') and not d['user'].startswith('<'), d; print(d)"
# index page should be HTTP 200:
python3 -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8899/',timeout=5).getcode())"
```

## 6. Open the dashboard

If you changed `DASHBOARD_PORT` in config.env, use that port below instead of 8899.

- macOS: `open http://localhost:8899`
- Linux: `xdg-open http://localhost:8899`
- WSL: open `http://localhost:8899` in the **Windows** browser (WSL2 forwards localhost).

Then report completion to the user, e.g.:
```
[6/6 Done] dashboard live at http://localhost:8899 · watchdog running (health badge +
cluster up/down alerts) · logs size-capped (macOS) / journald (Linux). Open that URL in your browser.
```

---

## Success criteria — confirm ALL before declaring done

- [ ] `config.env` has the user's `SLURM_USER`
- [ ] `./doctor.sh` reported a successful connection (or the user completed the key/2FA step)
- [ ] `./install.sh` set up a service (or instructed `./run.sh`) with no error
- [ ] `/api/config` returns the user's netID; the index page returns HTTP 200
- [ ] the dashboard loads in the browser and shows live SLURM data

## Uninstall / cleanup (e.g. after a test install)

```bash
./uninstall.sh        # removes the LaunchAgent or systemd service; keeps config.env + data
```

## Notes for the agent

- Steps 0,1,2,4,5,6 are automatable. Steps **3** (OSU password) and the **netID** in step 2
  require the human — ask, then continue.
- Everything is idempotent; safe to re-run `install.sh` / `doctor.sh`.
- Do not commit `config.env` or `ssh_config` (they are git-ignored — they hold the user's
  identity).
