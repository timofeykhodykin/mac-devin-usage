#!/bin/bash
# Builds a universal (Apple silicon + Intel) "Devin Usage.app" into ./dist.
# Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Devin Usage"
BUNDLE_ID="dev.mac-devin-usage"
VERSION="$(tr -d '[:space:]' < VERSION)"
# Build number: commits on this branch, so every build of a newer commit gets a higher one.
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/$APP_NAME.app"

BINS=()
for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH"
    BINS+=("$(swift build -c release --arch "$ARCH" --show-bin-path)/MacDevinUsage")
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/MacDevinUsage"
cp Resources/*.png "$APP/Contents/Resources/"
# The license travels with the app, so a downloaded copy carries its terms and notice.
cp LICENSE.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>MacDevinUsage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>NSHumanReadableCopyright</key><string>PolyForm Noncommercial License 1.0.0.</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# An ad-hoc signature is enough: the app only reads files and talks to Devin's API,
# so it does not depend on its code signature for entitlements.
codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, build $BUILD)"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications/$APP_NAME.app"
    mkdir -p "$HOME/Applications"
    pkill -x MacDevinUsage 2>/dev/null || true
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
