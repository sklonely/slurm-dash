#!/usr/bin/env bash
# Dump HPC status to JSON for the dashboard (web/index.html)
# Usage:
#   bash collect.sh           # smart one-shot (skip if queue unchanged)
#   bash collect.sh --force   # force full dump
#   bash collect.sh --loop    # continuous (every 15s, smart)
#
# Output: data/hpc_status.json (consumed by web/index.html)
#
# Requires SLURM_USER environment variable to be set.

set -euo pipefail

if [ -z "${SLURM_USER:-}" ]; then
    echo "ERROR: SLURM_USER is not set. Export it or source config.env first." >&2
    exit 1
fi

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="$APP_ROOT/data/hpc_status.json"
HASH_FILE="$APP_ROOT/data/.hpc_squeue.hash"
# ControlMaster: socket path must stay under 104 chars on macOS (sun_path limit).
# %C is a 16-char hash of conn params, $HOME/.ssh/cm/%C is short and stable.
SSH_CTRL_DIR="$HOME/.ssh/cm"
mkdir -p "$SSH_CTRL_DIR" && chmod 700 "$SSH_CTRL_DIR"
# All connection behavior (multiplexing both hops, keepalive, persist, timeouts)
# lives in the dedicated dashboard SSH config so this script and
# server.py share ONE warm master -- far fewer reconnects/auths on
# the busy submit node. See ssh_config.example for the rationale.
DASH_SSH_CONFIG="$APP_ROOT/ssh_config"
SSH_CMD="ssh -F $DASH_SSH_CONFIG dash-submit"

SAVINGS_FILE="$APP_ROOT/data/hpc_savings.json"

mkdir -p "$APP_ROOT/data"

# Exponential backoff retry for the SSH command. Returns the captured stdout on
# success; returns non-zero on final failure (caller decides whether to keep the
# old JSON). Delays: 1s, 2s, 4s, 8s (capped 30s) + small jitter.
ssh_retry() {
    local cmd="$1"
    local max_attempts="${2:-4}"
    local attempt=1
    local out delay jitter sleep_for
    while [ $attempt -le $max_attempts ]; do
        if out=$($SSH_CMD "$cmd" 2>/dev/null); then
            printf '%s' "$out"
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            delay=$(( 1 << (attempt - 1) ))
            [ $delay -gt 30 ] && delay=30
            jitter=$(( RANDOM % (delay > 1 ? delay : 2) ))
            sleep_for=$(( delay + jitter ))
            echo "[hpc-status] $(date '+%H:%M:%S') ssh attempt $attempt/$max_attempts failed, retry in ${sleep_for}s" >&2
            sleep "$sleep_for"
        fi
        attempt=$((attempt + 1))
    done
    echo "[hpc-status] $(date '+%H:%M:%S') ssh failed after $max_attempts attempts" >&2
    return 1
}

# Cheap change probe: hash structural fields of MY OWN jobs only (set + state +
# reason + node). Deliberately does NOT hash the whole dgxh partition: other
# users' jobs churn every few seconds, which would trip "changed" constantly and
# force full dumps ~every MIN_FULL_DUMP_SEC even when nothing of mine moved. With
# my-jobs-only, a full dump fires when MY queue actually changes (start/finish/
# position) -- the events that matter -- and cluster occupancy + my queue position
# refresh on the MAX_STALE_SEC safety net instead. Excludes elapsed/priority/
# start_time (they fluctuate every second and would defeat the short-circuit).
# ~21ms, reuses ControlMaster.
queue_hash() {
    local raw
    # Only 2 attempts -- this is a cheap probe and dump_once retries fully later.
    raw=$(ssh_retry "squeue -u $SLURM_USER -h --format='%i|%T' 2>/dev/null" 2) || return 1
    # Collapse to BASE-JOB level: strip the array-task suffix (20407258_2 ->
    # 20407258) and emit one line per distinct base id tagged R if ANY of its
    # tasks is running, else P. This makes the hash immune to the things that
    # churn every few seconds but mean nothing for us -- array-task turnover,
    # elapsed time, pending-reason flips, node reassignment -- while still
    # flipping on the events that matter: a job submitted / started / finished.
    # Prefix a constant so "no jobs" hashes to a stable, non-empty value (so it
    # short-circuits normally instead of colliding with EMPTY_HASH; a genuine SSH
    # failure is already caught above by ssh_retry's non-zero return).
    printf 'gmem|%s' "$(printf '%s\n' "$raw" | awk -F'|' '
        { id=$1; sub(/_.*/,"",id); base[id]=1; if ($2=="RUNNING") run[id]=1 }
        END { for (id in base) print id":"(run[id]?"R":"P") }' | sort)" \
        | md5sum 2>/dev/null | cut -d' ' -f1
}

