#!/bin/bash
# Builds MultiPlay.app into ./build
#
#   ./build.sh            build for this Mac
#   ./build.sh --install  build, copy to /Applications and launch
#   ./build.sh --release  universal (Apple Silicon + Intel) build, zipped for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUILD_NUMBER="1"
BUNDLE_ID="com.multiplay.app"
SIGNING_IDENTITY="MultiPlay Dev"

MODE="${1:-}"
case "$MODE" in
    ""|--install|--release) ;;
    *) echo "Usage: $0 [--install | --release]"; exit 1 ;;
esac

if ! command -v swift >/dev/null; then
    echo "Swift not found. Install Xcode, or the Command Line Tools with: xcode-select --install"
    exit 1
fi

# --- Compile -----------------------------------------------------------------------------
if [ "$MODE" = "--release" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/MultiPlay
else
    swift build -c release
    BINARY=.build/release/MultiPlay
fi

# --- Bundle ------------------------------------------------------------------------------
APP=build/MultiPlay.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/MultiPlay"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MultiPlay</string>
    <key>CFBundleDisplayName</key><string>MultiPlay</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>MultiPlay</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>NSMicrophoneUsageDescription</key><string>MultiPlay listens to a few short chirps to sync your speakers automatically. Nothing is saved or sent anywhere.</string>
    <key>NSAudioCaptureUsageDescription</key><string>MultiPlay captures system audio so it can play it on several speakers in sync.</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# --- Sign --------------------------------------------------------------------------------
# A stable certificate (scripts/create-signing-cert.sh) lets macOS keep the audio and mic
# permissions across rebuilds. Ad-hoc signatures change on every build, so macOS forgets them.
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
    codesign --force --sign "$SIGNING_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
    echo
    echo "Note: signed ad-hoc. macOS will forget MultiPlay's permissions after every rebuild."
    echo "      Run scripts/create-signing-cert.sh once to fix that."
    echo
fi
echo "Built $APP ($VERSION)"

# --- Optional steps ----------------------------------------------------------------------
if [ "$MODE" = "--install" ]; then
    pkill -x MultiPlay 2>/dev/null && sleep 0.5 || true
    rm -rf /Applications/MultiPlay.app
    cp -R "$APP" /Applications/
    open /Applications/MultiPlay.app
    echo "Installed to /Applications and launched. Look for the speaker icon in the menu bar."
fi

if [ "$MODE" = "--release" ]; then
    ZIP="build/MultiPlay-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Release archive: $ZIP"
fi
