#!/bin/bash
# make bootstrap: checks what building Lilo needs, then runs the make targets that prepare a clone.
# $1 installs the npm dependencies, $2 builds the rest; both are no-ops once done.
echo "Checking the prerequisites"

missing=()

macos=$(sw_vers -productVersion 2>/dev/null || echo none)
if [ "${macos%%.*}" -ge 26 ] 2>/dev/null; then
    echo "  ok  macOS $macos"
else
    missing+=("macOS 26 or later (found: $macos): update it in System Settings > General > Software Update")
fi

xcode=$(xcodebuild -version 2>/dev/null | head -1)
if [[ $xcode == "Xcode 27"* ]]; then
    echo "  ok  $xcode ($(xcode-select -p))"
    # Xcode 26 and later download the Metal compiler separately; the terminal's shaders need it.
    if xcrun metal --version >/dev/null 2>&1; then
        echo "  ok  Metal toolchain"
    else
        missing+=("the Metal toolchain: xcodebuild -downloadComponent MetalToolchain")
    fi
else
    missing+=("Xcode 27 selected (found: ${xcode:-none at $(xcode-select -p 2>/dev/null || echo '?')}): install it from https://developer.apple.com/xcode/, open it once, then: sudo xcode-select -s /Applications/Xcode.app")
fi

# The packages' engines field, not .nvmrc's major: the bridge tests need --experimental-strip-types.
wanted_node=$(sed -n 's/.*"node": *">=\([0-9.]*\)".*/\1/p' lilo-ui/package.json)
node_version=$(node -v 2>/dev/null)
if [ -n "$node_version" ] && [ "$(printf '%s\n' "$wanted_node" "${node_version#v}" | sort -V | head -1)" = "$wanted_node" ]; then
    echo "  ok  Node.js $node_version"
else
    echo "Missing: Node.js $wanted_node or later, as the packages require (found: ${node_version:-none})." >&2
    echo "Install it with nvm (nvm install, which reads .nvmrc), fnm, or from https://nodejs.org, then rerun make bootstrap." >&2
    exit 1
fi

# shellcheck disable=SC2086 # each argument is a list of make targets
make -s --no-print-directory $1 || exit 1

if [ ${#missing[@]} -gt 0 ]; then
    echo >&2
    echo "The npm dependencies are installed: make ui-preview already works. Building the app needs:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install them, then rerun make bootstrap." >&2
    exit 1
fi

# shellcheck disable=SC2086
make -s --no-print-directory $2 || exit 1

echo
cat <<'EOF'
Ready. Next:
  make app          Debug build in build/debug/export/Lilo.app
  make ui-preview   the interface in your browser, with hot reload and no Xcode
  make validate     the checks to pass before opening a pull request
EOF
