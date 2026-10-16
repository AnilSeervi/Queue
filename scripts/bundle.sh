#!/bin/bash
# Build Queue.app from the SPM executable (no Xcode project needed).
# Usage: scripts/bundle.sh [debug|release]   (default: release)
# QUEUE_VERSION sets CFBundleShortVersionString (default 0.0.0-dev; CI passes the tag).
# QUEUE_BUILD sets CFBundleVersion (default 1; CI passes the workflow run number).
set -euo pipefail

CONFIG="${1:-release}"
VERSION="${QUEUE_VERSION:-0.0.0-dev}"
BUILD="${QUEUE_BUILD:-1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Queue.app"
ICON="$ROOT/Resources/Queue.icns"

# Both land in Info.plist unescaped. Each starts with one to three numbers
# joined by dots; the version may then carry a "-dev" / "+42" style tag of
# letters, digits, dots and hyphens.
numbers_ok() {
    local IFS=. field fields
    case "$1" in ""|.*|*.|*..*) return 1 ;; esac
    read -r -a fields <<< "$1"
    [[ ${#fields[@]} -le 3 ]] || return 1
    for field in "${fields[@]}"; do
        case "$field" in *[!0-9]*) return 1 ;; esac
    done
}
CORE="${VERSION%%[-+]*}"
TAG="${VERSION#"$CORE"}"
if ! numbers_ok "$CORE" || [[ "$TAG" == ? || "${TAG:1}" == *[!0-9A-Za-z.-]* ]]; then
    echo "error: QUEUE_VERSION='$VERSION' — use dotted numbers, optionally tagged (0.4.1, 0.0.0-dev)" >&2
    exit 1
fi
if ! numbers_ok "$BUILD"; then
    echo "error: QUEUE_BUILD='$BUILD' — use dotted numbers (57, 57.1)" >&2
    exit 1
fi
if [[ ! -f "$ICON" ]]; then
    echo "error: $ICON is missing; run scripts/make-icon.sh" >&2
    exit 1
fi

cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Queue"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Queue"
cp "$ICON" "$APP/Contents/Resources/Queue.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Queue</string>
    <key>CFBundleDisplayName</key><string>Queue</string>
    <key>CFBundleIdentifier</key><string>com.queueapp.Queue</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleExecutable</key><string>Queue</string>
    <key>CFBundleIconFile</key><string>Queue</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Anil Seervi</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Bundled: $APP ($VERSION, build $BUILD)"