# Change-driven (event-like) refresh policy. The cheap queue_hash probe runs
# every kick (~15s, ~1 squeue); the heavy ~20-query full dump only fires when:
#   - the queue actually CHANGED (job in/out, position shift), but no more often
#     than MIN_FULL_DUMP_SEC apart so a churning queue can't hammer slurmdbd; or
#   - the JSON is older than MAX_STALE_SEC -- a slow safety net that refreshes the
#     slow-changing cluster/account data even when the queue is static.
# Elapsed times tick client-side in the dashboard, so we no longer need frequent
# full dumps just to keep the clock moving.
MAX_STALE_SEC=300
MIN_FULL_DUMP_SEC=30

dump_once() {
    local raw
    raw=$(ssh_retry "
        echo '===QUEUE==='
        squeue -u $SLURM_USER --noheader --format='%i|%j|%T|%M|%D|%R|%P|%l|%b|%E|%C|%m' 2>/dev/null
        echo '===HISTORY==='
        sacct -u $SLURM_USER --starttime=now-24hours --format=JobID%15,JobName%30,State%12,Elapsed,Start,ReqTRES%50 -n 2>/dev/null | grep -v '\\.batch' | grep -v '\\.extern'
        echo '===DGXH_QUEUE==='
        squeue -p dgxh -t RUNNING --noheader --format='%i|%j|%u|RUNNING|%M|%C|%m|%l|%N|0|N/A' --sort=N 2>/dev/null
        squeue -p dgxh -t PENDING --noheader --format='%i|%j|%u|PENDING|0:00|%C|%m|%l|%r|%Q|%S' --sort=-Q 2>/dev/null
        echo '===DGXH_NODES==='
        sinfo -p dgxh -N --noheader --format='%N|%G|%C|%m|%T|%f' 2>/dev/null
        echo '===DGXH_NODE_JOBS==='
        squeue -p dgxh --noheader --format='%N|%i|%j|%u|%T|%C|%m|%l|%S' --sort=N 2>/dev/null
        echo '===DGX2_QUEUE==='
        squeue -p dgx2 -t RUNNING --noheader --format='%i|%j|%u|RUNNING|%M|%C|%m|%l|%N|0|N/A' --sort=N 2>/dev/null
        squeue -p dgx2 -t PENDING --noheader --format='%i|%j|%u|PENDING|0:00|%C|%m|%l|%r|%Q|%S' --sort=-Q 2>/dev/null
        echo '===DGX2_NODES==='
        sinfo -p dgx2 -N --noheader --format='%N|%G|%C|%m|%T|%f' 2>/dev/null
        echo '===DGX2_NODE_JOBS==='
        squeue -p dgx2 --noheader --format='%N|%i|%j|%u|%T|%C|%m|%l|%S' --sort=N 2>/dev/null
        echo '===GPU_QUEUE==='
        squeue -p gpu -t RUNNING --noheader --format='%i|%j|%u|RUNNING|%M|%C|%m|%l|%N|0|N/A' --sort=N 2>/dev/null
        squeue -p gpu -t PENDING --noheader --format='%i|%j|%u|PENDING|0:00|%C|%m|%l|%r|%Q|%S' --sort=-Q 2>/dev/null
        echo '===AMPERE_QUEUE==='
        squeue -p ampere -t RUNNING --noheader --format='%i|%j|%u|RUNNING|%M|%C|%m|%l|%N|0|N/A' --sort=N 2>/dev/null
        squeue -p ampere -t PENDING --noheader --format='%i|%j|%u|PENDING|0:00|%C|%m|%l|%r|%Q|%S' --sort=-Q 2>/dev/null
        echo '===GPU_NODES==='
        sinfo -p gpu -N --noheader --format='%N|%G|%C|%m|%T|%f' 2>/dev/null
        echo '===GPU_NODE_JOBS==='
        squeue -p gpu -t RUNNING --noheader --format='%N|%i|%j|%u|%T|%C|%m|%l|%S' --sort=N 2>/dev/null
        echo '===AMPERE_NODES==='
        sinfo -p ampere -N --noheader --format='%N|%G|%C|%m|%T|%f' 2>/dev/null
        echo '===AMPERE_NODE_JOBS==='
        squeue -p ampere -t RUNNING --noheader --format='%N|%i|%j|%u|%T|%C|%m|%l|%S' --sort=N 2>/dev/null
        echo '===SHARE_NODES==='
        sinfo -p share -N --noheader --format='%N|%G|%C|%m|%T|%f' 2>/dev/null
        echo '===SHARE_NODE_JOBS==='
        squeue -p share -t RUNNING --noheader --format='%N|%i|%j|%u|%T|%C|%m|%l|%S' --sort=N 2>/dev/null
        echo '===PART_SQUEUE==='
        squeue -a -h -t RUNNING,PENDING --format='%P|%T' 2>/dev/null
        echo '===PART_SINFO==='
        sinfo -h --format='%P|%D|%A|%G' 2>/dev/null
        echo '===NODE_GPU==='
        scontrol -o show node 2>/dev/null | grep 'gres/gpu=' | awk '{
          name=\"\"; cfg=\"\"; alloc=\"\"
          for (i=1;i<=NF;i++) {
            if (\$i ~ /^NodeName=/) name=substr(\$i,10)
            if (\$i ~ /^CfgTRES=/) cfg=substr(\$i,9)
            if (\$i ~ /^AllocTRES=/) alloc=substr(\$i,11)
          }
          cfg_gpu=0; alloc_gpu=0
          n=split(cfg, ca, \",\"); for (j=1;j<=n;j++) if (ca[j] ~ /gres\\/gpu=/) { sub(/.*gres\\/gpu=/, \"\", ca[j]); cfg_gpu=ca[j]+0 }
          n=split(alloc, aa, \",\"); for (j=1;j<=n;j++) if (aa[j] ~ /gres\\/gpu=/) { sub(/.*gres\\/gpu=/, \"\", aa[j]); alloc_gpu=aa[j]+0 }
          print name \"|\" alloc_gpu \"|\" cfg_gpu
        }'
        echo '===PARTITIONS==='
        sinfo --noheader --format='%P|%a|%D|%A|%l|%G' --sort=P 2>/dev/null
        echo '===ACCOUNT==='
        echo 'HOME_USED:'
        df -Pm /nfs/stak/users/$SLURM_USER 2>/dev/null | awk 'NR==2{print \$3}'
        echo 'HOME_TOTAL:25600'
        echo 'SHARE_USED:'
        lfs quota -u $SLURM_USER /nfs/hpc/share 2>/dev/null | grep '/nfs/hpc/share' | awk '{print int(\$2/1024)}'
        echo 'SHARE_TOTAL:1572864'
        echo 'FAIRSHARE:'
        sshare -u $SLURM_USER -l --format=User,FairShare,EffectvUsage,RawUsage -n 2>/dev/null | grep $SLURM_USER
        echo 'DGXH_QOS:'
        sacctmgr show qos where name=dgxh format=MaxTRESRunMinsPerUser%50 -n 2>/dev/null
        echo '===END==='
    " 4) || return 1

    # Sanity: the END marker proves the remote command ran fully. Without it
    # the JSON would be a truncated snapshot -- keep the old one instead.
    if ! printf '%s' "$raw" | grep -q '===END==='; then
        echo "[hpc-status] $(date '+%H:%M:%S') ERROR: incomplete SSH output, keeping previous JSON" >&2
        return 1
    fi

    # Atomic write via temp file: dashboard never reads a half-written JSON.
    local tmp="${OUT}.tmp.$$"
    if ! SLURM_RAW="$raw" SLURM_USER="$SLURM_USER" python3 -c "
import json, os, sys
from datetime import datetime

slurm_user = os.environ['SLURM_USER']

# Pass the SSH payload via env, NOT string-interpolated into the source: a job
# name containing ''' / backslash / \$ would otherwise break the whole parse and
# silently freeze the dashboard. (Mirrors the savings-refresh block below.)
raw = os.environ['SLURM_RAW']
lines = raw.strip().split('\n')

section = None
queue = []
history = []
partitions = []
dgxh_queue = []
dgxh_nodes = []
dgxh_node_jobs = []
dgx2_queue = []
dgx2_nodes = []
dgx2_node_jobs = []
gpu_queue = []
ampere_queue = []
gpu_nodes = []
gpu_node_jobs = []
ampere_nodes = []
ampere_node_jobs = []
share_nodes = []
share_node_jobs = []
part_counts = []
# Cluster-wide partition occupancy, aggregated client-side from one squeue +
# one sinfo (was 7 partitions x 5 per-partition RPCs = 35 calls before).
WANT_PARTS = ['dgxh', 'dgx2', 'dgxs', 'gpu', 'ampere', 'share', 'eecs']
pc_running = {p: 0 for p in WANT_PARTS}
pc_pending = {p: 0 for p in WANT_PARTS}
pc_nodes = {p: 0 for p in WANT_PARTS}
pc_alloc = {p: 0 for p in WANT_PARTS}
pc_gres = {p: '' for p in WANT_PARTS}
node_gpu = {}
account_info = {}

def parse_node_row(parts):
    cpus = parts[2].strip().split('/')
    return {
        'name': parts[0].strip(),
        'gres': parts[1].strip(),
        'cpu_alloc': int(cpus[0]) if cpus[0].isdigit() else 0,
        'cpu_idle': int(cpus[1]) if len(cpus)>1 and cpus[1].isdigit() else 0,
        'cpu_total': int(cpus[3]) if len(cpus)>3 and cpus[3].isdigit() else 0,
        'mem_mb': int(parts[3].strip()) if parts[3].strip().isdigit() else 0,
        'state': parts[4].strip(),
        'features': parts[5].strip(),
    }

def parse_node_job_row(parts):
    return {
        'node': parts[0].strip(),
        'id': parts[1].strip(),
        'name': parts[2].strip(),
        'user': parts[3].strip(),
        'state': parts[4].strip(),
        'cpus': parts[5].strip(),
        'mem': parts[6].strip(),
        'timelimit': parts[7].strip(),
        'start': parts[8].strip() if len(parts) > 8 else '',
        'is_mine': parts[3].strip() == slurm_user,
    }

def parse_part_queue_row(parts):
    node_or_reason = parts[8].strip()
    return {
        'id': parts[0].strip(),
        'name': parts[1].strip(),
        'user': parts[2].strip(),
        'state': parts[3].strip(),
        'time': parts[4].strip(),
        'cpus': parts[5].strip(),
        'mem': parts[6].strip(),
        'timelimit': parts[7].strip(),
        'node': node_or_reason if '(' not in node_or_reason else '',
        'reason': node_or_reason if '(' in node_or_reason else '',
        'priority': parts[9].strip() if len(parts) > 9 else '',
        'start_time': parts[10].strip() if len(parts) > 10 else '',
        'is_mine': parts[2].strip() == slurm_user,
    }

for line in lines:
    line = line.strip()
    if line == '===QUEUE===': section = 'queue'; continue
    if line == '===HISTORY===': section = 'history'; continue
    if line == '===PARTITIONS===': section = 'partitions'; continue
    if line == '===DGXH_QUEUE===': section = 'dgxh_queue'; continue
    if line == '===DGXH_NODES===': section = 'dgxh_nodes'; continue
    if line == '===DGXH_NODE_JOBS===': section = 'dgxh_node_jobs'; continue
    if line == '===DGX2_QUEUE===': section = 'dgx2_queue'; continue
    if line == '===DGX2_NODES===': section = 'dgx2_nodes'; continue
    if line == '===DGX2_NODE_JOBS===': section = 'dgx2_node_jobs'; continue
    if line == '===GPU_QUEUE===': section = 'gpu_queue'; continue
    if line == '===AMPERE_QUEUE===': section = 'ampere_queue'; continue
    if line == '===GPU_NODES===': section = 'gpu_nodes'; continue
    if line == '===GPU_NODE_JOBS===': section = 'gpu_node_jobs'; continue
    if line == '===AMPERE_NODES===': section = 'ampere_nodes'; continue
    if line == '===AMPERE_NODE_JOBS===': section = 'ampere_node_jobs'; continue
    if line == '===SHARE_NODES===': section = 'share_nodes'; continue
    if line == '===SHARE_NODE_JOBS===': section = 'share_node_jobs'; continue
    if line == '===PART_SQUEUE===': section = 'part_squeue'; continue
    if line == '===PART_SINFO===': section = 'part_sinfo'; continue
    if line == '===NODE_GPU===': section = 'node_gpu'; continue
    if line == '===ACCOUNT===': section = 'account'; continue
    if line == '===END===': break
    if not line: continue

    if section == 'queue':
        parts = line.split('|')
        if len(parts) >= 6:
            queue.append({
                'id': parts[0].strip(),
                'name': parts[1].strip(),
                'state': parts[2].strip(),
                'time': parts[3].strip(),
                'node': parts[5].strip().split('(')[0] if '(' not in parts[5] else '',
                'partition': parts[6].strip() if len(parts) > 6 else '',
                'reason': parts[5].strip() if '(' in parts[5] else '',
                'timelimit': parts[7].strip() if len(parts) > 7 else '',
                'gres': parts[8].strip() if len(parts) > 8 else '',
                'dep_raw': parts[9].strip() if len(parts) > 9 else '',
                'cpus': parts[10].strip() if len(parts) > 10 else '',
                'mem': parts[11].strip() if len(parts) > 11 else '',
            })

    elif section == 'dgxh_nodes':
        parts = line.split('|')
        if len(parts) >= 6: dgxh_nodes.append(parse_node_row(parts))

    elif section == 'dgxh_node_jobs':
        parts = line.split('|')
        if len(parts) >= 8: dgxh_node_jobs.append(parse_node_job_row(parts))

    elif section == 'dgx2_nodes':
        parts = line.split('|')
        if len(parts) >= 6: dgx2_nodes.append(parse_node_row(parts))

    elif section == 'dgx2_node_jobs':
        parts = line.split('|')
        if len(parts) >= 8: dgx2_node_jobs.append(parse_node_job_row(parts))

    elif section == 'dgx2_queue':
        parts = line.split('|')
        if len(parts) >= 9: dgx2_queue.append(parse_part_queue_row(parts))

    elif section == 'gpu_queue':
        parts = line.split('|')
        if len(parts) >= 9: gpu_queue.append(parse_part_queue_row(parts))

    elif section == 'ampere_queue':
        parts = line.split('|')
        if len(parts) >= 9: ampere_queue.append(parse_part_queue_row(parts))

    elif section == 'gpu_nodes':
        parts = line.split('|')
        if len(parts) >= 6: gpu_nodes.append(parse_node_row(parts))

    elif section == 'gpu_node_jobs':
        parts = line.split('|')
        if len(parts) >= 8: gpu_node_jobs.append(parse_node_job_row(parts))

    elif section == 'ampere_nodes':
        parts = line.split('|')
        if len(parts) >= 6: ampere_nodes.append(parse_node_row(parts))

    elif section == 'ampere_node_jobs':
        parts = line.split('|')
        if len(parts) >= 8: ampere_node_jobs.append(parse_node_job_row(parts))

    elif section == 'share_nodes':
        parts = line.split('|')
        if len(parts) >= 6: share_nodes.append(parse_node_row(parts))

    elif section == 'share_node_jobs':
        parts = line.split('|')
        if len(parts) >= 8: share_node_jobs.append(parse_node_job_row(parts))

    elif section == 'part_squeue':
        parts = line.split('|')
        if len(parts) >= 2:
            state = parts[1].strip()
            # %P may be a comma list (a pending job eligible in several parts);
            # count it toward each, matching the old per-partition squeue -p.
            for pname in parts[0].strip().split(','):
                pname = pname.rstrip('*').strip()
                if pname in pc_running:
                    if state == 'RUNNING':
                        pc_running[pname] += 1
                    elif state == 'PENDING':
                        pc_pending[pname] += 1

    elif section == 'part_sinfo':
        parts = line.split('|')
        if len(parts) >= 4:
            pname = parts[0].strip().rstrip('*')
            if pname in pc_nodes:
                d = parts[1].strip()
                pc_nodes[pname] += int(d) if d.isdigit() else 0
                aio = parts[2].strip().split('/')
                pc_alloc[pname] += int(aio[0]) if aio and aio[0].isdigit() else 0
                g = parts[3].strip()
                if g and g != '(null)' and not pc_gres[pname]:
                    pc_gres[pname] = g

    elif section == 'node_gpu':
        parts = line.split('|')
        if len(parts) >= 3:
            node_gpu[parts[0].strip()] = {
                'gpu_alloc': int(parts[1].strip()) if parts[1].strip().isdigit() else 0,
                'gpu_total': int(parts[2].strip()) if parts[2].strip().isdigit() else 0,
            }

    elif section == 'history':
        # Fixed-width sacct output -- parse by position
        jid = line[:15].strip()
        name = line[15:45].strip()
        state = line[45:57].strip()
        elapsed = line[57:69].strip()
        start = line[69:89].strip()
        tres = line[89:].strip()
        gpu = ''
        if 'gres/gpu=' in tres:
            import re
            m = re.search(r'gres/gpu=(\d+)', tres)
            if m: gpu = f'{m.group(1)} GPU'
        history.append({
            'id': jid, 'name': name, 'state': state,
            'elapsed': elapsed, 'start': start, 'gpu': gpu,
        })

    elif section == 'partitions':
        parts = line.split('|')
        if len(parts) >= 6:
            name = parts[0].strip()
            is_default = name.endswith('*')
            name = name.rstrip('*')
            aio = parts[3].strip().split('/')
            a = int(aio[0]) if len(aio) > 0 and aio[0].isdigit() else 0
            i = int(aio[1]) if len(aio) > 1 and aio[1].isdigit() else 0
            total = int(parts[2].strip()) if parts[2].strip().isdigit() else 0
            o = total - a - i
            partitions.append({
                'name': name, 'default': is_default,
                'total': total, 'alloc': a, 'idle': i, 'other': max(0, o),
                'timelimit': parts[4].strip(),
                'gres': parts[5].strip(),
            })

    elif section == 'dgxh_queue':
        parts = line.split('|')
        if len(parts) >= 9: dgxh_queue.append(parse_part_queue_row(parts))

    elif section == 'account':
        if line.startswith('HOME_USED:'):
            pass  # next line is value
        elif line.startswith('HOME_TOTAL:'):
            account_info['home_total_mb'] = int(line.split(':')[1])
        elif line.startswith('SHARE_TOTAL:'):
            account_info['share_total_mb'] = int(line.split(':')[1])
        elif line.startswith('FAIRSHARE:'):
            pass  # next line has data
        elif line.startswith('DGXH_QOS:'):
            pass  # next line has data
        elif line.strip().isdigit():
            if 'home_used_mb' not in account_info:
                account_info['home_used_mb'] = int(line.strip())
            else:
                account_info['share_used_mb'] = int(line.strip())
        elif slurm_user in line and section == 'account':
            parts = line.split()
            for p in parts:
                try:
                    f = float(p)
                    if 0 < f < 1 and 'fairshare' not in account_info:
                        account_info['fairshare'] = round(f, 4)
                except: pass
        elif 'gres/gpu=' in line:
            import re as _r
            m = _r.search(r'gres/gpu=(\d+)', line)
            if m: account_info['dgxh_gpu_runmins_limit'] = int(m.group(1))

# Materialize cluster-wide partition occupancy from the aggregated counters.
part_counts = [{
    'name': p,
    'running': pc_running[p],
    'pending': pc_pending[p],
    'nodes_total': pc_nodes[p],
    'nodes_alloc': pc_alloc[p],
    'gres': pc_gres[p],
} for p in WANT_PARTS]

# GPU-hours / cloud-cost-saved is maintained by the hourly cold-tier scan
# (refresh_cost -> hpc_savings.json). The per-refresh dump only loads & embeds
# it, keeping the 2-month sacct off the hot path.
import os
savings_path = os.environ.get('SAVINGS_FILE', '$SAVINGS_FILE')
try:
    with open(savings_path) as f:
        persistent = json.load(f)
except:
    persistent = {'seen_jobs': [], 'total_hours': 0, 'total_savings': 0, 'partition_hours': {}}

# share has ~62 nodes, mostly pure CPU -- keep only GPU-bearing ones for the dashboard.
share_nodes = [n for n in share_nodes if 'gpu' in (n.get('gres') or '').lower()]

# Merge GPU alloc into node records by name
for n in dgxh_nodes + dgx2_nodes + gpu_nodes + ampere_nodes + share_nodes:
    g = node_gpu.get(n['name'])
    if g:
        n['gpu_alloc'] = g['gpu_alloc']
        n['gpu_total'] = g['gpu_total']

data = {
    'timestamp': datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
    'queue': queue,
    'history': history,
    'partitions': partitions,
    'part_counts': part_counts,
    'dgxh_queue': dgxh_queue,
    'dgxh_nodes': dgxh_nodes,
    'dgxh_node_jobs': dgxh_node_jobs,
    'dgx2_queue': dgx2_queue,
    'dgx2_nodes': dgx2_nodes,
    'dgx2_node_jobs': dgx2_node_jobs,
    'gpu_queue': gpu_queue,
    'ampere_queue': ampere_queue,
    'gpu_nodes': gpu_nodes,
    'gpu_node_jobs': gpu_node_jobs,
    'ampere_nodes': ampere_nodes,
    'ampere_node_jobs': ampere_node_jobs,
    'share_nodes': share_nodes,
    'share_node_jobs': share_node_jobs,
    'account': account_info,
    'savings': persistent,
}
print(json.dumps(data, indent=2))
" > "$tmp"; then
        rm -f "$tmp"
        echo "[hpc-status] $(date '+%H:%M:%S') ERROR: JSON render failed, keeping previous JSON" >&2
        return 1
    fi
    mv "$tmp" "$OUT"

    echo "[hpc-status] $(date '+%H:%M:%S') -> $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
}

# Cold tier: the cumulative GPU-hours / cloud-cost-saved figure comes from a
# 2-month `sacct` scan -- by far the heaviest query we issue (it hits the
# slurmdbd accounting DB on disk, not the in-memory controller). It's a slow,
# cumulative number, so we refresh it at most ONCE A DAY into hpc_savings.json;
# the per-refresh dump just reads that file. This is the single biggest cut to
# our disk/DB footprint on the OSU side. Gated on the savings-file mtime; set
# COST_FORCE=1 (or `--cost`) to force a refresh now.
COST_MAX_AGE="${COST_MAX_AGE:-86400}"
refresh_cost() {
    local age raw
    if [ "${COST_FORCE:-0}" != "1" ] && [ -f "$SAVINGS_FILE" ]; then
        age=$(( $(date +%s) - $(stat -f %m "$SAVINGS_FILE" 2>/dev/null || stat -c %Y "$SAVINGS_FILE" 2>/dev/null || echo 0) ))
        [ "$age" -lt "$COST_MAX_AGE" ] && return 0
    fi
    # Track the whole account, not a job-name pattern: job names/IDs churn
    # but the account doesn't, so a `grep` filter silently froze the total
    # once naming moved on. `-X` keeps only the job allocation (no
    # .batch/.extern double-count); `-P` is pipe-delimited so an empty
    # Partition column can't shift positional parsing.
    raw=$(ssh_retry "sacct -u $SLURM_USER -X --starttime=2026-04-01 --format=Elapsed,Partition,State -P -n 2>/dev/null" 2) || return 1
    # Raw passed via env (not string-interpolated) so newlines/quotes can't break it.
    if ! SAVINGS_RAW="$raw" SAVINGS_FILE="$SAVINGS_FILE" python3 - <<'PYEOF'
import json, os
from datetime import datetime

raw = os.environ.get("SAVINGS_RAW", "")
path = os.environ["SAVINGS_FILE"]

# Cloud GPU pricing (USD/hour per GPU), by partition hardware.
RATES = {"dgxh": 4.00, "gpu": 1.50, "eecs": 0.50, "dgx2": 2.00, "share": 1.50, "ampere": 1.50, "preempt": 1.50}

def parse_elapsed(s):
    """Parse DD-HH:MM:SS or HH:MM:SS to hours."""
    try:
        days = 0
        if "-" in s:
            d, s = s.split("-", 1)
            days = int(d)
        p = s.split(":")
        h = int(p[0]) if len(p) > 0 else 0
        m = int(p[1]) if len(p) > 1 else 0
        sec = int(p[2]) if len(p) > 2 else 0
        return days * 24 + h + m / 60 + sec / 3600
    except Exception:
        return 0

total_hours = 0.0
total_savings = 0.0
part_hours = {}
for line in raw.strip().splitlines():
    parts = line.split("|")  # Elapsed|Partition|State
    if len(parts) >= 2 and ":" in parts[0]:
        part = parts[1]
        hrs = parse_elapsed(parts[0])
        total_hours += hrs
        total_savings += hrs * RATES.get(part, 1.00)
        part_hours[part] = part_hours.get(part, 0) + hrs

try:
    with open(path) as f:
        persistent = json.load(f)
except Exception:
    persistent = {"seen_jobs": []}

# Never overwrite a good total with zeros if the scan came back empty.
if raw.strip():
    persistent["total_hours"] = round(total_hours, 2)
    persistent["total_savings"] = round(total_savings, 2)
    persistent["partition_hours"] = {k: round(v, 2) for k, v in part_hours.items()}
    persistent["last_updated"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(path, "w") as f:
        json.dump(persistent, f, indent=2)
    print("[hpc-status] cost refreshed: %.1f GPU-hrs, $%.0f saved" % (total_hours, total_savings))
else:
    print("[hpc-status] cost scan returned no rows; keeping previous savings")
PYEOF
    then
        return 1
    fi
    # Honor the hourly gate even on an empty scan (mtime = last attempt).
    touch "$SAVINGS_FILE" 2>/dev/null || true
}

# Smart wrapper: skip dump_once when queue hash unchanged AND JSON is fresh.
# Empty hash (md5 of empty input = d41d8cd98f00b204e9800998ecf8427e) means SSH
# probe failed -- don't trust it, fall through to dump_once.
EMPTY_HASH="d41d8cd98f00b204e9800998ecf8427e"
smart_dump() {
    local cur last age
    # Piggyback the hourly-throttled cost refresh; never let it block the queue dump.
    refresh_cost || true
    cur=$(queue_hash 2>/dev/null || true)
    if [ -n "$cur" ] && [ "$cur" != "$EMPTY_HASH" ] && [ -f "$HASH_FILE" ] && [ -f "$OUT" ]; then
        last=$(cat "$HASH_FILE" 2>/dev/null || true)
        # macOS stat -f %m, Linux stat -c %Y -- try both.
        age=$(( $(date +%s) - $(stat -f %m "$OUT" 2>/dev/null || stat -c %Y "$OUT" 2>/dev/null || echo 0) ))
        if [ "$cur" = "$last" ]; then
            # Static queue: probe only until the slow-data safety net expires.
            if [ "$age" -lt "$MAX_STALE_SEC" ]; then
                echo "[hpc-status] $(date '+%H:%M:%S') unchanged (probe only, age=${age}s)"
                return 0
            fi
        else
            # Queue changed: refresh ASAP, but coalesce rapid churn so we don't
            # hammer slurmdbd/Lustre -- keep probing (hash stays un-committed) until
            # MIN_FULL_DUMP_SEC has elapsed since the last full dump.
            if [ "$age" -lt "$MIN_FULL_DUMP_SEC" ]; then
                echo "[hpc-status] $(date '+%H:%M:%S') changed, coalescing (probe only, age=${age}s)"
                return 0
            fi
        fi
    fi
    if dump_once; then
        if [ -n "$cur" ] && [ "$cur" != "$EMPTY_HASH" ]; then
            echo "$cur" > "$HASH_FILE"
        fi
        return 0
    fi
    return 1
}

case "${1:-}" in
    --loop)
        echo "[hpc-status] Continuous smart mode -- probe every 60s, Ctrl+C to stop"
        # set +e so a transient SSH failure doesn't kill the loop under set -euo pipefail.
        set +e
        while true; do
            smart_dump || echo "[hpc-status] $(date '+%H:%M:%S') dump failed, will retry next cycle" >&2
            sleep 60
        done
        ;;
    --force)
        refresh_cost || true
        if dump_once; then
            cur=$(queue_hash 2>/dev/null || true)
            if [ -n "$cur" ] && [ "$cur" != "$EMPTY_HASH" ]; then
                echo "$cur" > "$HASH_FILE"
            fi
        else
            exit 1
        fi
        ;;
    --cost)
        COST_FORCE=1 refresh_cost || { echo "[hpc-status] cost refresh failed" >&2; exit 1; }
        ;;
    *)
        smart_dump || exit 1
        ;;
esac
