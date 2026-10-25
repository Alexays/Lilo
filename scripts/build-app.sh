#!/bin/bash
# Build, export, and optionally notarize Lilo.app.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh [debug|release] [install] [notarize]

Arguments:
  debug|release   Select the Xcode configuration to build. Defaults to debug.
  install         Copy the exported app into place: a release replaces /Applications/Lilo.app,
                  where the DMG installs it; a debug build goes to ~/Applications/Lilo.app.
                  Builds this Mac's architecture only, unless notarizing.
  notarize        Submit the exported release app to notarytool, wait, and staple.

Signing (ad-hoc when no team ID is set):
  LILO_TEAM_ID                Team ID for Developer ID signing and export of release builds.
  LILO_CODE_SIGN_IDENTITY     Release signing identity. Defaults to 'Developer ID Application'.
  LILO_DEBUG_TEAM_ID          Team ID for development signing (debug, and release without LILO_TEAM_ID).
                              Defaults to LILO_TEAM_ID.
  LILO_DEBUG_CODE_SIGN_IDENTITY
                              Development signing identity. Defaults to 'Apple Development'.
  LILO_PROVISIONING_PROFILE   Developer ID provisioning profile granting the browser passkey
                              entitlement. Release signing only: embeds it and adds the entitlement.

Notarization (a keychain profile, or an Apple ID and app-specific password):
  LILO_NOTARY_PROFILE         notarytool keychain profile name.
  LILO_NOTARY_APPLE_ID        Apple ID, used with LILO_TEAM_ID.
  LILO_NOTARY_APP_PASSWORD    App-specific password for that Apple ID.

Artifacts:
  build/<config>/archive/Lilo.xcarchive   (Developer ID signing only)
  build/<config>/export/Lilo.app
  build/<config>/dist/Lilo-<config>.zip
EOF
}

CONFIG="debug"
INSTALL=false
NOTARIZE=false
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        install) INSTALL=true ;;
        notarize) NOTARIZE=true ;;
        help|-h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DERIVED_DATA_DIR="$ROOT/.derived.noindex/build-app"
OUT_DIR="$ROOT/build/$CONFIG"
ARCHIVE_PATH="$OUT_DIR/archive/Lilo.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
APP="$EXPORT_DIR/Lilo.app"
ZIP="$OUT_DIR/dist/Lilo-$CONFIG.zip"

TEAM_ID="${LILO_TEAM_ID:-}"
IDENTITY="${LILO_CODE_SIGN_IDENTITY:-Developer ID Application}"
DEBUG_TEAM_ID="${LILO_DEBUG_TEAM_ID:-$TEAM_ID}"
DEBUG_IDENTITY="${LILO_DEBUG_CODE_SIGN_IDENTITY:-Apple Development}"

XCODE_CONFIGURATION="Debug"
if [ "$CONFIG" = "release" ]; then
    XCODE_CONFIGURATION="Release"
fi

# A release without Developer ID falls back to development signing: ad-hoc would change the
# designated requirement on every install, so macOS re-prompts for camera, microphone and keychain.
if [ "$CONFIG" = "release" ] && [ -n "$TEAM_ID" ]; then
    SIGNING="distribution"
    SIGNING_SETTINGS=("DEVELOPMENT_TEAM=$TEAM_ID" "CODE_SIGN_IDENTITY=$IDENTITY" "ENABLE_HARDENED_RUNTIME=YES")
    SIGNING_LABEL="$IDENTITY ($TEAM_ID)"
elif [ -n "$DEBUG_TEAM_ID" ]; then
    SIGNING="development"
    SIGNING_SETTINGS=("DEVELOPMENT_TEAM=$DEBUG_TEAM_ID" "CODE_SIGN_IDENTITY=$DEBUG_IDENTITY")
    SIGNING_LABEL="$DEBUG_IDENTITY ($DEBUG_TEAM_ID)"
else
    SIGNING="ad-hoc"
    SIGNING_SETTINGS=("DEVELOPMENT_TEAM=" "CODE_SIGN_IDENTITY=-")
    SIGNING_LABEL="ad-hoc"
fi

# A distributed release without the Sparkle public key could never update itself.
if [ "$CONFIG" = "release" ] && [ "$INSTALL" != true ] \
    && ! grep -Eq '^SPARKLE_PUBLIC_ED_KEY = [A-Za-z0-9+/=]{40,}$' "$ROOT/Xcode/Configs/Base.xcconfig"; then
    echo "SPARKLE_PUBLIC_ED_KEY is empty in Xcode/Configs/Base.xcconfig: see docs/RELEASING.md (Sparkle key)." >&2
    exit 1
fi

if [ "$NOTARIZE" = true ] && [ "$SIGNING" != "distribution" ]; then
    echo "Notarization needs a release build with LILO_TEAM_ID and a Developer ID Application certificate." >&2
    exit 1
fi

# A local install runs only on this Mac: building the other architecture doubles the compile.
if [ "$INSTALL" = true ] && [ "$NOTARIZE" != true ]; then
    SIGNING_SETTINGS+=("ARCHS=$(uname -m)")
fi

rm -rf "$OUT_DIR"
mkdir -p "$EXPORT_DIR" "$(dirname "$ZIP")"

