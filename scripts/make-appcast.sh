#!/usr/bin/env bash
# Writes a signed Sparkle appcast with one item: the given release zip.
#
# Usage: scripts/make-appcast.sh <Colon.app> <Colon-<version>.zip> <download-url> <release-page-url> <out.xml>
#
#   <Colon.app>         The app inside the zip; versions are read from its Info.plist.
#   <download-url>      Where the zip is published (tag-specific, never .../latest/...).
#   <release-page-url>  Human-readable release notes (GitHub release page).
#
# Environment:
#   SPARKLE_ED_PRIVATE_KEY  Sparkle EdDSA private key (base64 seed, as `generate_keys -x`
#                           exports it). Passed to sign_update on stdin, never as an argument.
#   SPARKLE_BIN             Directory with Sparkle's sign_update (default: the SwiftPM
#                           artifact in .build, present after `swift package resolve`).
#
# The archive gets an EdDSA signature (sparkle:edSignature) and the finished feed is
# signed as well, which the app requires (SURequireSignedFeed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="${SPARKLE_BIN:-$ROOT/.build/artifacts/sparkle/Sparkle/bin}"

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $# -eq 5 ]] || { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
APP="$1" ZIP="$2" DOWNLOAD_URL="$3" NOTES_URL="$4" OUT="$5"

[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is not set"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "sign_update not found in $SPARKLE_BIN (run 'swift package resolve')"
[[ -f "$ZIP" ]] || die "no archive at $ZIP"

PLIST="$APP/Contents/Info.plist"
SHORT_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$PLIST")"
MIN_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw "$PLIST")"
[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || die "CFBundleVersion '$BUILD_VERSION' must be an integer"

sign() { printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - "$@"; }

# Prints: sparkle:edSignature="…" length="…"
ENCLOSURE_ATTRS="$(sign "$ZIP")"
[[ "$ENCLOSURE_ATTRS" == sparkle:edSignature=*length=* ]] || die "unexpected sign_update output"
PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat > "$OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Colon</title>
    <link>$NOTES_URL</link>
    <description>Colon updates</description>
    <language>en</language>
    <item>
      <title>Colon $SHORT_VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <link>$NOTES_URL</link>
      <sparkle:version>$BUILD_VERSION</sparkle:version>
      <sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$NOTES_URL</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<p>Colon $SHORT_VERSION is available. Read what's new in the <a href="$NOTES_URL">release notes</a>.</p>]]></description>
      <enclosure url="$DOWNLOAD_URL" type="application/octet-stream" $ENCLOSURE_ATTRS />
    </item>
  </channel>
</rss>
EOF

xmllint --noout "$OUT"
sign "$OUT"
grep -q 'sparkle-signatures' "$OUT" || die "appcast was not signed"
printf 'Wrote %s (Colon %s, build %s)\n' "$OUT" "$SHORT_VERSION" "$BUILD_VERSION"
