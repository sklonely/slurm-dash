#!/usr/bin/env python3
"""
OSU SLURM dashboard server.

Serves static dashboard files from ./web plus API endpoints:

    GET /api/refresh        -- kick a throttled smart dump (collect.sh, no --force), return updated JSON
    GET /api/status         -- return cached data/hpc_status.json (no remote call)
    GET /api/health         -- return data/hpc_watchdog.json (no remote call)
    GET /api/config         -- return {"user":..., "group":...} from env
    GET /api/debug          -- refresher status (inflight / throttle / last_error)
    GET /api/joblog/stream  -- SSE live tail -F of a job's StdOut/StdErr (one
                               persistent SSH channel per viewer; see below)

The /api/refresh endpoint coalesces concurrent requests: if a dump is in flight,
later callers wait on the same future instead of hammering the submit node.
"""

from __future__ import annotations

import json
import os
import queue as queuelib
import re
import subprocess
import sys
import threading
import time
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

APP_ROOT = Path(__file__).resolve().parent
WEB_ROOT = APP_ROOT / "web"
DATA_DIR = APP_ROOT / "data"
DUMP_SCRIPT = APP_ROOT / "collect.sh"
STATUS_JSON = DATA_DIR / "hpc_status.json"
WATCHDOG_JSON = DATA_DIR / "hpc_watchdog.json"
HOST = os.environ.get("DASHBOARD_HOST", "0.0.0.0")
PORT = int(os.environ.get("DASHBOARD_PORT", "8899"))
DUMP_TIMEOUT_S = 180
# Server-side throttle: at most one script run kicked off every N seconds, no
# matter how often clients call /api/refresh. The script's default path is now
# CHEAP -- a ~1-squeue change probe -- and only does the heavy full dump when the
# queue actually changed (coalesced) or the slow-data safety net expires. So a
# short throttle here just sets the change-DETECTION latency (~15s), not the
# heavy-query rate. Override via DASHBOARD_DUMP_THROTTLE_S.
DUMP_THROTTLE_S = int(os.environ.get("DASHBOARD_DUMP_THROTTLE_S", "15"))

# -- Live job-log streaming (SSE) -------------------------------------------------
# A viewer opens one EventSource -> one long-lived `tail -F` over the persistent
# ControlMaster SSH channel. scontrol is queried exactly once per stream (to
# resolve the StdOut/StdErr paths + state); after that the connection just
# follows the file, so steady-state load on the submit node is ~zero (no
# reconnects, no repeated slurmctld RPCs). `tail -F` itself is inotify-light.
# Connection behavior (multiplexing both hops, keepalive, persist) lives in the
# shared dashboard SSH config so the dump script and this server reuse ONE warm
# master to the submit node. See ssh_config.example.
DASH_SSH_CONFIG = APP_ROOT / "ssh_config"
SSH_BASE = ["ssh", "-F", str(DASH_SSH_CONFIG), "dash-submit"]

JOBID_RE = re.compile(r"^\d+(?:_\d+)?$")          # 12345 or 12345_6 (array task)
SAFE_PATH_RE = re.compile(r"^/[^'\n]+$")           # absolute, no quote/newline
JOBLOG_TAIL_LINES = int(os.environ.get("JOBLOG_TAIL_LINES", "400"))
JOBLOG_MAX_STREAMS = int(os.environ.get("JOBLOG_MAX_STREAMS", "8"))
_stream_count_lock = threading.Lock()
_stream_count = 0


def _resolve_job(job: str) -> dict:
    """One scontrol RPC -> JobState/JobName + resolved StdOut/StdErr paths."""
    remote = (
        f"I=$(scontrol show job {job} -o 2>/dev/null); "
        "S=$(printf '%s\\n' \"$I\" | grep -oE 'JobState=[^ ]+' | head -1 | cut -d= -f2); "
        "NM=$(printf '%s\\n' \"$I\" | grep -oE 'JobName=[^ ]+' | head -1 | cut -d= -f2); "
        "O=$(printf '%s\\n' \"$I\" | grep -oE 'StdOut=[^ ]+' | head -1 | cut -d= -f2); "
        "E=$(printf '%s\\n' \"$I\" | grep -oE 'StdErr=[^ ]+' | head -1 | cut -d= -f2); "
        "printf 'STATE=%s\\nNAME=%s\\nSTDOUT=%s\\nSTDERR=%s\\n' \"$S\" \"$NM\" \"$O\" \"$E\""
    )
    try:
        proc = subprocess.run(
            SSH_BASE + [remote], capture_output=True, text=True, timeout=25
        )
    except subprocess.TimeoutExpired:
        return {"error": "ssh timeout resolving job"}
    info = {"state": "", "name": "", "stdout_path": "", "stderr_path": ""}
    for line in proc.stdout.splitlines():
        if line.startswith("STATE="):
            info["state"] = line[6:]
        elif line.startswith("NAME="):
            info["name"] = line[5:]
        elif line.startswith("STDOUT="):
            info["stdout_path"] = line[7:]
        elif line.startswith("STDERR="):
            info["stderr_path"] = line[7:]
    info["state"] = info["state"] or "UNKNOWN"
    return info


