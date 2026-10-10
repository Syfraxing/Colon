#!/usr/bin/env bash
# Packages build/Emojify.app into dist/Emojify-<version>.dmg with an Applications
# shortcut, laid out for drag-to-install. Builds the app first if it is missing.
#
# Usage: scripts/make-dmg.sh [build-app.sh options, used only when building]
#
# Environment:
#   BUILD_DIR       Where Emojify.app lives (default: <repo>/build).
#   DIST_DIR        Output directory (default: <repo>/dist).
#   SIGN_IDENTITY   When set to a real identity (not "-"), the DMG is signed too.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
export BUILD_DIR
APP_NAME="Emojify"
APP="$BUILD_DIR/$APP_NAME.app"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

[[ -d "$APP" ]] || "$ROOT/scripts/build-app.sh" "$@"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
VOLUME="$APP_NAME $VERSION"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/emojify-dmg.XXXXXX")"
MOUNT=""
cleanup() {
    [[ -n "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

log "Staging $APP_NAME.app"
STAGE="$WORK/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
fi

log "Creating writable image"
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF; exit}')"
[[ -n "$MOUNT" ]] || { echo "error: could not mount $RW" >&2; exit 1; }

if [[ -f "$MOUNT/.VolumeIcon.icns" ]] && command -v SetFile >/dev/null; then
    SetFile -a C "$MOUNT"
fi

# Finder layout: big icons, app on the left, Applications on the right. Needs a
# GUI session with Automation access to Finder; CI runners get the default layout.
if [[ -z "${CI:-}" ]]; then
    log "Laying out Finder window"
    if ! osascript >/dev/null <<OSA
tell application "Finder"
    set theDisk to disk "$(basename "$MOUNT")"
    open theDisk
    set win to container window of theDisk
    set current view of win to icon view
    set toolbar visible of win to false
    set statusbar visible of win to false
    set bounds of win to {200, 120, 760, 480}
    set opts to icon view options of win
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set position of item "$APP_NAME.app" of win to {140, 170}
    set position of item "Applications" of win to {420, 170}
    update theDisk without registering applications
    delay 1
    close win
end tell
OSA
    then
        warn "Finder layout skipped (grant Terminal Automation access to Finder for the pretty layout)"
    fi
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

log "Compressing $DMG"
mkdir -p "$DIST_DIR"
rm -f "$DMG"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"

if [[ -n "${SIGN_IDENTITY:-}" && "$SIGN_IDENTITY" != "-" ]]; then
    log "Signing DMG"
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi

hdiutil verify -quiet "$DMG"
log "Created $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
