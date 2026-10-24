#!/bin/bash
# Samples Lilo's CPU, wakeups and energy per process role. Usage: sudo energy_sample.sh [-d SECONDS=60] [-l LABEL]
# [-o DIR] [-p PID] [--git] [--top], or energy_sample.sh compare BEFORE.summary.tsv AFTER.summary.tsv
set -euo pipefail

if [ "${1:-}" = "compare" ]; then
    [ $# -eq 3 ] || { echo "usage: $0 compare BEFORE.summary.tsv AFTER.summary.tsv" >&2; exit 2; }
    exec python3 - "$2" "$3" <<'PY'
import sys
def load(p):
    d = {}
    for line in open(p):
        if line.startswith("#") or "\t" not in line:
            continue
        k, v = line.rstrip("\n").split("\t", 1)
        try:
            d[k] = float(v)
        except ValueError:
            pass
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
keys = [k for k in a] + [k for k in b if k not in a]
print(f"{'metric':36}{'before':>12}{'after':>12}{'delta':>10}")
for k in keys:
    x, y = a.get(k), b.get(k)
    if x is None or y is None:
        print(f"{k:36}{x if x is not None else '-':>12}{y if y is not None else '-':>12}{'':>10}")
        continue
    pct = f"{(y - x) / x * 100:+.0f}%" if x else ("=" if y == 0 else "new")
    print(f"{k:36}{x:12.2f}{y:12.2f}{pct:>10}")
PY
fi

DURATION=60
LABEL=run
OUT_DIR=.
LILO_PID=""
COUNT_GIT=false
FORCE_TOP=false
while [ $# -gt 0 ]; do
    case "$1" in
        -d) DURATION="$2"; shift ;;
        -l) LABEL="$2"; shift ;;
        -o) OUT_DIR="$2"; shift ;;
        -p) LILO_PID="$2"; shift ;;
        --git) COUNT_GIT=true ;;
        --top) FORCE_TOP=true ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -n "$LILO_PID" ] || LILO_PID="$(pgrep -nx Lilo || true)"
[ -n "$LILO_PID" ] && kill -0 "$LILO_PID" 2>/dev/null || { echo "Lilo is not running" >&2; exit 1; }
mkdir -p "$OUT_DIR"
BASE="$OUT_DIR/$LABEL"
SUMMARY="$BASE.summary.tsv"
IS_ROOT=false
[ "$(id -u)" -eq 0 ] && IS_ROOT=true
if $COUNT_GIT && ! $IS_ROOT; then echo "--git needs sudo (eslogger)" >&2; exit 1; fi

ESLOGGER_PID=""
cleanup() { [ -z "$ESLOGGER_PID" ] || kill "$ESLOGGER_PID" 2>/dev/null || true; }
trap cleanup EXIT
if $COUNT_GIT; then
    /usr/bin/eslogger exec > "$BASE.exec.jsonl" 2> "$BASE.exec.err" &
    ESLOGGER_PID=$!
    sleep 1
    kill -0 "$ESLOGGER_PID" 2>/dev/null || { echo "eslogger failed (Full Disk Access?): $(cat "$BASE.exec.err")" >&2; exit 1; }
fi

echo "Sampling Lilo pid $LILO_PID for ${DURATION}s, label '$LABEL'" >&2

# powermetrics groups by the fr.arouillard.lilo coalition; top misses short-lived processes such as git, and sees
# LiloPowerHelper (a launchd daemon outside Lilo's tree) only when it runs at start.
if $IS_ROOT && ! $FORCE_TOP; then
    BACKEND=powermetrics
    /usr/bin/powermetrics --samplers tasks,cpu_power --show-process-coalition --show-process-energy \
        -i 1000 -n "$DURATION" -f plist -o "$BASE.powermetrics.plist" >/dev/null 2>&1
else
    BACKEND=top
    # The pid set is fixed now: processes started later (new WebContent, git) are not sampled.
    ps -A -o pid=,ppid=,comm= > "$BASE.ps.txt"
    PIDS="$(python3 - "$LILO_PID" "$BASE.ps.txt" <<'PY'
import sys, os
lilo = int(sys.argv[1])
rows = []
for line in open(sys.argv[2]):
    parts = line.split(None, 2)
    if len(parts) == 3:
        rows.append((int(parts[0]), int(parts[1]), os.path.basename(parts[2].strip())))