class ThrottledRefresher:
    """Background-runs dump_once; ignores calls within throttle window.

    - maybe_kick(): starts a dump in a background thread if not already running
      and the throttle window has elapsed; never blocks.
    - wait_for_first(timeout): blocks until at least one successful dump has
      written STATUS_JSON, for the cold-start case.
    """

    def __init__(self, fn, min_interval_s: int):
        self._fn = fn
        self._min_interval = min_interval_s
        self._lock = threading.Lock()
        self._inflight = False
        self._last_started = 0.0   # monotonic
        self._last_finished_ok = 0.0
        self._last_error: str | None = None
        self._first_done = threading.Event()
        if STATUS_JSON.exists():
            self._first_done.set()

    def status(self) -> dict:
        with self._lock:
            since = (time.monotonic() - self._last_started) if self._last_started else None
            return {
                "inflight": self._inflight,
                "last_started_sec_ago": int(since) if since is not None else None,
                "throttle_window_s": self._min_interval,
                "last_error": self._last_error,
            }

    def maybe_kick(self) -> dict:
        now = time.monotonic()
        with self._lock:
            if self._inflight:
                return {"kicked": False, "reason": "inflight", "inflight": True}
            if self._last_started and (now - self._last_started) < self._min_interval:
                wait = int(self._min_interval - (now - self._last_started))
                return {"kicked": False, "reason": "throttled", "wait_s": wait, "inflight": False}
            self._inflight = True
            self._last_started = now
        threading.Thread(target=self._run, daemon=True).start()
        return {"kicked": True, "inflight": True}

    def wait_for_first(self, timeout_s: float) -> bool:
        return self._first_done.wait(timeout=timeout_s)

    def _run(self):
        try:
            self._fn()
            with self._lock:
                self._last_finished_ok = time.monotonic()
                self._last_error = None
        except Exception as exc:
            sys.stderr.write(f"[refresh] failed: {exc}\n")
            with self._lock:
                self._last_error = str(exc)[:200]
        finally:
            # Always unblock cold-start waiters (even on failure) so they
            # get a fast error instead of blocking for the full timeout.
            self._first_done.set()
            with self._lock:
                self._inflight = False


def _run_dump():
    # No-flag invocation hits smart_dump: cheap probe + cached-JSON shortcut
    # when queue unchanged and JSON <60s old, full dump otherwise.
    res = subprocess.run(
        ["/bin/bash", str(DUMP_SCRIPT)],
        cwd=str(APP_ROOT),
        capture_output=True,
        text=True,
        timeout=DUMP_TIMEOUT_S,
    )
    if res.returncode != 0:
        tail = (res.stderr or res.stdout).strip()[-400:]
        raise RuntimeError(f"dump exit {res.returncode}: {tail}")
    if not STATUS_JSON.exists():
        raise RuntimeError("dump exited 0 but hpc_status.json missing")


REFRESH = ThrottledRefresher(_run_dump, min_interval_s=DUMP_THROTTLE_S)


