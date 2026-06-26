# slurm-dash

A self-hosted SLURM dashboard for the OSU College of Engineering HPC cluster.
Real-time job monitoring, node status, GPU utilization, queue depth, and live
job-log streaming -- all from a single-page web UI backed by a lightweight
Python server.

Extracted from a research project's internal tooling and decoupled so any lab
member on the same cluster can run their own copy.

## Prerequisites

- **SSH access** to `access.engr.oregonstate.edu` with your OSU netID + key-based auth.
- **macOS** (the install script creates a LaunchAgent; the dashboard runs on any OS but auto-start is macOS-only).
- **Python 3.9+** (ships with macOS).

## Quickstart

```bash
git clone <this-repo> && cd slurm-dash

# 1. Create your config (first run creates the file and exits):
./install.sh

# 2. Set your OSU netID:
$EDITOR config.env   # set SLURM_USER=yournetid

# 3. Install and start:
./install.sh

# 4. Open the dashboard:
open http://localhost:8899
```

## How it works

| Component      | File          | Purpose |
|----------------|---------------|---------|
| **Server**     | `server.py`   | HTTP server serving `web/` + API endpoints (`/api/refresh`, `/api/status`, `/api/health`, `/api/config`, `/api/joblog/stream`). |
| **Collector**   | `collect.sh`  | SSH into the submit node, run ~20 SLURM queries, render JSON to `data/hpc_status.json`. Smart change-detection: only does the heavy dump when your queue actually changes. |
| **Watchdog**   | `watchdog.py` | Probes the submit node every 5 min, writes `data/hpc_watchdog.json`, fires macOS notifications on state transitions. |
| **Frontend**   | `web/index.html` | React SPA that fetches JSON from the API endpoints and renders the dashboard. |
| **SSH config** | `ssh_config`  | Generated from `ssh_config.example` at install time. Dedicated ControlMaster for the dashboard (isolated from your interactive SSH). |

### SSE job-log streaming

Click any running job card to open a live log modal. The server opens one
`tail -F` over the persistent SSH ControlMaster channel -- steady-state load
on the submit node is near zero (no reconnects, no repeated slurmctld RPCs).

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SLURM_USER` | *(required)* | Your OSU netID. |
| `SLURM_GROUP` | `eecs` | Your SLURM account/group (displayed in the header). |
| `SSH_IDENTITY` | `~/.ssh/id_ed25519` | Path to the SSH private key for the gateway. |
| `DASHBOARD_PORT` | `8899` | Local port the server binds to. |
| `DASHBOARD_HOST` | `0.0.0.0` | Bind address (env only, not in config.env). |
| `DASHBOARD_DUMP_THROTTLE_S` | `15` | Minimum seconds between refresh kicks (env only). |

Cluster-specific values (gateway hostname, partition names, billing rates,
GPU-type labels) are baked in for the OSU HPC. If you are on the same cluster,
no changes are needed.

## Uninstall

```bash
./uninstall.sh
```

This unloads the LaunchAgent and removes the plist. Your `config.env`,
`ssh_config`, and `data/` are preserved. To fully clean up, delete the
`slurm-dash` directory.

## Security

- The web root is restricted to `./web/` -- the server cannot serve files
  outside that directory.
- Runtime data (JSON dumps, logs) lives in `./data/`, which is not under the
  web root and not served statically.
- The server binds `0.0.0.0` by default, so it is reachable on your local
  network or Tailnet. It does **not** serve to the public internet unless you
  explicitly expose the port. For Tailnet-only access, this is fine; for shared
  networks, bind to `127.0.0.1` via `DASHBOARD_HOST=127.0.0.1` in your env.
- `config.env` and `ssh_config` are git-ignored (they contain your username
  and key path).
