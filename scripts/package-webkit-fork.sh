#!/bin/bash
# Package a Release build of the WebKit fork for `make webkit-fork`: see docs/WEBKIT_FORK.md.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: scripts/package-webkit-fork.sh <WebKit checkout> <output .zip>" >&2
    echo "The checkout holds the fork's commit history and its Release build in WebKitBuild/Release." >&2
    exit 1
fi
CHECKOUT="$(cd "$1" && pwd)"
OUTPUT="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$CHECKOUT/WebKitBuild/Release"
STAGING="$(mktemp -d -t webkit-fork)"
trap '/bin/rm -rf "$STAGING"' EXIT
FORK="$STAGING/WebKitFork"

MACOS_MAJOR="$(/usr/bin/vtool -show-build "$BUILD/WebKit.framework/WebKit" | awk '/minos/ { split($2, v, "."); print v[1]; exit }')"
COVERS="$(python3 -I "$ROOT/scripts/webkit-fork-coverage.py" "$CHECKOUT" "$MACOS_MAJOR")"

mkdir -p "$FORK"
for item in JavaScriptCore.framework WebCore.framework WebKit.framework WebKitLegacy.framework WebGPU.framework \
    WebInspectorUI.framework libwebrtc.dylib libANGLE-shared.dylib libWebKitSwift.dylib "$BUILD"/com.apple.WebKit.*.xpc; do
    ditto "$BUILD/$(basename "$item")" "$FORK/$(basename "$item")"
done
# Headers and modules serve only builds against the fork, never Lilo at run time.
for framework in "$FORK"/*.framework; do
    /bin/rm -rf "$framework"/{Headers,PrivateHeaders,Modules} "$framework"/Versions/A/{Headers,PrivateHeaders,Modules}
done
/usr/libexec/PlistBuddy \
    -c "Add :CoversSafari string $COVERS" \
    -c "Add :Commit string $(git -C "$CHECKOUT" rev-parse HEAD)" \
    "$FORK/WebKitFork.plist" >/dev/null

/bin/rm -f "$OUTPUT"
ditto -c -k --keepParent "$FORK" "$OUTPUT"
echo "WebKit fork $(git -C "$CHECKOUT" rev-parse --short HEAD), covers Safari $COVERS: $OUTPUT"
echo "sha256 $(shasum -a 256 "$OUTPUT" | cut -d' ' -f1)"
