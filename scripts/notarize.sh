#!/usr/bin/env bash
# Notarizes a Developer ID-signed Colon.app or DMG with Apple and staples the ticket.
#
# Usage: scripts/notarize.sh <path/to/Colon.app | path/to/Colon.dmg>
#
# Environment (App Store Connect API key with the Developer role):
#   NOTARY_KEY_PATH   Path to the AuthKey_<id>.p8 file.
#   NOTARY_KEY_ID     The key's ID.
#   NOTARY_ISSUER_ID  The issuer ID shown above the key list.
set -euo pipefail

TARGET="${1:?usage: notarize.sh <app or dmg>}"
: "${NOTARY_KEY_PATH:?}" "${NOTARY_KEY_ID:?}" "${NOTARY_ISSUER_ID:?}"
AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

WORK="$(mktemp -d "${TMPDIR:-/tmp}/colon-notary.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# notarytool takes zip, pkg or dmg; an app bundle goes up zipped.
case "$TARGET" in
    *.app) UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
           ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$UPLOAD" ;;
    *.dmg) UPLOAD="$TARGET" ;;
    *) echo "error: expected an .app or .dmg: $TARGET" >&2; exit 1 ;;
esac

echo "==> Submitting $(basename "$TARGET") for notarization"
# --wait exits 0 for any finished submission, Invalid included, so check the status.
xcrun notarytool submit "$UPLOAD" "${AUTH[@]}" --wait --timeout 30m \
    --output-format json > "$WORK/result.json"
ID="$(plutil -extract id raw "$WORK/result.json")"
STATUS="$(plutil -extract status raw "$WORK/result.json")"
echo "submission $ID: $STATUS"
if [[ "$STATUS" != Accepted ]]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
    echo "error: notarization of $TARGET finished as $STATUS" >&2
    exit 1
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
