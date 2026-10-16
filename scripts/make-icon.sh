#!/bin/bash
# Regenerate Resources/Queue.icns (the Dock/Finder icon) from the app's own
# drawing code: Snapshotter's QUEUE_ICON mode renders every iconset size, then
# iconutil packs them. Commit the result; bundle.sh copies it into the app.
# Usage: scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Resources/Queue.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cd "$ROOT"
swift build
BIN="$(swift build --show-bin-path)/Queue"

# Demo mode keeps the run offline and out of the Keychain.
QUEUE_DEMO=1 QUEUE_ICON="$WORK" "$BIN"

mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$WORK/Queue.iconset" -o "$OUT"
echo "Wrote: $OUT"
