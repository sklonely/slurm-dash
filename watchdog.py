#!/usr/bin/env python3
"""
OSU HPC submit-node watchdog.

Probes the submit node every WATCHDOG_INTERVAL seconds with one cheap SSH
command, writes data/hpc_watchdog.json, and fires a macOS notification
when the connection state transitions (OK -> FAIL or FAIL -> OK).

Default interval: 300s (5 min). Each probe is one SSH session running
"hostname && squeue -u $SLURM_USER -h | wc -l" -- two slurm RPCs total.

Requires SLURM_USER environment variable to be set.
"""

from __future__ import annotations

import json
import os
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

APP_ROOT = Path(__file__).resolve().parent
DATA_DIR = APP_ROOT / "data"
OUT = DATA_DIR / "hpc_watchdog.json"
INTERVAL_S = int(os.environ.get("WATCHDOG_INTERVAL", "300"))
LOG_MAX_BYTES = int(os.environ.get("LOG_MAX_BYTES", "5000000"))
SSH_CONNECT_TIMEOUT = 15

SLURM_USER = os.environ.get("SLURM_USER", "")
if not SLURM_USER:
    sys.stderr.write("[watchdog] FATAL: SLURM_USER environment variable is not set.\n")
    sys.exit(1)

DASH_SSH_CONFIG = APP_ROOT / "ssh_config"
SSH_HOST = "dash-submit"  # resolved via the project's ssh_config


def now_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def notify(title: str, body: str) -> None:
    """Desktop notification. Dispatches by platform; never crashes."""
    try:
        if sys.platform == "darwin":
            safe_title = title.replace('"', "'")
            safe_body = body.replace('"', "'")
            subprocess.run(
                ["osascript", "-e",
                 f'display notification "{safe_body}" with title "{safe_title}"'],
                check=False, capture_output=True, timeout=5,
            )
        elif sys.platform == "linux":
            if shutil.which("notify-send"):
                subprocess.run(
                    ["notify-send", title, body],
                    check=False, capture_output=True, timeout=5,
                )
            # else: no notifier available -- silently skip.
        # Other platforms: no-op.
    except Exception:
        pass


def rotate_log(path: Path) -> None:
    """Copytruncate rotation: if *path* exceeds LOG_MAX_BYTES, back it up to
    ``<path>.1`` and truncate the original **in place** so launchd/systemd
    file-descriptors keep working.  Never raises."""
    try:
        if not path.exists():
            return
        if path.stat().st_size <= LOG_MAX_BYTES:
            return
        shutil.copy2(path, str(path) + ".1")
        with open(path, "r+") as f:
            f.truncate(0)
    except Exception:
        pass  # log housekeeping must never crash the watchdog


def probe() -> tuple[bool, int, str, int, str]:
    start = time.monotonic()
    try:
        r = subprocess.run(
            ["ssh", "-F", str(DASH_SSH_CONFIG), SSH_HOST,
             f"hostname && squeue -u {SLURM_USER} -h 2>/dev/null | wc -l"],
            capture_output=True, text=True, timeout=SSH_CONNECT_TIMEOUT + 10,
        )
    except subprocess.TimeoutExpired:
        return False, int((time.monotonic() - start) * 1000), "", 0, "ssh timeout"
    except Exception as exc:
        return False, int((time.monotonic() - start) * 1000), "", 0, f"exec error: {exc}"
    latency_ms = int((time.monotonic() - start) * 1000)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).strip().splitlines()
        reason = (tail[-1] if tail else f"exit {r.returncode}")[:200]
        return False, latency_ms, "", 0, reason
    lines = [ln.strip() for ln in r.stdout.splitlines() if ln.strip()]
    if len(lines) < 2:
        return False, latency_ms, "", 0, "unexpected output"
    node = lines[0]
    try:
        jobs = int(lines[1])
    except ValueError:
        jobs = 0
    return True, latency_ms, node, jobs, ""


def load_prev() -> dict | None:
    if not OUT.exists():
        return None
    try:
        return json.loads(OUT.read_text())
    except Exception:
        return None


def write_status(ok, latency_ms, node, jobs, reason, prev):
    ts = now_utc()
    last_ok = ts if ok else (prev.get("last_ok_ts", "") if prev else "")
    last_fail = ts if not ok else (prev.get("last_fail_ts", "") if prev else "")
    fail_count = 0 if ok else ((prev.get("consecutive_fails", 0) if prev else 0) + 1)
    payload = {
        "ts": ts,
        "ok": ok,
        "latency_ms": latency_ms,
        "node": node,
        "my_jobs": jobs,
        "reason": reason,
        "last_ok_ts": last_ok,
        "last_fail_ts": last_fail,
        "consecutive_fails": fail_count,
        "interval_sec": INTERVAL_S,
    }
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, indent=2))
    tmp.replace(OUT)
    return payload


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    prev_payload = load_prev()
    prev_state = bool(prev_payload.get("ok")) if prev_payload else None
    sys.stderr.write(
        f"[watchdog] start, user={SLURM_USER}, interval={INTERVAL_S}s, prev_state={prev_state}\n"
    )
    while True:
        rotate_log(DATA_DIR / "server.log")
        rotate_log(DATA_DIR / "watchdog.log")
        ok, latency, node, jobs, reason = probe()
        prev_payload = write_status(ok, latency, node, jobs, reason, prev_payload)
        sys.stderr.write(
            f"[{time.strftime('%H:%M:%S')}] ok={ok} latency={latency}ms "
            f"node={node!r} jobs={jobs} reason={reason!r}\n"
        )
        if prev_state is True and ok is False:
            notify("OSU HPC unreachable", reason[:120] or "submit node down")
        elif prev_state is False and ok is True:
            notify("OSU HPC restored", f"{node} ({latency}ms)")
        prev_state = ok
        time.sleep(INTERVAL_S)


if __name__ == "__main__":
    main()