keep, frontier = {lilo}, {lilo}
while frontier:
    frontier = {p for p, pp, _ in rows if pp in frontier and p not in keep}
    keep |= frontier
keep |= {p for p, _, c in rows if c.startswith("com.apple.WebKit.") or c == "LiloPowerHelper"}
if not any(c == "LiloPowerHelper" for _, _, c in rows):
    print("LiloPowerHelper is not running (launchd starts it on demand and it exits when idle): not sampled", file=sys.stderr)
print(" ".join(f"-pid {p}" for p in sorted(keep)))
PY
)"
    # -c d: IDLEW is the count over each interval (the default mode reports a stale cumulative value).
    # shellcheck disable=SC2086
    top -l $((DURATION + 1)) -s 1 -c d $PIDS -stats pid,command,cpu,idlew,power > "$BASE.top.txt"
fi

cleanup
ESLOGGER_PID=""

python3 - "$BACKEND" "$BASE" "$LILO_PID" "$DURATION" "$COUNT_GIT" > "$SUMMARY" <<'PY'
import sys, os, json, plistlib, collections
backend, base, lilo, duration, count_git = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5] == "true"
HELPER = "lilopowerhelper"
SHELLS = {"zsh", "bash", "fish", "sh", "login", "nu", "tmux"}

def role(name, pid):
    n = os.path.basename(name).lower()
    if pid == lilo or n == "lilo": return "app"
    if "webcontent" in n: return "webcontent"
    if "networking" in n: return "networking"
    if "webkit.gpu" in n: return "gpu"
    if n == HELPER: return "powerhelper"
    if n == "git": return "git"
    if n.lstrip("-") in SHELLS: return "shells"
    return "children"

ROLES = ["app", "webcontent", "networking", "gpu", "powerhelper", "shells", "git", "children"]
metrics = ["cpu_pct", "idle_wakeups_s", "intr_wakeups_s", "energy_impact_s"]
sums = {r: collections.defaultdict(float) for r in ROLES}
peak = collections.defaultdict(float)
seen = collections.defaultdict(set)
power = []
nsamples = 0

if backend == "powermetrics":
    path = base + ".powermetrics.plist"
    raw = open(path, "rb").read()
    sample_keys, task_keys, layouts = set(), set(), set()
    for chunk in raw.split(b"\0"):
        chunk = chunk.strip()
        if not chunk:
            continue
        try:
            s = plistlib.loads(chunk)
        except Exception:
            continue
        nsamples += 1
        sample_keys |= s.keys()
        tasks = []
        if s.get("coalitions"):
            layouts.add("coalitions")
            for c in s["coalitions"]:
                ctasks = c.get("tasks") or []
                for t in ctasks:
                    task_keys |= t.keys()
                if c.get("name") == "fr.arouillard.lilo" or any(t.get("pid") == lilo for t in ctasks):
                    tasks += ctasks
                else:
                    tasks += [t for t in ctasks if t.get("name", "").lower() == HELPER]
        else:
            layouts.add("tasks")
            for t in s.get("tasks") or []:
                task_keys |= t.keys()
            tasks = [t for t in s.get("tasks") or []
                     if t.get("pid") == lilo or "WebKit" in t.get("name", "") or t.get("name", "").lower() == HELPER]
        per = {r: collections.defaultdict(float) for r in ROLES}
        for t in tasks:
            pid = t.get("pid", -1)
            if pid < 0:
                continue
            r = role(t.get("name", ""), pid)
            seen[r].add(pid)
            per[r]["cpu_pct"] += t.get("cputime_ms_per_s", 0) / 10
            per[r]["idle_wakeups_s"] += t.get("idle_wakeups_per_s", 0)
            per[r]["intr_wakeups_s"] += t.get("intr_wakeups_per_s", 0)
            energy = t.get("energy_impact_per_s")
            per[r]["energy_impact_s"] += t.get("energy_impact", 0) if energy is None else energy
        for r in ROLES:
            for m in metrics:
                sums[r][m] += per[r][m]
            peak[r] = max(peak[r], per[r]["cpu_pct"])
        p = s.get("processor", {})
        mw = p.get("combined_power") or (p.get("package_watts", 0) * 1000) or (p.get("cpu_power", 0) + p.get("gpu_power", 0))
        if mw:
            power.append(mw)
    if not nsamples:
        sys.exit(f"powermetrics: no plist sample could be parsed from {path}")
    wanted = ["cputime_ms_per_s", "idle_wakeups_per_s", "intr_wakeups_per_s", "energy_impact_per_s", "energy_impact"]
    print(f"powermetrics: {nsamples} samples, layout {'+'.join(sorted(layouts))}, sample keys {sorted(sample_keys)}", file=sys.stderr)
    print(f"powermetrics: task keys found {[k for k in wanted if k in task_keys]}, missing {[k for k in wanted if k not in task_keys]}", file=sys.stderr)
    if not any(seen.values()):
        sys.exit(f"powermetrics: no Lilo task found (pid {lilo}, coalition fr.arouillard.lilo, {HELPER}) in {path}")
    if not seen["powerhelper"]:
        print("powermetrics: LiloPowerHelper never ran during the sample", file=sys.stderr)
