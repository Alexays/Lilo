#!/bin/bash
# Median startup marks of a Release Lilo on a throwaway home, onboarding pending then completed. Usage:
# bench_startup.sh [runs=10] [--no-build] [--app PATH] [--tabs N] [--url URL] [--all] [--out DIR] [--variant NAME:[app=PATH] [VAR=value]...]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.derived.noindex/bench"
APP="$DERIVED/Build/Products/Release/Lilo.app"
RUNS=10
BUILD=true
TABS=0
URL=""
ALL=false
KEEP=""
VARIANTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=false ;;
        --app) APP="$2"; BUILD=false; shift ;;
        --tabs) TABS="$2"; shift ;;
        --url) URL="$2"; shift ;;
        --all) ALL=true ;;
        --out) KEEP="$2"; [[ $KEEP = /* ]] || KEEP="$PWD/$KEEP"; shift ;;
        --variant) VARIANTS+=("$2"); shift ;;
        *) RUNS="$1" ;;
    esac
    shift
done
[ ${#VARIANTS[@]} -gt 0 ] || VARIANTS=("default:")

# WebKit renders nothing on a locked screen, so the chrome never reports its first paint.
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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lilo-bench.XXXXXX")"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; [ -z "$KEEP" ] || { mkdir -p "$KEEP" && /bin/cp -f "$WORK"/out/*.json "$KEEP"/ 2>/dev/null || true; }; /bin/rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/out" "$WORK/site"

# CFFIXED_USER_HOME moves preferences, caches and WebKit data under the throwaway home, and
# LILO_APP_SUPPORT_DIR the database: the real profile is never read or written.
launch() {
    local out="$1" app="$APP" vars=()
    for token in $2; do
        case "$token" in
            app=*) app="${token#app=}" ;;
            *) vars+=("$token") ;;
        esac
    done
    /bin/rm -f "$out"
    env CFFIXED_USER_HOME="$WORK/home" LILO_APP_SUPPORT_DIR="$WORK/home/support" \
        LILO_STARTUP_BENCH_OUT="$out" ${vars[@]+"${vars[@]}"} "$app/Contents/MacOS/Lilo" >/dev/null 2>&1 &
    local pid=$!
    for _ in $(seq 1 600); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; echo "launch timed out" >&2; exit 1; fi
    [ -s "$out" ] || { echo "launch wrote no metrics" >&2; exit 1; }
}

run_scenario() {
    local scenario="$1"
    for i in $(seq 1 "$RUNS"); do
        # Interleaved so machine noise hits every variant alike.
        for variant in "${VARIANTS[@]}"; do
            launch "$WORK/out/$scenario.${variant%%:*}.$i.json" "${variant#*:}"
        done
    done
}

# First launch creates the database and profile; it is a fresh-install path, not the one measured.
# Served over HTTP, not file://: a file load skips the network process a real page goes through.
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID"
SEED_URLS=""
for i in $(seq 1 "$TABS"); do
    printf '<!doctype html><meta charset="utf-8"><title>Bench %s</title><style>body{font:16px system-ui;margin:40px}</style><h1>Page %s</h1><p>%s</p>' \
        "$i" "$i" "$(printf 'Lorem ipsum dolor sit amet. %.0s' $(seq 1 200))" > "$WORK/site/page-$i.html"
    SEED_URLS+="http://127.0.0.1:$PORT/page-$i.html"$'\n'
done
[ -z "$URL" ] || SEED_URLS+="$URL"$'\n'
# It lingers so the filter lists download and compile into WebKit's cache, as they would in normal
# use; quit sooner, every measured launch would recompile them on the main thread.
LILO_BENCH_SEED_URLS="$SEED_URLS" LILO_STARTUP_BENCH_LINGER=25 launch "$WORK/out/seed.json" ""
run_scenario onboarding
sqlite3 "$WORK/home/support/global.db" "UPDATE settings SET value = 'true' WHERE key = 'onboardingCompleted'"
run_scenario returning

python3 - "$WORK/out" "$RUNS" "$ALL" "${VARIANTS[@]%%:*}" <<'PY'
import json, statistics, sys, os
out, runs, show_all, variants = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "true", sys.argv[4:]
HEADLINE = ["main", "chromePreloadIssued", "windowShown", "restoreSessionActiveContextReady",
            "chromeServed:index.js", "chromeInitialStateReceived", "chromeVisualReady",
            "onboardingVisible", "firstContentPainted", "firstContentFinished"]

def medians(scenario, variant):
    series, order = {}, []
    for i in range(1, runs + 1):
        seen = set()
        for m in json.load(open(os.path.join(out, f"{scenario}.{variant}.{i}.json")))["marks"]:
            e = m["event"]
            if e in seen:
                continue
            seen.add(e)
            if e not in series:
                series[e] = []
                order.append(e)
            series[e].append(m["totalMilliseconds"])
    return {e: statistics.median(v) for e, v in series.items()}, {e: (min(v), max(v)) for e, v in series.items()}

for scenario in ("onboarding", "returning"):
    results = {v: medians(scenario, v) for v in variants}
    events = sorted({e for med, _ in results.values() for e in med}, key=lambda e: statistics.median(
        [med[e] for med, _ in results.values() if e in med]))
    if not show_all:
        events = [e for e in events if e in HEADLINE]
    print(f"\n== {scenario} ({runs} launches per variant, median ms)")
    print(f"{'mark':40}" + "".join(f"{v:>14}" for v in variants))
    for e in events:
        print(f"{e:40}" + "".join(f"{results[v][0][e]:14.1f}" if e in results[v][0] else f"{'-':>14}" for v in variants))
PY
