#!/bin/bash
# Build Queue.app from the SPM executable (no Xcode project needed).
# Usage: scripts/bundle.sh [debug|release]   (default: release)
# QUEUE_VERSION sets CFBundleShortVersionString (default 0.0.0-dev; CI passes the tag).
set -euo pipefail

CONFIG="${1:-release}"
VERSION="${QUEUE_VERSION:-0.0.0-dev}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Queue.app"

cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Queue"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Queue"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Queue</string>
    <key>CFBundleDisplayName</key><string>Queue</string>
    <key>CFBundleIdentifier</key><string>com.queueapp.Queue</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>Queue</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Bundled: $APP"
