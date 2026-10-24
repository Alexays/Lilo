#!/bin/bash
# Fails when an idle Release Lilo (restored tabs, hidden terminal) runs git, wakes extension workers or saves terminal
# snapshots. Usage: energy_idle_check.sh [--no-build] [--tabs N=3] [--idle SECONDS=45] [--no-terminal]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.derived.noindex/bench"
APP="$DERIVED/Build/Products/Release/Lilo.app"
BUILD=true
TABS=3
IDLE=45
TERMINAL=true
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) BUILD=false ;;
        --tabs) TABS="$2"; shift ;;
        --idle) IDLE="$2"; shift ;;
        --no-terminal) TERMINAL=false ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

if ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked | grep -q '<true/>'; then
    echo "The screen is locked: unlock it to run the idle check." >&2
    exit 1
fi

if $BUILD; then
    make -C "$ROOT" vt-build ui-build >/dev/null
    # Ad-hoc signed: library validation would reject the embedded Sparkle.framework under the hardened runtime.
    xcodebuild -project "$ROOT/Lilo.xcodeproj" -scheme Lilo -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
        CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build >/dev/null
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lilo-energy-idle.XXXXXX")"
SERVER_PID=""
APP_PID=""
trap '[ -z "$APP_PID" ] || kill "$APP_PID" 2>/dev/null || true; [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true; /bin/rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/site"
# CFFIXED_USER_HOME moves preferences, caches and WebKit data under the throwaway home, and
# LILO_APP_SUPPORT_DIR the database: the real profile is never read or written.
PROFILE=(CFFIXED_USER_HOME="$WORK/home" LILO_APP_SUPPORT_DIR="$WORK/home/support")

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/site" >/dev/null 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID"
SEED_URLS=""
for i in $(seq 1 "$TABS"); do
    printf '<!doctype html><meta charset="utf-8"><title>Idle %s</title><h1>Page %s</h1>' "$i" "$i" > "$WORK/site/page-$i.html"
    SEED_URLS+="http://127.0.0.1:$PORT/page-$i.html"$'\n'
done

# A first launch creates the profile, opens the pages and lets the filter lists compile, then quits.
env "${PROFILE[@]}" LILO_BENCH_SEED_URLS="$SEED_URLS" LILO_STARTUP_BENCH_OUT="$WORK/seed.json" \
    LILO_STARTUP_BENCH_LINGER=25 "$APP/Contents/MacOS/Lilo" >/dev/null 2>&1 &
SEED_PID=$!
for _ in $(seq 1 600); do
    kill -0 "$SEED_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$SEED_PID" 2>/dev/null; then kill "$SEED_PID"; echo "seed launch timed out" >&2; exit 1; fi
sqlite3 "$WORK/home/support/global.db" "UPDATE settings SET value = 'true' WHERE key = 'onboardingCompleted'"

env "${PROFILE[@]}" "$APP/Contents/MacOS/Lilo" >/dev/null 2>&1 &
APP_PID=$!
sleep 10
kill -0 "$APP_PID" 2>/dev/null || { echo "Lilo exited during startup" >&2; exit 1; }

if $TERMINAL; then
    # Ctrl+` opens a terminal tab and starts its shell; Cmd+1 then hides it behind the first page.
    osascript -e "tell application \"System Events\"
        set frontmost of (first process whose unix id is $APP_PID) to true
        delay 1
        key code 50 using control down
        delay 3
        key code 18 using command down
    end tell" >/dev/null || { echo "System Events refused the keystrokes: grant Accessibility access to this terminal, or pass --no-terminal" >&2; exit 1; }
    # A hidden terminal is saved once, on the second 30 s housekeeping pass after its output settles.
    SETTLE=90
else
    SETTLE=20
fi
sleep "$SETTLE"

START="$(date '+%Y-%m-%d %H:%M:%S')"
echo "Idle for ${IDLE}s from $START (pid $APP_PID)"
sleep "$IDLE"
END="$(date '+%Y-%m-%d %H:%M:%S')"
kill -0 "$APP_PID" 2>/dev/null || { echo "Lilo exited during the idle window" >&2; exit 1; }

/usr/bin/log show --signpost --style ndjson --start "$START" --end "$END" \
    --predicate "subsystem == \"fr.arouillard.lilo\" AND category == \"energy\" AND processIdentifier == $APP_PID" \
    | jq -c 'select(.eventType == "signpostEvent")' > "$WORK/energy.ndjson"

echo "Energy signposts while idle:"
jq -r 'select(.signpostType != "end") | .signpostName' "$WORK/energy.ndjson" | sort | uniq -c
OFFENDERS="$(jq -r 'select((.signpostName == "git" or .signpostName == "workerWake") and .signpostType != "end"
    or .signpostName == "saveSnapshots" and .signpostType == "end" and (.eventMessage | startswith("0 ") | not))
    | "\(.timestamp) \(.signpostName) \(.eventMessage)"' "$WORK/energy.ndjson")"
if [ -n "$OFFENDERS" ]; then
    echo "Idle work found:" >&2
    echo "$OFFENDERS" >&2
    exit 1
fi
echo "No git runs, worker wakes or snapshot saves while idle."
