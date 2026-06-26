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

## Running it lab-wide (HPC load)

Each dashboard instance is polite **on its own**, but a whole lab pointing at the
same `slurmctld` adds up. Know the load profile before everyone installs it:

| Situation | SLURM RPCs |
|-----------|-----------|
| Browser tab **closed** | watchdog only — **2 RPCs / 5 min**. Negligible. |
| Tab **open**, your jobs unchanged | one cheap `squeue -u you` per refresh, throttled to ≥15s → **~1 query / 15s**. |
| Your jobs **change state** | one **heavy dump = ~41 RPCs** (cluster-wide `squeue -p …`, `sinfo`, `sacct`, …). |

What keeps it light: (1) **change-detection** — the 41-query dump only fires when
*your own* jobs change state, not on every refresh; (2) the **15s throttle**;
(3) a persistent **SSH ControlMaster** so all queries share one connection.

⚠️ **Caveat for many simultaneous users:** the ~13 cluster-wide queries in the
heavy dump are identical across users, so N people each fetching them means N×
the same load on `slurmctld` (and `sacct` hits `slurmdbd`). With a whole lab this
can cause lock contention during job-churn bursts. Mitigations:

- Raise the throttle and poll less often. Recommended lab-friendly values:
  ```bash
  # in your env / LaunchAgent
  export DASHBOARD_DUMP_THROTTLE_S=60     # heavy dump at most once/min
  ```
  and set the UI refresh to 30s, watchdog interval to 600s.
- **Two-tier (planned):** run one shared collector that does the cluster-wide
  dump once and serves the JSON; each member's dashboard reads that shared view
  and only queries SLURM for *their own* jobs. This collapses cluster-wide load
  from N× to 1×. (Not yet wired — see `SHARED_STATUS_URL` issue.)

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `install.sh` says SLURM_USER not set | `cp config.example.env config.env`, set `SLURM_USER=yournetid`, re-run. |
| Dashboard loads but shows no data | Check SSH works: `ssh -F ssh_config dash-submit hostname`. If it prompts for a password, set up key-based auth to `access.engr.oregonstate.edu`. |
| "manifest/JSON missing" or stale | Hit **Refresh** in the UI, or `SLURM_USER=you bash collect.sh --force` and read the error. |
| Port 8899 already in use | Set `DASHBOARD_PORT=<other>` in `config.env` and re-run `./install.sh`. |
| LaunchAgent not auto-starting | `launchctl list | grep slurm-dash`; re-`./install.sh`; check `data/server.log`. |
| Job-log modal won't stream | You hit `JOBLOG_MAX_STREAMS` (default 8) — close other log modals. |
| Reachable from other machines unexpectedly | It binds `0.0.0.0`. For localhost-only, set `DASHBOARD_HOST=127.0.0.1`. |

Logs: `data/server.log` (server) and the LaunchAgent stdout/err.

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
