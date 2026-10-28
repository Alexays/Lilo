#!/bin/bash
# Times a Release Lilo with 20 store extensions and a probe on a throwaway profile: launch to extensions restored,
# per-extension preparation (cold, then stamped), worker starts, tabs.query and storage.get latency, and idle CPU.
# Usage: bench_extensions.sh [runs=5] [--no-build] [--idle SECONDS=60] [--out DIR] [--max-idle-cpu LILO,WEBKIT]
# --max-idle-cpu exits non-zero when idle CPU % of Lilo or of its WebKit processes goes over that budget.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.derived.noindex/bench"
APP="$DERIVED/Build/Products/Release/Lilo.app"
PACKAGES="$ROOT/build/ext-bench"
RUNS=5
BUILD=true
IDLE=60
KEEP=""
MAX_IDLE_CPU=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=false ;;
        --idle) IDLE="$2"; shift ;;
        --out) KEEP="$2"; [[ $KEEP = /* ]] || KEEP="$PWD/$KEEP"; shift ;;
        --max-idle-cpu) MAX_IDLE_CPU="$2"; shift ;;
        *) RUNS="$1" ;;
    esac
    shift
done

# From the top of LiloTests/Extensions/top-extensions.json: ad blockers, password managers, dark mode, grammar,
# translators, and other heavy workers.
EXTENSIONS=(
    efaidnbmnnnibpcajpcglclefindmkaj # Adobe Acrobat
    gighmmpiobklfepjocnamgkkbiglidom # AdBlock
    cfhdojbkjhnklbpkdaibdccddilifddb # Adblock Plus
    kbfnbcaeplbcioakkpcpgfkobkghlhen # Grammarly
    aapbdbdomjkkjkaonfhkkikfgjllcleb # Google Translate
    ddkjiahejlhfcafbddmgiahcphecmpfh # uBlock Origin Lite
    bgnkhhnnamicmpeenaelnjfhikgbkllg # AdGuard
    bmnlcjabgnpnenekpadlanbbkooimhnj # Honey
    dhdgffkkebhmkfjojejmpbldmpobfkfo # Tampermonkey
    ihcjicgdanjaechkgeegckofjjedodee # Malwarebytes Browser Guard
    fdpohaocaechififmbbbbbknoalclacl # GoFullPage
    eiaeiblijfjekdanodkjadfinkhbfgcd # NordPass
    ekhagklcjbdpajgpjgmbionohlpdbjgc # Zotero Connector
    caljgklbbfbcjjanaijlacgncafpegll # Avira Password Manager
    hdokiejnpimakedhajhdlcegeplioahd # LastPass
    nngceckbapebfimnlniiiahkandclblb # Bitwarden
    aeblfdkhhhdcdjpifhhbdiojplfjncoa # 1Password
    eimadpbcbfnmbkopoojfekhnkhdbieeh # Dark Reader
    jghecgabfgfdldnmbfkhmffcabddioke # Volume Master
    aopddeflghjljihihabdclejbojaomaf # AnyDoc Translator
)

if [ -n "$MAX_IDLE_CPU" ] && ! [[ $MAX_IDLE_CPU =~ ^[0-9.]+,[0-9.]+$ ]]; then
    echo "--max-idle-cpu takes LILO,WEBKIT percentages, like 35,25" >&2
    exit 1
fi

if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    echo "The screen is locked: unlock it to benchmark launches." >&2
    exit 1
fi

if $BUILD; then
    make -C "$ROOT" vt-build ui-build >/dev/null
    # Ad-hoc signed: library validation would reject the embedded Sparkle.framework under the hardened runtime.
    xcodebuild -project "$ROOT/Lilo.xcodeproj" -scheme Lilo -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build >/dev/null
fi

# Downloaded once, as the store serves them to Chrome; delete build/ext-bench for newer versions.
PROD_VERSION=$(grep -o 'Chrome/[0-9.]*' "$ROOT/Lilo/Engine/ChromeMasquerade.swift" | head -1 | cut -d/ -f2)
for id in "${EXTENSIONS[@]}"; do
    [ -f "$PACKAGES/$id/manifest.json" ] && continue
    mkdir -p "$PACKAGES"
    curl -fsSL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/$PROD_VERSION" -o "$PACKAGES/$id.crx" \
        "https://clients2.google.com/service/update2/crx?response=redirect&os=mac&arch=x86-64&nacl_arch=x86-64&prod=chromecrx&prodchannel=stable&prodversion=$PROD_VERSION&acceptformat=crx3&x=id%3D$id%26installsource%3Dondemand%26uc"
    # CRX3: magic, version, header length (little endian), header, then the zip.
    python3 -I -c 'import sys, struct; d = open(sys.argv[1], "rb").read(); open(sys.argv[2], "wb").write(d[12 + struct.unpack("<I", d[8:12])[0]:])' \
        "$PACKAGES/$id.crx" "$PACKAGES/$id.zip"
    /bin/rm -rf "$PACKAGES/$id.tmp"
    unzip -qo "$PACKAGES/$id.zip" -d "$PACKAGES/$id.tmp" || true
    /bin/rm -f "$PACKAGES/$id.crx" "$PACKAGES/$id.zip"
    [ -f "$PACKAGES/$id.tmp/manifest.json" ] || { echo "$id: no manifest in its package" >&2; exit 1; }
    /bin/mv -f "$PACKAGES/$id.tmp" "$PACKAGES/$id"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lilo-ext-bench.XXXXXX")"
SERVER_PID=""
APP_PID=""
trap '[ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true; [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; [ -z "$KEEP" ] || { mkdir -p "$KEEP" && /bin/cp -f "$WORK"/out/* "$KEEP"/ 2>/dev/null || true; }; /bin/rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/out" "$WORK/site"
# CFFIXED_USER_HOME moves preferences, caches and WebKit data under the throwaway home, and
# LILO_APP_SUPPORT_DIR the database: the real profile is never read or written.
PROFILE=(CFFIXED_USER_HOME="$WORK/home" LILO_APP_SUPPORT_DIR="$WORK/home/support")

# The probe reports its timings as a request to this server, whose log the summary reads.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" 2>"$WORK/server.log" >/dev/null &
SERVER_PID=$!
disown "$SERVER_PID"
printf '<!doctype html><title>Bench</title><h1>Bench</h1>' > "$WORK/site/index.html"

# Waits for a launch that quits itself once the chrome is ready and `linger` seconds passed.
launch() {
    local out="$1" linger="$2"
    env "${PROFILE[@]}" LILO_STARTUP_BENCH_OUT="$out" LILO_STARTUP_BENCH_LINGER="$linger" \
        ${SEED_URLS:+LILO_BENCH_SEED_URLS="$SEED_URLS"} "$APP/Contents/MacOS/Lilo" >/dev/null 2>&1 &
    APP_PID=$!
    for _ in $(seq 1 1200); do
        kill -0 "$APP_PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then kill "$APP_PID"; echo "launch timed out" >&2; exit 1; fi
    LAUNCHED_PID=$APP_PID
    APP_PID=""
}

# The first launch creates the profile with one restored page and lets the filter lists compile, then quits.
SEED_URLS="http://127.0.0.1:$PORT/" launch "$WORK/seed.json" 25
SEED_URLS=""
DB="$WORK/home/support/global.db"
PROFILE_ID=$(sqlite3 "$DB" "SELECT id FROM profiles ORDER BY isDefault DESC LIMIT 1")
EXT_DIR="$WORK/home/support/Profiles/$PROFILE_ID/Extensions"
mkdir -p "$EXT_DIR"
# Installed as the store installs them: one folder per id in the profile's extensions folder, and its record.
for id in "${EXTENSIONS[@]}" probe; do
    if [ "$id" = probe ]; then
        /bin/cp -R "$ROOT/bench/extensions/probe" "$EXT_DIR/probe"
        sed -i '' "s/__PORT__/$PORT/" "$EXT_DIR/probe/worker.js"
    else
        /bin/cp -cR "$PACKAGES/$id" "$EXT_DIR/$id"
    fi
    sqlite3 "$DB" "INSERT INTO installed_extensions (id, profile_id, name, version, install_date, path) VALUES ('$id', '$PROFILE_ID', '$id', \
        '$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8-sig"))["version"])' "$EXT_DIR/$id/manifest.json")', datetime('now'), '$EXT_DIR/$id')"
done
# No onboarding, and no update check (90 s after launch at the earliest) in the idle window.
sqlite3 "$DB" "UPDATE settings SET value = 'true' WHERE key = 'onboardingCompleted'; \
    INSERT OR REPLACE INTO settings (key, value) VALUES ('extensionUpdateLastCheck', '$(date +%s)')"

# Run 1 prepares every extension and starts every worker for the first time; the next ones find them stamped.
for i in $(seq 1 "$RUNS"); do
    START="$(date '+%Y-%m-%d %H:%M:%S')"
    SERVED=$(wc -l < "$WORK/server.log")
    launch "$WORK/out/run-$i.json" 15
    /usr/bin/log show --signpost --style ndjson --start "$START" \
        --predicate "subsystem == \"fr.arouillard.lilo\" AND (category == \"extensions\" OR category == \"startup\") AND processIdentifier == $LAUNCHED_PID" \
        | jq -c 'select(.eventType == "signpostEvent" or (.eventMessage // "" | startswith("startup event=")))' > "$WORK/out/run-$i.ndjson"
    tail -n +$((SERVED + 1)) "$WORK/server.log" | grep -ao 'GET /report?[^ ]*' > "$WORK/out/probe-$i.txt" || true
done

# CPU time and wakeups so far of Lilo and of the WebKit processes it is responsible for, without sudo: top reports
# no wakeups, powermetrics needs root.
usage() {
    python3 -I - "$APP_PID" <<'PY'
import ctypes, json, subprocess, sys
libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))
app = int(sys.argv[1])
usage = {}
for pid in [app] + [int(p) for p in subprocess.run(["pgrep", "-f", "com.apple.WebKit"], capture_output=True, text=True).stdout.split()]:
    info = (ctypes.c_uint64 * 64)()
    if (pid == app or libc.responsibility_get_pid_responsible_for_pid(pid) == app) and libc.proc_pid_rusage(pid, 4, info) == 0:
        # rusage_info_v4: a 16-byte uuid, then user and system time in mach units, idle and interrupt wakeups.
        usage["app" if pid == app else str(pid)] = [(info[2] + info[3]) * timebase.numer / timebase.denom / 1e9, info[4] + info[5]]
print(json.dumps(usage))
PY
}

# Idle once the launch settled: the workers started for onStartup had time to finish, and the rule lists a new install
# compiles over minutes, resumed when a launch quits first, are done (Lilo under 5 % CPU for 10 s, waiting up to 10
# minutes). Through LaunchServices, so the WebKit processes are Lilo's responsibility and not the shell's.
open -n -g --env "${PROFILE[0]}" --env "${PROFILE[1]}" "$APP"
sleep 60
APP_PID=$(pgrep -nf "$APP/Contents/MacOS/Lilo")
kill -0 "$APP_PID" 2>/dev/null || { echo "Lilo exited during startup" >&2; exit 1; }
SETTLED=60
while [ "$SETTLED" -lt 600 ]; do
    BEFORE=$(usage)
    sleep 10
    SETTLED=$((SETTLED + 10))
    python3 -I -c 'import json, sys; a, b = (json.loads(x)["app"][0] for x in sys.argv[1:]); sys.exit((b - a) / 10 >= 0.05)' \
        "$BEFORE" "$(usage)" && break
done
echo "$SETTLED" > "$WORK/out/settled.txt"
usage > "$WORK/out/idle-start.json"
sleep "$IDLE"
usage > "$WORK/out/idle-end.json"
kill "$APP_PID"
wait "$APP_PID" 2>/dev/null || true
APP_PID=""

python3 -I - "$WORK/out" "$RUNS" "$IDLE" "$MAX_IDLE_CPU" <<'PY'
import json, os, re, statistics, sys
from datetime import datetime
out, runs, idle, budget = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]

def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))] if values else float("nan")

def spread(values, digits=1):
    return f"{pct(values, 50):.{digits}f} / {pct(values, 95):.{digits}f} / {max(values, default=0):.{digits}f} ({len(values)})"

def parse(i):
    """Intervals as (name, begin message, end message, ms, end time), and startup marks as (ms since launch, time)."""
    intervals, marks, begun = [], {}, {}
    for line in open(os.path.join(out, f"run-{i}.ndjson")):
        e = json.loads(line)
        t = datetime.strptime(e["timestamp"][:26], "%Y-%m-%d %H:%M:%S.%f").timestamp()
        mark = re.match(r"startup event=(\S+) total_ms=([\d.]+)", e["eventMessage"])
        if mark:
            marks.setdefault(mark.group(1), (float(mark.group(2)), t))
        elif e["signpostType"] == "begin":
            begun[(e["signpostName"], e["signpostID"])] = (e["eventMessage"], t)
        elif (e["signpostName"], e["signpostID"]) in begun:
            message, start = begun.pop((e["signpostName"], e["signpostID"]))
            intervals.append((e["signpostName"], message, e["eventMessage"], (t - start) * 1000, t))
    return intervals, marks

rows = {}
def row(name, value):
    rows[name] = value
    print(f"{name:58}{value}")

restored, workers_ready, stamped, gap, loading = [], [], [], {}, {"createExtension": [], "activate": []}
for i in range(1, runs + 1):
    intervals, marks = parse(i)
    launch = marks["main"][1] - marks["main"][0] / 1000
    restored.append(marks["extensionsRestored"][0])
    workers = [x for x in intervals if x[0] == "workerStart" and x[2] != "failed"]
    workers_ready.append(f"{(max((x[4] for x in workers), default=launch) - launch) * 1000:.0f} ({len(workers)})")
    prepare = [x for x in intervals if x[0] == "prepare"]
    if i == 1:
        print("== run 1: cold, every extension prepared and every worker started for the first time")
        row("prepare per extension, median / p95 / max ms (count)", spread([x[3] for x in prepare]))
        row("prepare, sum over extensions ms", f"{sum(x[3] for x in prepare):.0f}")
        row("slowest preparations", ", ".join(f"{x[1]} {x[3]:.0f} ms" for x in sorted(prepare, key=lambda x: -x[3])[:3]))
        row("worker start (load to connected), median / p95 / max ms", spread([x[3] for x in workers], 0))
        continue
    stamped += [x[3] for x in prepare]
    for name in loading:
        loading[name] += [x[3] for x in intervals if x[0] == name]
    for x in intervals:
        if x[0] == "gapCall":
            gap.setdefault(x[1], []).append(x[3])

print(f"\n== runs 2-{runs}: stamped")
row("prepare per extension, median / p95 / max ms (count)", spread(stamped, 2))
for name, values in loading.items():
    row(f"{name} per extension, median / p95 / max ms (count)", spread(values))
row("launch to extensions restored ms, run 1 then the others", " ".join(f"{ms:.0f}" for ms in restored))
row("launch to extensions restored ms, median of runs 2+", f"{statistics.median(restored[1:]):.0f}" if runs > 1 else "-")
row("launch to last worker connected ms (workers), per run", " ".join(workers_ready))

probe = {"tabs": [], "storage": []}
for i in range(2, runs + 1):
    for line in open(os.path.join(out, f"probe-{i}.txt")):
        for key, values in re.findall(r"(tabs|storage)=([\d.,]+)", line):
            probe[key] += [float(v) for v in values.split(",")]
# performance.now() in a worker ticks in whole milliseconds.
row("tabs.query from a worker, median / p95 / max ms (calls)", spread(probe["tabs"]))
row("storage.local.get from a worker, median / p95 / max ms (calls)", spread(probe["storage"]))
row("gap tabs.details in Lilo, median / p95 / max ms (calls)", spread(gap.get("tabs.details", []), 3))
row("every gap call in Lilo, median / p95 / max ms (calls)", spread([v for values in gap.values() for v in values], 3))

start, end = (json.load(open(os.path.join(out, f"idle-{name}.json"))) for name in ("start", "end"))
# A WebKit process started during the window counts from zero; one that ended in it is missed.
delta = {k: [v[0] - start.get(k, [0, 0])[0], v[1] - start.get(k, [0, 0])[1]] for k, v in end.items()}
webkit = [v for k, v in delta.items() if k != "app"]
app_cpu, webkit_cpu = delta["app"][0] / int(idle) * 100, sum(v[0] for v in webkit) / int(idle) * 100
print(f"\n== idle {idle} s, from {open(os.path.join(out, 'settled.txt')).read().strip()} s after a launch, once it settled")
row("Lilo CPU % / wakeups per s", f"{app_cpu:.1f} / {delta['app'][1] / int(idle):.0f}")
row("its WebKit processes CPU % / wakeups per s (processes)",
    f"{webkit_cpu:.1f} / {sum(v[1] for v in webkit) / int(idle):.0f} ({len(webkit)})")
over = []
if budget:
    app_max, webkit_max = (float(v) for v in budget.split(","))
    over = [f"{name} {cpu:.1f}% > {limit:g}%" for name, cpu, limit in (("Lilo", app_cpu, app_max), ("WebKit processes", webkit_cpu, webkit_max)) if cpu > limit]
    row("idle CPU budget, Lilo / WebKit processes %", f"{app_max:g} / {webkit_max:g}: {'over, ' + ', '.join(over) if over else 'ok'}")
json.dump(rows, open(os.path.join(out, "summary.json"), "w"), indent=1)
sys.exit(1 if over else 0)
PY