class Handler(SimpleHTTPRequestHandler):
    server_version = "SlurmDash/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_ROOT), **kwargs)

    def log_message(self, fmt, *args):
        sys.stderr.write(
            f"[{time.strftime('%H:%M:%S')}] {self.address_string()} {fmt % args}\n"
        )

    def _send_json(self, status, payload):
        if isinstance(payload, (bytes, bytearray)):
            body = bytes(payload)
        else:
            body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file_json(self, path: Path, extra_headers: dict | None = None):
        if not path.exists():
            self._send_json(503, {"error": f"{path.name} not yet generated"})
            return
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, str(v))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _maybe_serve_range(self) -> bool:
        """ADDITIVE: Range-aware static serving. Only fires when the request
        carries a ``Range`` header (the dataset viewer streams huge JSONL by
        byte range; stdlib SimpleHTTPRequestHandler ignores Range and returns
        the whole file). Returns True if it handled the response, False to fall
        back to the normal static handler. Non-Range requests are unaffected."""
        rng = self.headers.get("Range")
        if not rng:
            return False
        path = Path(self.translate_path(self.path))
        if not path.is_file():
            return False
        m = re.match(r"bytes=(\d+)-(\d*)", rng.strip())
        if not m:
            return False
        size = path.stat().st_size
        start = int(m.group(1))
        end = int(m.group(2)) if m.group(2) else size - 1
        end = min(end, size - 1)
        if start >= size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return True
        length = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(str(path)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(length))
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)
        return True

    def do_GET(self):
        route = self.path.split("?", 1)[0]
        if route == "/api/refresh":
            kick = REFRESH.maybe_kick()
            extra = {
                "X-Refresh-Inflight": "1" if kick["inflight"] else "0",
                "X-Refresh-Kicked": "1" if kick["kicked"] else "0",
            }
            if kick.get("reason"):
                extra["X-Refresh-Reason"] = kick["reason"]
            if not STATUS_JSON.exists():
                # Cold start: block briefly (not the full 180s dump timeout).
                cold_wait = min(20, DUMP_TIMEOUT_S)
                if REFRESH.wait_for_first(cold_wait) and STATUS_JSON.exists():
                    self._send_file_json(STATUS_JSON, extra)
                else:
                    detail = REFRESH.status().get("last_error") or "dump not finished yet"
                    self._send_json(503, {"error": "SSH not connected yet", "detail": detail})
                return
            self._send_file_json(STATUS_JSON, extra)
            return
        if route == "/api/status":
            self._send_file_json(STATUS_JSON)
            return
        if route == "/api/health":
            self._send_file_json(WATCHDOG_JSON)
            return
        if route == "/api/config":
            self._send_json(200, {
                "user": os.environ.get("SLURM_USER", ""),
                "group": os.environ.get("SLURM_GROUP", ""),
            })
            return
        if route == "/api/debug":
            self._send_json(200, REFRESH.status())
            return
        if route == "/api/joblog/stream":
            self._stream_joblog()
            return
        if self._maybe_serve_range():
            return
        super().do_GET()

    def _stream_joblog(self):
        global _stream_count
        q = parse_qs(urlparse(self.path).query)
        job = (q.get("job") or [""])[0]
        if not JOBID_RE.match(job):
            self._send_json(400, {"error": "invalid job id"})
            return

        with _stream_count_lock:
            if _stream_count >= JOBLOG_MAX_STREAMS:
                self._send_json(503, {"error": "too many live streams open"})
                return
            _stream_count += 1
        proc = None
        token = "slurmtail_" + uuid.uuid4().hex
        try:
            info = _resolve_job(job)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "keep-alive")
            self.send_header("X-Accel-Buffering", "no")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            def emit(event: str, data: dict):
                msg = f"event: {event}\ndata: {json.dumps(data)}\n\n"
                self.wfile.write(msg.encode("utf-8"))
                self.wfile.flush()

            emit("meta", info)

            out, err = info.get("stdout_path", ""), info.get("stderr_path", "")
            files, seen = [], set()
            for p in (out, err):
                if p and SAFE_PATH_RE.match(p) and p not in seen:
                    files.append(p)
                    seen.add(p)
            if not files:
                emit("end", {"reason": "no log files (job not running?)"})
                return

            quoted = " ".join(f"'{p}'" for p in files)
            # Name the remote tail (argv[0]=token) so we can authoritatively kill
            # exactly this stream's tail on disconnect via `pkill -f <token>`.
            # Neither read-EOF nor PTY-SIGHUP reliably reaps the remote process
            # through the jump host + ControlMaster mux (verified empirically), so
            # an explicit one-shot kill over the persistent master is the robust
            # path and costs ~nothing.
            remote = (
                f"exec -a {token} tail -n {JOBLOG_TAIL_LINES} -F {quoted} 2>/dev/null"
            )
            proc = subprocess.Popen(
                SSH_BASE + [remote],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )

            line_q: queuelib.Queue = queuelib.Queue(maxsize=2000)

            def reader():
                try:
                    for line in proc.stdout:
                        line_q.put(line.rstrip("\n"))
                finally:
                    line_q.put(None)  # sentinel: stream ended

            threading.Thread(target=reader, daemon=True).start()

            while True:
                try:
                    line = line_q.get(timeout=8)
                except queuelib.Empty:
                    # Heartbeat doubles as the disconnect detector: this write
                    # fails once the viewer is gone, so an idle (quiet-job)
                    # stream is reaped within ~8s instead of lingering.
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                    continue
                if line is None:
                    emit("end", {"reason": "log stream closed"})
                    break
                emit("line", {"t": line})
        except (BrokenPipeError, ConnectionResetError):
            pass  # client closed the tab
        except Exception as exc:  # noqa: BLE001
            sys.stderr.write(f"[joblog] {job}: {exc}\n")
        finally:
            with _stream_count_lock:
                _stream_count -= 1
            if proc:
                try:
                    proc.terminate()
                except Exception:
                    pass
            # Authoritative reap of the remote tail (idempotent, cheap over the
            # persistent master). Token is hex-only -> injection-safe.
            try:
                subprocess.run(
                    SSH_BASE + [f"pkill -f {token}"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                )
            except Exception:
                pass


def main():
    import errno as _errno

    # Ensure data directory exists
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    os.chdir(APP_ROOT)
    try:
        srv = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        if exc.errno == _errno.EADDRINUSE:
            sys.stderr.write(
                f"port {PORT} is already in use; set DASHBOARD_PORT to a "
                f"free port (or stop the other process) and retry\n"
            )
            sys.exit(1)
        raise
    with srv:
        sys.stderr.write(
            f"[slurm-dash] listening on {HOST}:{PORT}, "
            f"web_root={WEB_ROOT}, data_dir={DATA_DIR}\n"
        )
        srv.serve_forever()


if __name__ == "__main__":
    main()
