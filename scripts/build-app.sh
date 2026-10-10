#!/usr/bin/env bash
# Builds build/Colon.app from the SwiftPM package and code signs it.
#
# Usage: scripts/build-app.sh [--native] [--help]
#
#   --native   Build only for this Mac's architecture (faster; skips the universal
#              arm64 + x86_64 build). Used automatically if the universal build fails.
#
# Environment:
#   SIGN_IDENTITY     Code signing identity (name or SHA-1). Defaults to the first
#                     "Developer ID Application" identity, then the first
#                     "Apple Development" identity, then any other valid
#                     code-signing identity (e.g. a self-signed "Colon Dev"
#                     certificate) in your keychain, else ad-hoc ("-").
#                     Set SIGN_IDENTITY=- to force ad-hoc signing.
#   COLON_VERSION   Overrides CFBundleShortVersionString (a leading "v" is stripped).
#   COLON_BUILD     Overrides CFBundleVersion.
#   BUILD_DIR         Output directory (default: <repo>/build).
#
# Why the signature matters: macOS ties the Accessibility permission (TCC) to the
# app's code signature. A certificate-backed signature (Apple Development or
# Developer ID) has a stable designated requirement, so the permission survives
# rebuilds. An ad-hoc signature changes with every build, so after each rebuild you
# must remove Colon from System Settings > Privacy & Security > Accessibility and
# grant it again.
#
# Resource bundles: SwiftPM's generated `Bundle.module` accessor (Swift Build /
# XCBuild flavour) looks in `Bundle.main.resourceURL` first, which for an app is
# Contents/Resources. Both Colon_ColonCore.bundle (emoji dataset) and
# KeyboardShortcuts_KeyboardShortcuts.bundle (recorder localizations) are copied
# there. Older toolchains whose default "native" build system generates an accessor
# that only checks the app root are switched to the Xcode build system, because
# anything placed in the app root breaks the code signature.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
APP_NAME="Colon"
APP="$BUILD_DIR/$APP_NAME.app"
NATIVE=0

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

for arg in "$@"; do
    case "$arg" in
        --native) NATIVE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown option '$arg'" >&2; usage >&2; exit 64 ;;
    esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cd "$ROOT"

# The KeyboardShortcuts dependency uses SwiftUI `#Preview`, whose macro plugin ships only
# with full Xcode. Command Line Tools alone fail deep in the build with
# "plugin for module 'PreviewsMacros' not found", so say so up front.
if [[ "$(xcode-select -p 2>/dev/null)" != *.app/Contents/Developer ]]; then
    if [[ -d /Applications/Xcode.app ]]; then
        die "the active developer directory is Command Line Tools ($(xcode-select -p 2>/dev/null)).
       Switch to Xcode:  sudo xcode-select -s /Applications/Xcode.app
       Or skip building: download Colon from https://github.com/Syfraxing/Colon/releases/latest"
    fi
    die "building Colon needs full Xcode (Command Line Tools are not enough).
       Install Xcode from the App Store, or skip building and download the app:
       https://github.com/Syfraxing/Colon/releases/latest"
fi

# --- Build ------------------------------------------------------------------

SWIFT_FLAGS=(-c release)
# Swift 6.1+ defaults to Swift Build ("swiftbuild"). Older toolchains default to the
# native build system, whose Bundle.module accessor does not search Contents/Resources.
if ! swift build --help 2>/dev/null | grep -q 'swiftbuild'; then
    SWIFT_FLAGS+=(--build-system xcode)
fi

build() {
    local flags=("${SWIFT_FLAGS[@]}" "$@")
    swift build "${flags[@]}" || return 1
    BIN_DIR="$(swift build "${flags[@]}" --show-bin-path)"
}

if [[ $NATIVE -eq 0 ]]; then
    log "Building universal (arm64 + x86_64) release"
    if ! build --arch arm64 --arch x86_64; then
        warn "universal build failed; retrying for $(uname -m) only (pass --native to skip the attempt)"
        NATIVE=1
    fi
fi
if [[ $NATIVE -eq 1 ]]; then
    log "Building native ($(uname -m)) release"
    build
fi

EXECUTABLE="$BIN_DIR/$APP_NAME"
[[ -x "$EXECUTABLE" ]] || die "executable not found at $EXECUTABLE"

# --- Assemble ---------------------------------------------------------------

log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

PLIST="$APP/Contents/Info.plist"
if [[ -n "${COLON_VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "${COLON_VERSION#v}" "$PLIST"
fi
if [[ -n "${COLON_BUILD:-}" ]]; then
    plutil -replace CFBundleVersion -string "$COLON_BUILD" "$PLIST"
fi
plutil -lint "$PLIST" >/dev/null

if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
elif [[ -d "$ROOT/Resources/AppIcon.iconset" ]]; then
    iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
else
    warn "no Resources/AppIcon.icns (run 'make icon'); the app will use the generic icon"
fi

shopt -s nullglob
bundles=("$BIN_DIR"/*.bundle)
[[ -d "$BIN_DIR/${APP_NAME}_ColonCore.bundle" ]] || die "${APP_NAME}_ColonCore.bundle missing from $BIN_DIR"
for bundle in "${bundles[@]}"; do
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

# Dynamic package products (none today) go to Contents/Frameworks.
frameworks=("$BIN_DIR"/PackageFrameworks/*.framework)
if (( ${#frameworks[@]} )); then
    mkdir -p "$APP/Contents/Frameworks"
    for framework in "${frameworks[@]}"; do
        ditto "$framework" "$APP/Contents/Frameworks/$(basename "$framework")"
    done
    if ! otool -l "$APP/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$APP_NAME"
    fi
fi
shopt -u nullglob

# Extended attributes (Finder info, quarantine) make codesign reject the bundle.
xattr -cr "$APP"

# --- Sign -------------------------------------------------------------------

if [[ -z "${SIGN_IDENTITY+set}" ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    SIGN_IDENTITY="-"
    for pattern in '"Developer ID Application: ' '"Apple Development: ' '^ *[0-9]+\) [0-9A-F]{40} "'; do
        line="$(grep -m1 -E "$pattern" <<<"$identities" || true)"
        if [[ -n "$line" ]]; then
            SIGN_IDENTITY="$(awk '{print $2}' <<<"$line")"
            SIGN_LABEL="$(sed -E 's/.*"(.*)".*/\1/' <<<"$line")"
            break
        fi
    done
fi
SIGN_LABEL="${SIGN_LABEL:-$SIGN_IDENTITY}"

SIGN_FLAGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    log "Signing ad-hoc (Accessibility must be re-granted after every rebuild)"
    SIGN_FLAGS+=(--timestamp=none)
elif [[ "$SIGN_LABEL" == "Developer ID Application"* ]]; then
    log "Signing with $SIGN_LABEL (hardened runtime, secure timestamp)"
    SIGN_FLAGS+=(--options runtime --timestamp)
else
    log "Signing with $SIGN_LABEL"
    SIGN_FLAGS+=(--timestamp=none)
fi
if [[ -f "$ROOT/Resources/Colon.entitlements" ]]; then
    SIGN_FLAGS+=(--entitlements "$ROOT/Resources/Colon.entitlements")
fi

if [[ -d "$APP/Contents/Frameworks" ]]; then
    for framework in "$APP"/Contents/Frameworks/*.framework; do
        codesign "${SIGN_FLAGS[@]}" "$framework"
    done
fi
codesign "${SIGN_FLAGS[@]}" "$APP"

log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
log "Built $APP ($VERSION ($BUILD), $ARCHS, signed by $SIGN_LABEL)"
