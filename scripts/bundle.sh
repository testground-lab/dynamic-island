#!/bin/sh
# Builds a release binary and wraps it in build/DynamicIsland.app
# (LSUIElement, ad-hoc signed) so launch-at-login works.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/DynamicIsland.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DynamicIsland" "$APP/Contents/MacOS/DynamicIsland"
# SwiftPM resource bundle (fixtures for --demo). Bundle.module looks in Contents/Resources.
cp -R "$BIN_DIR/DynamicIsland_IslandCore.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ksotis.dynamic-island</string>
    <key>CFBundleName</key><string>Dynamic Island</string>
    <key>CFBundleDisplayName</key><string>Dynamic Island</string>
    <key>CFBundleExecutable</key><string>DynamicIsland</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
