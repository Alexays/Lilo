#!/bin/bash
# make bootstrap: checks everything building Lilo needs, and only then installs anything.
# Usage: bootstrap.sh [--with-sites] [--json] <deps-targets> <build-targets> [<site-targets>]
#   deps-targets   make targets installing the npm dependencies of the interface and the bridge
#   build-targets  make targets building the rest (libghostty-vt, bundles, SwiftLint, XcodeGen)
#   site-targets   make targets installing the website, docs and Changie tools, run with --with-sites
# Exit codes: 0 ready; 1 a make step failed; 2 a tool is missing and installs without an account
# (Node.js, Zig); 3 a person must act (sudo, an Apple ID download, a system update, free disk);
# 64 usage. 3 wins over 2. Nothing is installed unless every check passed.
# Environment: LILO_BOOTSTRAP_DISK_GB (free space needed, default 5), VT_URL, VT_STAMP,
# GHOSTTY_SHA, VT_FROM_SOURCE (set by the Makefile), LILO_UNAME (tests).
cd "$(dirname "$0")/.." || exit 1

with_sites=0
json=0
while [[ ${1:-} == --* ]]; do
    case $1 in
        --with-sites) with_sites=1 ;;
        --json) json=1 ;;
        *) echo "bootstrap.sh: unknown option $1" >&2; exit 64 ;;
    esac
    shift
done
deps_targets=${1:-}
build_targets=${2:-}
site_targets=${3:-}

# say prints to the terminal; in JSON mode stdout carries only the final object.
say() { [ "$json" = 1 ] || echo "$@"; }

ids=() states=() messages=() fixes=()
worst=0 # 0 ok, 2 missing tool, 3 human action
# check <id> <ok|missing|human|skipped> <message> [fix]
check() {
    ids+=("$1"); states+=("$2"); messages+=("$3"); fixes+=("${4:-}")
    case $2 in
        ok) say "  ok  $3" ;;
        missing) [ "$worst" -ge 2 ] || worst=2 ;;
        human) worst=3 ;;
    esac
}

json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\t' '  ')"; }

emit_json() { # <exit> <installed true|false>
    local i sep=""
    printf '{"ready":%s,"exit":%s,"installed":%s,"with_sites":%s,"checks":[' \
        "$([ "$1" = 0 ] && echo true || echo false)" "$1" "$2" "$([ "$with_sites" = 1 ] && echo true || echo false)"
    for i in "${!ids[@]}"; do
        printf '%s{"id":%s,"status":"%s","message":%s,"fix":%s}' "$sep" "$(json_str "${ids[$i]}")" "${states[$i]}" \
            "$(json_str "${messages[$i]}")" "$(json_str "${fixes[$i]}")"
        sep=,
    done
    printf ']}\n'
}

run_make() { # build output never mixes into the JSON on stdout
    if [ "$json" = 1 ]; then make -s --no-print-directory "$@" >&2; else make -s --no-print-directory "$@"; fi
}

say "Checking the prerequisites"
os=${LILO_UNAME:-$(uname -s)}

if [ "$os" = Darwin ]; then
    macos=$(sw_vers -productVersion 2>/dev/null || echo none)
    if [ "${macos%%.*}" -ge 26 ] 2>/dev/null; then
        check macos ok "macOS $macos"
    else
        check macos human "macOS 26 or later (found: $macos)" "update it in System Settings > General > Software Update"
    fi

    xcode=$(xcodebuild -version 2>/dev/null | head -1)
    if [[ $xcode == "Xcode 27"* ]]; then
        check xcode ok "$xcode ($(xcode-select -p))"
        # Xcode 26 and later download the Metal compiler separately; the terminal's shaders need it.
        if xcrun metal --version >/dev/null 2>&1; then
            check metal ok "Metal toolchain"
        else
            check metal human "the Metal toolchain is not installed" \
                "xcodebuild -downloadComponent MetalToolchain (an Apple ID download of a few GB, about 10 minutes)"
        fi
    else
        check xcode human "Xcode 27 selected (found: ${xcode:-none at $(xcode-select -p 2>/dev/null || echo '?')})" \
            "install it from https://developer.apple.com/xcode/, open it once, then: sudo xcode-select -s /Applications/Xcode.app"
    fi

    # Without it, xcodebuild fails to launch the test host with "INTERNAL ERROR: childPID > 0" once its cached
    # authorization expires: tens of minutes into make validate.
    if command -v DevToolsSecurity >/dev/null 2>&1; then
        if DevToolsSecurity -status 2>&1 | grep -qi 'enabled'; then
            check devtools ok "Developer mode (DevToolsSecurity)"
        else
            check devtools human "Developer mode is disabled: the Swift tests cannot launch their host" "sudo DevToolsSecurity -enable"
        fi
    fi
