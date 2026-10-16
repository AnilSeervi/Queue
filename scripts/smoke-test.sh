#!/bin/bash
# Launch a built Queue.app once in demo snapshot mode (fixture data, no
# network, no Keychain) and fail unless it exits cleanly and renders every
# surface. Release CI runs this before publishing.
# Usage: scripts/smoke-test.sh [path/to/Queue.app] [empty-snapshot-dir]
#   defaults: build/Queue.app, a fresh temp dir (kept, so the PNGs can be viewed)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Queue.app}"
SNAP="${2:-$(mktemp -d)}"
TIMEOUT=120

# What Snapshotter writes; keep in sync with App/Snapshotter.swift.
EXPECTED=(app-icon.png onboarding-step1.png onboarding-token.png)
for appearance in dark light; do
    for tab in inbox prs issues stats; do EXPECTED+=("panel-$tab-$appearance.png"); done
    for tab in inbox prs; do EXPECTED+=("panel-$tab-done-$appearance.png"); done
    for variant in inbox-hover prs-hover prs-merge; do EXPECTED+=("panel-$variant-$appearance.png"); done
    for icon in all-clear count count-ci dot ci-failing; do EXPECTED+=("icon-$icon-$appearance.png"); done
    EXPECTED+=("settings-$appearance.png")
done

fail() { echo "error: $*" >&2; exit 1; }

BIN="$APP/Contents/MacOS/Queue"
[[ -x "$BIN" ]] || fail "no executable at $BIN"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is malformed"
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null)" \
    || fail "Info.plist has no CFBundleIconFile"
[[ -s "$APP/Contents/Resources/${ICON_FILE%.icns}.icns" ]] || fail "icon '$ICON_FILE' is not in Contents/Resources"
codesign --verify --deep "$APP" || fail "code signature does not verify"

mkdir -p "$SNAP"
[[ -z "$(ls -A "$SNAP")" ]] || fail "snapshot dir $SNAP is not empty"
LOG="$SNAP/queue.log"

QUEUE_DEMO=1 QUEUE_SNAPSHOT="$SNAP" "$BIN" >"$LOG" 2>&1 &
PID=$!
deadline=$((SECONDS + TIMEOUT))
while kill -0 "$PID" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
        kill -9 "$PID" 2>/dev/null || true
        cat "$LOG" >&2
        fail "Queue did not exit within ${TIMEOUT}s"
    fi
    sleep 1
done
status=0
wait "$PID" || status=$?
if (( status != 0 )); then
    cat "$LOG" >&2
    fail "Queue exited with status $status"
fi

missing=()
for name in "${EXPECTED[@]}"; do
    [[ -s "$SNAP/$name" ]] || missing+=("$name")
done
if (( ${#missing[@]} > 0 )); then
    ls -l "$SNAP" >&2
    fail "missing snapshots: ${missing[*]}"
fi

# A blank layout would still write a (tiny) PNG; the panel is 440pt wide.
width="$(sips -g pixelWidth "$SNAP/panel-inbox-dark.png" | awk '/pixelWidth/ {print $2}')"
(( width >= 440 )) || fail "panel-inbox-dark.png is only ${width}px wide"

echo "Smoke test passed: ${#EXPECTED[@]} snapshots in $SNAP"
