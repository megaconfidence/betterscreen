#!/bin/bash
#
# Builds BetterScreen and assembles a signed .app bundle in ./dist.
#
# Usage:
#   Scripts/bundle.sh                 release build, sign, no launch
#   Scripts/bundle.sh --run           build and launch
#   Scripts/bundle.sh --debug --run   debug build and launch
#   Scripts/bundle.sh --logs          stream the app's os_log output
#   Scripts/bundle.sh --reset-tcc     revoke the camera grant to re-test the prompt

set -euo pipefail

APP_NAME="BetterScreen"
BUNDLE_ID="com.betterscreen.app"
VERSION="0.1.0"
BUILD="1"
MIN_MACOS="15.0"
SIGN_IDENTITY="${SIGN_IDENTITY:-BetterScreen Dev}"

CONFIG="release"
DO_RUN=0
DO_RESET_TCC=0
DO_LOGS=0

for arg in "$@"; do
    case "$arg" in
        --debug)     CONFIG="debug" ;;
        --release)   CONFIG="release" ;;
        --run)       DO_RUN=1 ;;
        --reset-tcc) DO_RESET_TCC=1 ;;
        --logs)      DO_LOGS=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# dist/ must live under $HOME. `tccutil reset` resolves bundle IDs through
# LaunchServices and fails with -10814 for bundles under /private/var/folders,
# even after an explicit lsregister.
APP="$ROOT/dist/$APP_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key>       <true/>

    <!-- Menu bar only: no Dock icon, no Cmd-Tab entry. -->
    <key>LSUIElement</key>                   <true/>

    <!-- Mandatory. Without it TCC cannot render a prompt and the app is
         terminated when it touches the camera. -->
    <key>NSCameraUsageDescription</key>
    <string>$APP_NAME measures the light in your room so it can adjust your display brightness. Images are analysed on your Mac for overall brightness only, and are never stored or transmitted.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# --- Signing ---------------------------------------------------------------
#
# No --options runtime. Enabling the hardened runtime additionally requires the
# com.apple.security.device.camera entitlement, and without it TCC refuses to
# even show the prompt ("Policy disallows prompt").
#
# No App Sandbox either: it blocks `mach-lookup com.apple.backlightd`, which is
# what display brightness control goes through.
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "==> Signing with '$SIGN_IDENTITY' (stable identity)"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "==> WARNING: identity '$SIGN_IDENTITY' not found; falling back to ad-hoc."
    echo "    Camera permission will be requested again after EVERY rebuild."
    echo "    Fix once with: Scripts/make-signing-cert.sh '$SIGN_IDENTITY'"
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

codesign --verify --strict "$APP"
echo "    $(codesign -d --requirements - "$APP" 2>&1 | grep -i designated || true)"

# Required for tccutil to be able to resolve the bundle identifier.
"$LSREGISTER" -f "$APP" 2>/dev/null || true

if [ "$DO_RESET_TCC" = 1 ]; then
    echo "==> Resetting camera permission for $BUNDLE_ID"
    tccutil reset Camera "$BUNDLE_ID" || echo "    (failed; ensure dist/ is under \$HOME)"
fi

echo "==> Built $APP"

if [ "$DO_RUN" = 1 ]; then
    # Always launch via `open`. Running Contents/MacOS/<binary> directly makes TCC
    # attribute the camera grant to the *terminal* rather than to the app.
    echo "==> Launching"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi

if [ "$DO_LOGS" = 1 ]; then
    echo "==> Streaming logs (Ctrl-C to stop)"
    # /usr/bin/log, not `log`: the bare name is a zsh builtin.
    /usr/bin/log stream --style compact --level debug \
        --predicate "subsystem == '$BUNDLE_ID'"
fi
