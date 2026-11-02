#!/bin/bash
# Embed the WebKit fork in a signed Lilo.app and sign it the same way: see docs/WEBKIT_FORK.md.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: scripts/embed-webkit-fork.sh <Lilo.app> <fork directory>" >&2
    echo "The fork directory is what scripts/package-webkit-fork.sh packages (Vendor/WebKitFork)." >&2
    exit 1
fi
APP="$1"
FORK="$2"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS="$APP/Contents/Frameworks"
EXECUTABLE="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
FORK_EXECUTABLE="$APP/Contents/MacOS/LiloFork"
WORK="$(mktemp -d -t lilo-webkit-fork)"
trap '/bin/rm -rf "$WORK"' EXIT
ENTITLEMENTS="$WORK/entitlements.plist"

# Everything is signed as the app is: its certificate (ad-hoc when it has none), its entitlements, and for a
# release the hardened runtime and a timestamp.
codesign --display --entitlements - --xml "$APP" > "$ENTITLEMENTS"
SIGNATURE="$(codesign --display --verbose=2 "$APP" 2>&1)"
IDENTITY="-"
if codesign --display --extract-certificates="$WORK/certificate" "$APP" 2>/dev/null && [ -f "$WORK/certificate0" ]; then
    IDENTITY="$(openssl x509 -inform DER -in "$WORK/certificate0" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
fi
SIGN_OPTIONS=()
grep -q "flags=.*runtime" <<< "$SIGNATURE" && SIGN_OPTIONS+=(--options runtime)
grep -q "^Timestamp=" <<< "$SIGNATURE" && SIGN_OPTIONS+=(--timestamp)

# The XPC services find the frameworks next to them (their own dyld environment), so the layout of the build stays.
mkdir -p "$FRAMEWORKS"
for item in "$FORK"/*; do
    [ "$(basename "$item")" = WebKitFork.plist ] && continue
    ditto "$item" "$FRAMEWORKS/$(basename "$item")"
done

/usr/libexec/PlistBuddy -c "Delete :LiloWebKitForkCoversSafari" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LiloWebKitForkCoversSafari string $(/usr/libexec/PlistBuddy -c 'Print :CoversSafari' "$FORK/WebKitFork.plist")" "$APP/Contents/Info.plist"

# The fork is built for Apple silicon only: on an Intel Mac the exec fails and Lilo stays on the system WebKit.
lipo "$EXECUTABLE" -thin arm64 -output "$FORK_EXECUTABLE" 2>/dev/null || /bin/cp -f "$EXECUTABLE" "$FORK_EXECUTABLE"
codesign --remove-signature "$FORK_EXECUTABLE"
python3 -I "$ROOT/scripts/add-dyld-environment.py" "$FORK_EXECUTABLE" \
    "DYLD_FRAMEWORK_PATH=@executable_path/../Frameworks" "DYLD_LIBRARY_PATH=@executable_path/../Frameworks"

# Inside out: the services and libraries, then the frameworks sealing them, then the executables and the app.
sign() { codesign --force --sign "$IDENTITY" ${SIGN_OPTIONS[@]+"${SIGN_OPTIONS[@]}"} "$@"; }
for item in "$FORK"/*.xpc "$FORK"/*.dylib; do
    sign --preserve-metadata=identifier,entitlements "$FRAMEWORKS/$(basename "$item")"
done
for item in "$FORK"/*.framework; do
    sign "$FRAMEWORKS/$(basename "$item")"
done
sign --identifier "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" \
    --entitlements "$ENTITLEMENTS" "$FORK_EXECUTABLE"
sign --entitlements "$ENTITLEMENTS" "$APP"