fi

# The highest engines field of the five packages, not .nvmrc's major: make validate checks the sites too.
wanted_node=$(sed -n 's/.*"node": *">=\([0-9.]*\)".*/\1/p' lilo-ui/package.json Lilo/Extensions/bridge-src/package.json \
    site/package.json docs-site/package.json release-media/package.json 2>/dev/null | sort -V | tail -1)
node_version=$(node -v 2>/dev/null)
if [ -n "$node_version" ] && [ "$(printf '%s\n' "$wanted_node" "${node_version#v}" | sort -V | head -1)" = "$wanted_node" ]; then
    check node ok "Node.js $node_version"
else
    check node missing "Node.js $wanted_node or later, as the packages require (found: ${node_version:-none})" \
        "install it with nvm (nvm install, which reads .nvmrc), fnm, mise, or from https://nodejs.org"
fi

need_gb=${LILO_BOOTSTRAP_DISK_GB:-5}
free_gb=$(df -k . 2>/dev/null | awk 'NR == 2 { print int($4 / 1048576) }')
if [ "${free_gb:-0}" -ge "$need_gb" ] 2>/dev/null; then
    check disk ok "${free_gb} GB free (needs $need_gb: about 2.3 GB per worktree, then the build)"
else
    check disk human "${free_gb:-unknown} GB free, $need_gb needed (about 2.3 GB per worktree, then the build)" \
        "free some disk space, for example old worktrees and Xcode DerivedData"
fi

# libghostty-vt is downloaded prebuilt; only when that is impossible does the build need Zig.
if [ "$os" = Darwin ] && [ "$(cat "${VT_STAMP:-Vendor/.ghostty-sha}" 2>/dev/null)" != "${GHOSTTY_SHA:-}" ]; then
    if [ "${VT_FROM_SOURCE:-}" = 1 ]; then
        vt_source="VT_FROM_SOURCE=1 builds libghostty-vt from source"
    elif [ -z "${VT_URL:-}" ] || ! curl -fsSI --max-time 8 "$VT_URL" >/dev/null 2>&1; then
        vt_source="the prebuilt libghostty-vt is unreachable, so it is built from source"
    fi
    if [ -n "${vt_source:-}" ]; then
        if command -v zig >/dev/null 2>&1; then
            check zig ok "Zig $(zig version 2>/dev/null) ($vt_source)"
        else
            check zig missing "Zig 0.16.x: $vt_source" "brew install zig, or mise install"
        fi
    fi
fi

if [ "$os" != Darwin ]; then
    say "  --  $os: the macOS app cannot be built here, so the Xcode, Metal and Zig checks are skipped"
fi

if [ "$worst" -ne 0 ]; then
    if [ "$json" = 1 ]; then
        emit_json "$worst" false
    else
        echo >&2
        echo "Nothing was installed. Fix these, then rerun make bootstrap:" >&2
        for i in "${!ids[@]}"; do
            [ "${states[$i]}" = ok ] && continue
            echo "  - ${messages[$i]}" >&2
            [ -z "${fixes[$i]}" ] || echo "      ${fixes[$i]}" >&2
        done
        if [ "$os" = Darwin ]; then
            echo "make ui-preview needs only Node.js: it installs the interface's dependencies itself." >&2
        fi
    fi
    exit "$worst"
fi

# shellcheck disable=SC2086 # each argument is a list of make targets
run_make $deps_targets || { [ "$json" = 1 ] && emit_json 1 false; exit 1; }
if [ "$with_sites" = 1 ]; then
    # shellcheck disable=SC2086
    run_make $site_targets || { [ "$json" = 1 ] && emit_json 1 false; exit 1; }
fi

if [ "$os" != Darwin ]; then
    if [ "$json" = 1 ]; then
        emit_json 0 true
    else
        cat <<'EOF'

The JavaScript lane is ready on Linux. CI runs these there:
  make ui-lint ui-test ext-bridge-test site-check site-test docs-check docs-test release-status release-test perf-summary-test
The app, the Swift tests and everything else need macOS (AppKit, WebKit, Xcode).
EOF
    fi
    exit 0
fi

# shellcheck disable=SC2086
run_make $build_targets || { [ "$json" = 1 ] && emit_json 1 true; exit 1; }

if [ "$json" = 1 ]; then
    emit_json 0 true
    exit 0
fi
echo
cat <<'EOF'
Ready. Next:
  make app          Debug build in build/debug/export/Lilo.app
  make ui-preview   the interface in your browser, with hot reload and no Xcode
  make validate     the checks to pass before opening a pull request
EOF
if [ "$with_sites" != 1 ]; then
    echo "  (make validate installs the website and docs dependencies on first use; make bootstrap BOOTSTRAP_ARGS=--with-sites does it now)"
fi
