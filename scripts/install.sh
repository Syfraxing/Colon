#!/usr/bin/env bash
# Builds Colon, quits the running copy, installs it to /Applications (or
# ~/Applications when /Applications is not writable) and launches it.
#
# Usage: scripts/install.sh [build-app.sh options, e.g. --native]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
export BUILD_DIR
APP_NAME="Colon"
BUNDLE_ID="so.slayer.Colon"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

"$ROOT/scripts/build-app.sh" "$@"

if pgrep -x "$APP_NAME" >/dev/null; then
    log "Quitting running $APP_NAME"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.25
    done
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

if [[ -w /Applications ]]; then
    DEST_DIR=/Applications
else
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME.app"

log "Installing to $DEST"
rm -rf "$DEST"
ditto "$BUILD_DIR/$APP_NAME.app" "$DEST"

log "Launching $APP_NAME"
open "$DEST"