# A build with an archive's postprocessing rather than xcodebuild archive, which starts from an empty build folder
# every time: this one compiles only what changed, and a change of signing settings compiles nothing.
xcodebuild \
    -project "$ROOT/Lilo.xcodeproj" \
    -scheme Lilo \
    -configuration "$XCODE_CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Manual \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    DEPLOYMENT_POSTPROCESSING=YES \
    "${SIGNING_SETTINGS[@]}" \
    build
BUILT_APP="$DERIVED_DATA_DIR/Build/Products/$XCODE_CONFIGURATION/Lilo.app"
# Xcode registers each app it builds with LaunchServices: the build folder's copy must never open links.
"$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true

if [ "$SIGNING" = "distribution" ]; then
    # The archive -exportArchive signs from: the app, and the keys export reads.
    ditto "$BUILT_APP" "$ARCHIVE_PATH/Products/Applications/Lilo.app"
    cat > "$ARCHIVE_PATH/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ApplicationProperties</key>
    <dict>
        <key>ApplicationPath</key>
        <string>Applications/Lilo.app</string>
        <key>CFBundleIdentifier</key>
        <string>$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")</string>
    </dict>
    <key>ArchiveVersion</key>
    <integer>2</integer>
    <key>Name</key>
    <string>Lilo</string>
    <key>SchemeName</key>
    <string>Lilo</string>
</dict>
</plist>
EOF
    EXPORT_OPTIONS="$DERIVED_DATA_DIR/ExportOptions.plist"
    cat > "$EXPORT_OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$IDENTITY</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$EXPORT_OPTIONS"
else
    ditto "$BUILT_APP" "$APP"
fi

if [ "$SIGNING" = "distribution" ] && [ -n "${LILO_PROVISIONING_PROFILE:-}" ]; then
    # A restricted entitlement is honored only with the profile and the app identifier it names.
    ENTITLEMENTS="$DERIVED_DATA_DIR/Lilo.entitlements"
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
    cp -f "$ROOT/Lilo/Lilo.entitlements" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy \
        -c 'Add :com.apple.developer.web-browser.public-key-credential bool true' \
        -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $TEAM_ID" \
        "$ENTITLEMENTS"
    cp -f "$LILO_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force --sign "$IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
fi

NOTARIZATION="skipped"
if [ "$NOTARIZE" = true ]; then
    if [ -n "${LILO_NOTARY_PROFILE:-}" ]; then
        NOTARY_ARGS=(--keychain-profile "$LILO_NOTARY_PROFILE")
    elif [ -n "${LILO_NOTARY_APPLE_ID:-}" ] && [ -n "${LILO_NOTARY_APP_PASSWORD:-}" ]; then
        NOTARY_ARGS=(--apple-id "$LILO_NOTARY_APPLE_ID" --team-id "$TEAM_ID" --password "$LILO_NOTARY_APP_PASSWORD")
    else
        echo "Notarization requires LILO_NOTARY_PROFILE, or LILO_NOTARY_APPLE_ID and LILO_NOTARY_APP_PASSWORD." >&2
        exit 1
    fi

    NOTARY_DIR="$OUT_DIR/notarization"
    mkdir -p "$NOTARY_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_DIR/Lilo-upload.zip"
    xcrun notarytool submit "$NOTARY_DIR/Lilo-upload.zip" --wait --output-format json "${NOTARY_ARGS[@]}" \
        > "$NOTARY_DIR/notary-result.json"
    STATUS="$(plutil -extract status raw -o - "$NOTARY_DIR/notary-result.json" 2>/dev/null || true)"
    if [ "$STATUS" != "Accepted" ]; then
        echo "Notarization finished with status '${STATUS:-unknown}', not Accepted. See $NOTARY_DIR/notary-result.json and 'xcrun notarytool log <id>'." >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    NOTARIZATION="completed"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ "$INSTALL" = true ]; then
    # A release shares its identity and data with the DMG's copy: one copy, in its place, so macOS never
    # opens links or Spotlight results with the other.
    if [ "$CONFIG" = "release" ]; then
        INSTALLED="/Applications/Lilo.app"
        STRAY="$HOME/Applications/Lilo.app"
        if [ "$(defaults read "$STRAY/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "fr.arouillard.lilo" ]; then
            echo "warning: $STRAY is another release copy of Lilo; remove it so macOS only opens $INSTALLED" >&2
        fi
    else
        INSTALLED="$HOME/Applications/Lilo.app"
    fi
    rm -rf "$INSTALLED"
    mkdir -p "$(dirname "$INSTALLED")"
    ditto "$APP" "$INSTALLED"
    "$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
    # The export copy under build/ is a throwaway artifact: unregistered so it never competes as an
    # http/https handler (a link clicked in another app would launch that stale copy).
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
else
    "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

echo "Signing: $SIGNING_LABEL"
[ "$SIGNING" = "distribution" ] && echo "Archive: $ARCHIVE_PATH"
echo "Exported app: $APP"
echo "Distribution zip: $ZIP"
echo "Notarization: $NOTARIZATION"
if [ "$INSTALL" = true ]; then
    echo "Installed app: $INSTALLED"
fi
