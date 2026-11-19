#!/bin/bash
# shellcheck disable=SC2016 # the stubs expand their variables when they run, not when written
# Tests scripts/bootstrap.sh with stubbed tools: every check runs before the first install, and the
# exit codes and the JSON tell a missing tool from an action only a person can take.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/lilo-bootstrap.XXXXXX")
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/root/scripts" "$T/bin" "$T/root/lilo-ui" "$T/root/site" "$T/root/docs-site" "$T/root/release-media" "$T/root/Lilo/Extensions/bridge-src"
cp "$ROOT/scripts/bootstrap.sh" "$T/root/scripts/"
for pkg in lilo-ui:22.8 site:22.23.4 docs-site:22.23.4 Lilo/Extensions/bridge-src:22.6; do
    printf '{"engines": {"node": ">=%s"}}\n' "${pkg#*:}" > "$T/root/${pkg%%:*}/package.json"
done
echo '{}' > "$T/root/release-media/package.json"

stub() { printf '#!/bin/sh\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
stub sw_vers 'echo "${STUB_MACOS:-26.6}"'
stub xcodebuild 'echo "${STUB_XCODE:-Xcode 27.2}"'
stub xcode-select 'echo /Applications/Xcode.app'
stub xcrun '[ "${STUB_METAL:-1}" = 1 ]'
stub DevToolsSecurity 'echo "Developer mode is currently ${STUB_DEV:-enabled}."'
stub node 'echo "${STUB_NODE:-v24.0.0}"'
stub curl '[ "${STUB_CURL:-1}" = 1 ]'
stub zig 'echo 0.16.0'
stub make 'echo "MAKE-NOISE"; echo "$*" >> "$STUB_LOG"'
export STUB_LOG="$T/make.log"
# bash keeps a real uname out of the way; df, sed and the rest come from the system.
export PATH="$T/bin:/usr/bin:/bin" LILO_BOOTSTRAP_DISK_GB=1 VT_URL=https://example.com/vt.zip GHOSTTY_SHA=abc VT_STAMP=$T/none
export LILO_UNAME=Darwin

fail() { echo "FAIL: $*" >&2; sed 's/^/  | /' "$T/out" "$T/err" >&2; exit 1; }
# run <expected-exit> <env assignments...> -- <bootstrap args...>
run() {
    local expected=$1 actual=0; shift
    : > "$STUB_LOG"
    local envs=()
    while [ "$1" != -- ]; do envs+=("$1"); shift; done
    shift
    env ${envs[@]+"${envs[@]}"} "$T/root/scripts/bootstrap.sh" "$@" > "$T/out" 2> "$T/err" || actual=$?
    [ "$actual" = "$expected" ] || fail "expected exit $expected, got $actual: ${envs[*]-} $*"
}
makes() { wc -l < "$STUB_LOG" | tr -d ' '; }
expect_makes() { [ "$(makes)" = "$1" ] || fail "expected $1 make calls, got $(makes)"; }
contains() { cat "$T/out" "$T/err" | grep -qF -- "$1" || fail "output lacks: $1"; }

# Every check passes: the dependencies, then the build targets.
run 0 -- "deps" "build" "sites"
expect_makes 2
[ "$(sed -n 1p "$STUB_LOG")" = "-s --no-print-directory deps" ] || fail "dependencies are not installed first"
contains "Ready. Next:"

# Checks run before any install: a broken Metal toolchain installs nothing and needs a person.
run 3 STUB_METAL=0 -- "deps" "build" "sites"
expect_makes 0
contains "Nothing was installed"
contains "MetalToolchain"

run 3 STUB_DEV=disabled -- "deps" "build" "sites"
expect_makes 0
contains "sudo DevToolsSecurity -enable"

run 3 STUB_XCODE=Xcode\ 26.0 -- "deps" "build" "sites"
expect_makes 0

run 3 STUB_MACOS=15.1 -- "deps" "build" "sites"
expect_makes 0

run 3 LILO_BOOTSTRAP_DISK_GB=999999999 -- "deps" "build" "sites"
expect_makes 0
contains "free some disk space"

# A missing tool is exit 2; a person's action outranks it.
run 2 STUB_NODE=v20.0.0 -- "deps" "build" "sites"
expect_makes 0
run 3 STUB_NODE=v20.0.0 STUB_METAL=0 -- "deps" "build" "sites"

# The Node.js floor is the highest engines field of all the packages, the bridge included.
printf '{"engines": {"node": ">=99.1"}}\n' > "$T/root/Lilo/Extensions/bridge-src/package.json"
run 2 -- "deps" "build" "sites"
contains "Node.js 99.1 or later"
printf '{"engines": {"node": ">=22.6"}}\n' > "$T/root/Lilo/Extensions/bridge-src/package.json"

# Zig is required only when libghostty-vt cannot be downloaded or VT_FROM_SOURCE asks for it.
run 0 STUB_CURL=0 -- "deps" "build" "sites"
rm "$T/bin/zig"
run 2 STUB_CURL=0 -- "deps" "build" "sites"
expect_makes 0
contains "brew install zig"
run 2 VT_FROM_SOURCE=1 -- "deps" "build" "sites"
run 0 -- "deps" "build" "sites"
echo abc > "$T/vt-stamp"
run 0 STUB_CURL=0 VT_STAMP="$T/vt-stamp" -- "deps" "build" "sites"
stub zig 'echo 0.16.0'

# --with-sites installs the site tools between the dependencies and the build.
run 0 -- --with-sites "deps" "build" "sites"
[ "$(sed -n 2p "$STUB_LOG")" = "-s --no-print-directory sites" ] || fail "--with-sites did not install the site tools"
expect_makes 3
run 0 -- "deps" "build" "sites"
expect_makes 2

# --json keeps stdout to one object, status per check, and make's own output off it.
run 3 STUB_METAL=0 -- --json "deps" "build" "sites"
python3 -I - "$T/out" <<'PY' || fail "JSON for a broken environment"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ready"] is False and d["exit"] == 3 and d["installed"] is False
status = {c["id"]: c["status"] for c in d["checks"]}
assert status["metal"] == "human" and status["node"] == "ok", status
PY
run 0 -- --json --with-sites "deps" "build" "sites"
python3 -I - "$T/out" <<'PY' || fail "JSON for a ready environment"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ready"] is True and d["installed"] is True and d["with_sites"] is True
PY
run 2 STUB_NODE=v20.0.0 -- --json "deps" "build" "sites"
python3 -I -c 'import json,sys; assert json.load(open(sys.argv[1]))["exit"] == 2' "$T/out" || fail "JSON exit code"

# Linux installs the JavaScript lane only, with no Apple checks, and says what runs there.
rm "$T/bin/xcodebuild" "$T/bin/sw_vers"
run 0 LILO_UNAME=Linux -- "deps" "build" "sites"
expect_makes 1
contains "make ui-lint"
contains "need macOS"

run 64 -- --nope
echo "bootstrap.test.sh: ok"