else:
    comm = {}
    for line in open(base + ".ps.txt"):
        parts = line.split(None, 2)
        if len(parts) == 3:
            comm[int(parts[0])] = parts[2].strip()
    block, blocks = None, []
    for line in open(base + ".top.txt"):
        if line.startswith("PID"):
            block = []
            blocks.append(block)
            continue
        if block is None:
            continue
        f = line.split()
        if len(f) >= 5 and f[0].isdigit():
            try:
                block.append((int(f[0]), float(f[-3]), float(f[-2].rstrip("+")), float(f[-1])))
            except ValueError:
                pass
        elif not line.strip() or line.startswith("Processes:"):
            block = None
    blocks = blocks[1:]  # top's first sample has no CPU delta
    for b in blocks:
        nsamples += 1
        per = {r: collections.defaultdict(float) for r in ROLES}
        for pid, cpu, idlew, pw in b:
            r = role(comm.get(pid, ""), pid)
            seen[r].add(pid)
            per[r]["cpu_pct"] += cpu
            per[r]["idle_wakeups_s"] += idlew
            per[r]["energy_impact_s"] += pw
        for r in ROLES:
            for m in metrics:
                sums[r][m] += per[r][m]
            peak[r] = max(peak[r], per[r]["cpu_pct"])

n = max(nsamples, 1)
print(f"# backend={backend} samples={nsamples} lilo_pid={lilo} duration_s={duration}")
total = collections.defaultdict(float)
for r in ROLES:
    if not seen[r]:
        continue
    for m in metrics:
        if backend == "top" and m == "intr_wakeups_s":
            continue
        v = sums[r][m] / n
        total[m] += v
        print(f"{r}.{m}\t{v:.2f}")
    print(f"{r}.cpu_pct_peak\t{peak[r]:.1f}")
    print(f"{r}.processes\t{len(seen[r])}")
for m in metrics:
    if m in total:
        print(f"total.{m}\t{total[m]:.2f}")
own = sum(sums[r]["cpu_pct"] for r in ("app", "webcontent", "networking", "gpu", "powerhelper")) / n
print(f"lilo_own.cpu_pct\t{own:.2f}")
if power:
    print(f"system.combined_power_mw\t{sum(power) / len(power):.0f}")

if count_git:
    direct = via_shell = spawned = 0
    for line in open(base + ".exec.jsonl", errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        proc = e.get("process", {})
        target = e.get("event", {}).get("exec", {}).get("target", {})
        ppid = target.get("ppid", proc.get("ppid"))
        resp = (target.get("responsible_audit_token") or proc.get("responsible_audit_token") or {}).get("pid")
        if ppid != lilo and resp != lilo:
            continue
        spawned += 1
        if os.path.basename(target.get("executable", {}).get("path", "")) == "git":
            if ppid == lilo:
                direct += 1
            else:
                via_shell += 1
    print(f"exec.total_from_lilo\t{spawned}")
    print(f"exec.git_spawned_by_lilo\t{direct}")
    print(f"exec.git_from_terminal_shells\t{via_shell}")
    print(f"exec.git_spawned_by_lilo_per_min\t{direct * 60 / max(duration, 1):.1f}")
PY

# Under sudo the outputs would otherwise stay owned by root.
[ -z "${SUDO_USER:-}" ] || chown "$SUDO_USER" "$OUT_DIR" "$BASE".*
column -t -s $'\t' "$SUMMARY"
echo "Summary: $SUMMARY" >&2
