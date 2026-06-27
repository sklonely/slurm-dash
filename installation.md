# slurm-dash — Installation & Smoke-Test Guide (for AI agents)

You are an AI coding agent installing **slurm-dash** (a self-hosted OSU College of
Engineering SLURM dashboard) on the user's machine. Follow these steps **in order**
and **verify after each one** before continuing. Two steps need the human — they are
marked **[ASK USER]**; do not try to do them yourself.

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
- On Debian/Ubuntu/WSL, install anything missing:
  ```bash
  sudo apt update && sudo apt install -y git python3 openssh-client
  ```

## 1. Get the code

- If the repo is already on disk, `cd` into it and skip the clone.
- Otherwise:
  ```bash
  git clone https://github.com/sklonely/slurm-dash.git && cd slurm-dash
  ```
  This is a **private** repo. If the clone fails with an auth error, ask the user to
  grant your GitHub account access (or run `gh auth login`), then retry.

## 2. Configure  **[ASK USER: OSU netID]**

```bash
cp -n config.example.env config.env
```
Ask the user for their **OSU netID**, then set it (the dashboard only needs this one value):
```bash
# Linux/WSL:
sed -i  's/^SLURM_USER=.*/SLURM_USER=NETID/' config.env
# macOS:
sed -i '' 's/^SLURM_USER=.*/SLURM_USER=NETID/' config.env
grep '^SLURM_USER=' config.env        # verify it is set
```
(Optional: `SLURM_GROUP`, `SSH_IDENTITY`, `DASHBOARD_PORT` — sensible defaults exist.
Gateway/partitions/rates are baked in for the OSU cluster.)

## 3. SSH connection  **[ASK USER: OSU password, once]**

The dashboard reaches the cluster over two hops (your machine → `access.engr.oregonstate.edu`
→ a submit node) via ProxyJump. The doctor sets this up for the user — they do **not** need
to know the jump-host details.

```bash
./doctor.sh --auto
```
It will: generate an SSH key in `~/.ssh` if absent → copy the **public** key to the cluster
(**this prompts for the user's OSU password — pause and let the user type it**) → test the
full path. Success line: `✅ Connected through the gateway to the submit node.`

If it reports:
- *can't reach the gateway* → the user must be on OSU Wi-Fi / OSU VPN; retry.
- *Duo / 2FA* → the user runs `ssh -F ssh_config dash-gateway` once interactively to complete
  2FA, then you re-run `./doctor.sh`.

## 4. Install (auto-start service)

```bash
./install.sh
```
Auto-detects the OS: macOS → LaunchAgent · Linux/WSL with systemd → systemd user service ·
WSL without systemd → it tells you to start manually with `./run.sh`. Non-fatal if SSH is not
ready yet (it installs anyway; the dashboard just shows no data until the connection works).

## 5. Verify it serves

```bash
# /api/config should echo the configured user:
python3 -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8899/api/config',timeout=5).read().decode())"
# index page should be HTTP 200:
python3 -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8899/',timeout=5).getcode())"
```
If `install.sh` told you to use `./run.sh` (WSL without systemd), start it first:
```bash
nohup ./run.sh > data/server.log 2>&1 &
```

## 6. Open the dashboard

- macOS: `open http://localhost:8899`
- Linux: `xdg-open http://localhost:8899`
- WSL: open `http://localhost:8899` in the **Windows** browser (WSL2 forwards localhost).

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
