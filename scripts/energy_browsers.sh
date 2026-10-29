#!/bin/bash
# Median energy impact, CPU, wakeups and power of Lilo, Safari, Chrome and Firefox on the same local pages. Usage:
# energy_browsers.sh [--no-build] [--app PATH] [--browsers "lilo safari chrome firefox"] [--rounds N=3]
# [--duration SECONDS=60] [--settle SECONDS=30] [--out DIR=build/energy-browsers]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.derived.noindex/bench"
APP="$DERIVED/Build/Products/Release/Lilo.app"
BUILD=true
BROWSERS="lilo safari chrome firefox"
ROUNDS=3
DURATION=60
SETTLE=30
OUT="$ROOT/build/energy-browsers"
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=false ;;
        --app) APP="$2"; BUILD=false; shift ;;
        --browsers) BROWSERS="$2"; shift ;;
        --rounds) ROUNDS="$2"; shift ;;
        --duration) DURATION="$2"; shift ;;
        --settle) SETTLE="$2"; shift ;;
        --out) OUT="$2"; [[ $OUT = /* ]] || OUT="$PWD/$OUT"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

CHROME="/Applications/Google Chrome.app"
FIREFOX="/Applications/Firefox.app"
SELECTED=""
for b in $BROWSERS; do
    case "$b" in
        chrome) [ -d "$CHROME" ] || { echo "Chrome is not installed: skipped" >&2; continue; } ;;
        firefox) [ -d "$FIREFOX" ] || { echo "Firefox is not installed: skipped" >&2; continue; } ;;
        safari)
            # Safari has a single instance on the real profile: the run replaces its last session.
            if pgrep -xq Safari; then echo "Quit Safari first (its session is replaced by the run's windows)" >&2; exit 1; fi ;;
        lilo) ;;
        *) echo "unknown browser: $b" >&2; exit 2 ;;
    esac
    SELECTED+="$b "
done
[ -n "$SELECTED" ] || { echo "no browser to measure" >&2; exit 1; }

# WebKit renders nothing on a locked screen.
if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    echo "The screen is locked: unlock it to run the benchmark." >&2
    exit 1
fi

if $BUILD && [[ $SELECTED == *lilo* ]]; then
    make -C "$ROOT" vt-build ui-build >/dev/null
    # Ad-hoc signed: library validation would reject the embedded Sparkle.framework under the hardened runtime.
    xcodebuild -project "$ROOT/Lilo.xcodeproj" -scheme Lilo -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build >/dev/null
fi

# powermetrics needs root; the browsers run as the user.
sudo -v
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lilo-energy-browsers.XXXXXX")"
SERVER_PID=""
BROWSER_PID=""
KEEPALIVE_PID=""
cleanup() {
    [ -z "$BROWSER_PID" ] || kill "$BROWSER_PID" 2>/dev/null || true
    [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
    [ -z "$KEEPALIVE_PID" ] || kill "$KEEPALIVE_PID" 2>/dev/null || true
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT
while sudo -n true 2>/dev/null; do sleep 50; done &
KEEPALIVE_PID=$!
disown "$KEEPALIVE_PID"
# Display sleep would lock the screen mid-run, and system sleep would stop it.
caffeinate -dimsu -w $$ &
mkdir -p "$WORK/site" "$WORK/profiles" "$OUT"

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID"
BASE_URL="http://127.0.0.1:$PORT"

# idle: five static pages. active: a visible page with a CSS animation and a 1 s clock, and four background tabs
# whose 250 ms timers touch the DOM, as analytics and carousels do.
ARTICLE='<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.</p>'
page() { # file title body
    printf '<!doctype html><meta charset="utf-8"><title>%s</title><style>body{font:16px/1.5 -apple-system,sans-serif;max-width:40em;margin:3em auto}</style><h1>%s</h1>%s%s%s%s\n' \
        "$2" "$2" "$ARTICLE" "$ARTICLE" "$3" "$ARTICLE" > "$WORK/site/$1"
}
page visible-idle.html Visible ""
page visible-active.html Visible '<div style="width:96px;height:96px;margin:2em auto;border-radius:24px;background:#5b8def;animation:spin 2s linear infinite"></div><p id="clock"></p><style>@keyframes spin{to{transform:rotate(360deg)}}</style><script>setInterval(()=>{clock.textContent=new Date().toLocaleTimeString()},1000)</script>'
for i in 1 2 3 4; do
    page "background-idle-$i.html" "Background $i" ""
    page "background-active-$i.html" "Background $i" '<p id="n">0</p><script>let k=0;setInterval(()=>{n.textContent=++k},250)</script>'
done
urls() { # scenario
    echo "$BASE_URL/visible-$1.html"
    for i in 1 2 3 4; do echo "$BASE_URL/background-$1-$i.html"; done
}

new_pid() { # process name, pids before the launch
    for _ in $(seq 1 200); do
        for p in $(pgrep -x "$1" || true); do
            [[ " $2 " == *" $p "* ]] || { echo "$p"; return; }
        done
        sleep 0.1
    done
    echo "$1 did not start" >&2
    exit 1
}

# Launches a browser on its profile in $WORK/run with the given URLs (first one visible) and sets BROWSER_PID.
launch() { # browser, urls...
    local browser="$1" before
    shift
    case "$browser" in
        lilo)
            before="$(pgrep -x Lilo | tr '\n' ' ' || true)"
            # Lilo opens each handed-over page in a new foreground tab: the visible page goes last.
            local seed
            seed="$(printf '%s\n' "${@:2}" "$1")"
            open -n --env CFFIXED_USER_HOME="$WORK/run" --env LILO_APP_SUPPORT_DIR="$WORK/run/support" \
                --env LILO_BENCH_SEED_URLS="$seed" "$APP"
            BROWSER_PID="$(new_pid Lilo "$before")" ;;
        chrome)
            before="$(pgrep -x "Google Chrome" | tr '\n' ' ' || true)"
            open -n -a "$CHROME" --args --user-data-dir="$WORK/run" --no-first-run --no-default-browser-check "$@"
            BROWSER_PID="$(new_pid "Google Chrome" "$before")" ;;
        firefox)
            before="$(pgrep -x firefox | tr '\n' ' ' || true)"
            open -n -a "$FIREFOX" --args -profile "$WORK/run" -no-remote "$@"
            BROWSER_PID="$(new_pid firefox "$before")" ;;
        safari)
            open -a Safari
            BROWSER_PID="$(new_pid Safari "")"
            local script='tell application "Safari"
                close every window
                make new document with properties {URL:"'"$1"'"}'
            for u in "${@:2}"; do script+=$'\n'"tell window 1 to make new tab at end of tabs with properties {URL:\"$u\"}"; done
            script+=$'\n''set current tab of window 1 to tab 1 of window 1
            end tell'
            osascript -e "$script" >/dev/null ;;
    esac
}

quit_browser() {
    if [ "$1" = safari ]; then
        osascript -e 'tell application "Safari" to close every window' -e 'tell application "Safari" to quit' >/dev/null
    else
        kill "$BROWSER_PID" 2>/dev/null || true
    fi
    for _ in $(seq 1 150); do kill -0 "$BROWSER_PID" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$BROWSER_PID" 2>/dev/null || true
    BROWSER_PID=""
    sleep 5
}

# A first launch per browser creates its profile and lets it finish first-run work (components, filter lists),
# then every run starts from a copy of that profile.
for b in $SELECTED; do
    [ "$b" != safari ] || continue
    /bin/rm -rf "$WORK/run"
    mkdir -p "$WORK/run"
    if [ "$b" = firefox ]; then
        printf 'user_pref("%s", %s);\n' browser.shell.checkDefaultBrowser false browser.aboutwelcome.enabled false \
            browser.startup.homepage_override.mstone '"ignore"' datareporting.policy.dataSubmissionPolicyBypassNotification true \
            toolkit.telemetry.reportingpolicy.firstRun false browser.tabs.warnOnClose false > "$WORK/run/user.js"
    fi
    echo "Preparing the $b profile" >&2
    launch "$b" "$BASE_URL/visible-idle.html"
    sleep 60
    quit_browser "$b"
    [ "$b" != lilo ] || sqlite3 "$WORK/run/support/global.db" "UPDATE settings SET value = 'true' WHERE key = 'onboardingCompleted'"
    /bin/mv -f "$WORK/run" "$WORK/profiles/$b"
done

RUNS="$OUT/runs.tsv"
printf 'round\tscenario\tbrowser\tenergy_impact\tcpu_pct\tidle_wakeups_s\tsystem_power_mw\tprocesses\tfrontmost\tprocess_names\n' > "$RUNS"
sample() { # round scenario browser
    sudo /usr/bin/powermetrics --samplers tasks,cpu_power --show-process-coalition --show-process-energy \
        -i 1000 -n "$DURATION" -f plist -o "$WORK/sample.plist" >/dev/null 2>&1
    python3 - "$WORK/sample.plist" "${BROWSER_PID:-0}" "$1" "$2" "$3" "${4:-}" "${5:-}" >> "$RUNS" <<'PY'
import sys, plistlib, statistics
path, pid, rnd, scenario, browser, front_start, front_end = sys.argv[1], int(sys.argv[2]), *sys.argv[3:]
energy, cpu, wakeups, power, pids, names = [], [], [], [], set(), set()
for chunk in open(path, "rb").read().split(b"\0"):
    chunk = chunk.strip()
    if not chunk:
        continue
    try:
        s = plistlib.loads(chunk)
    except Exception:
        continue
    p = s.get("processor", {})
    power.append(p.get("combined_power") or p.get("cpu_power", 0) + p.get("gpu_power", 0))
    if not pid:
        continue
    # The browser's coalition holds its helpers and the WebKit or Chromium processes it started.
    tasks = next((c.get("tasks") or [] for c in s.get("coalitions") or [] if any(t.get("pid") == pid for t in c.get("tasks") or [])), [])
    pids |= {t.get("pid") for t in tasks}
    names |= {t.get("name") for t in tasks}
    energy.append(sum(t.get("energy_impact_per_s", t.get("energy_impact", 0)) for t in tasks))
    cpu.append(sum(t.get("cputime_ms_per_s", 0) for t in tasks) / 10)
    wakeups.append(sum(t.get("idle_wakeups_per_s", 0) for t in tasks))
if not power:
    sys.exit(f"powermetrics: no sample in {path}")
if pid and not pids:
    sys.exit(f"powermetrics: no coalition holds pid {pid}")
mean = lambda v: statistics.fmean(v) if v else 0
front = "yes" if front_start == front_end == "yes" else "no" if pid else ""
print(f"{rnd}\t{scenario}\t{browser}\t{mean(energy):.2f}\t{mean(cpu):.2f}\t{mean(wakeups):.1f}\t{mean(power):.0f}\t{len(pids)}\t{front}\t{','.join(sorted(names))}")
PY
    /bin/rm -f "$WORK/sample.plist"
}

is_frontmost() {
    [ "$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)" = "$BROWSER_PID" ] \
        && echo yes || echo no
}

# Hidden or occluded pages stop drawing, so each sample needs the browser in front.
bring_to_front() {
    for _ in 1 2 3 4 5; do
        osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $BROWSER_PID) to true" >/dev/null 2>&1 || true
        sleep 1
        [ "$(is_frontmost)" = no ] || return 0
    done
    echo "warning: the $1 window could not be brought to the front" >&2
}

for round in $(seq 1 "$ROUNDS"); do
    echo "Round $round: baseline" >&2
    sample "$round" baseline none
    for scenario in idle active; do
        # Rotated each round so drift over the run hits every browser alike.
        # shellcheck disable=SC2086
        order="$(echo $SELECTED | tr ' ' '\n' | awk -v r="$round" '{a[NR]=$0} END {for (i = 0; i < NR; i++) print a[(i + r - 1) % NR + 1]}')"
        for b in $order; do
            echo "Round $round: $scenario, $b" >&2
            /bin/rm -rf "$WORK/run"
            [ "$b" = safari ] || /bin/cp -Rf "$WORK/profiles/$b" "$WORK/run"
            # shellcheck disable=SC2046
            launch "$b" $(urls "$scenario")
            sleep 5
            bring_to_front "$b"
            sleep "$SETTLE"
            bring_to_front "$b"
            front="$(is_frontmost)"
            sample "$round" "$scenario" "$b" "$front" "$(is_frontmost)"
            quit_browser "$b"
        done
    done
done

python3 - "$RUNS" > "$OUT/summary.tsv" <<'PY'
import sys, csv, statistics, collections
rows = list(csv.DictReader(open(sys.argv[1]), delimiter="\t"))
base = statistics.median(float(r["system_power_mw"]) for r in rows if r["scenario"] == "baseline")
groups = collections.defaultdict(list)
for r in rows:
    if r["scenario"] != "baseline":
        groups[(r["scenario"], r["browser"])].append(r)
print(f"# medians of {len(rows)} runs; baseline system power {base:.0f} mW")
print("scenario\tbrowser\tenergy_impact\tcpu_pct\tidle_wakeups_s\tpower_above_baseline_mw\tprocesses")
for (scenario, browser), rs in groups.items():
    m = lambda k: statistics.median(float(r[k]) for r in rs)
    print(f"{scenario}\t{browser}\t{m('energy_impact'):.2f}\t{m('cpu_pct'):.2f}\t{m('idle_wakeups_s'):.1f}\t{m('system_power_mw') - base:.0f}\t{m('processes'):.0f}")
PY
column -t -s $'\t' "$OUT/summary.tsv"
awk -F'\t' 'NR > 1 && $2 != "baseline" && $9 != "yes" {print "warning: round " $1 " " $2 " " $3 ": the browser was not frontmost for the whole sample"}' "$RUNS" >&2
echo "Runs: $RUNS, summary: $OUT/summary.tsv" >&2
