#!/usr/bin/env bash
# Checks that a release would move the published Sparkle feed forward.
#
# Usage: scripts/check-feed-forward.sh <feed-url> <build> <version>
#
#   <build>    New CFBundleVersion / sparkle:version (integer).
#   <version>  New CFBundleShortVersionString, e.g. 0.3.1.
#
# Exit status: 0 when there is no published feed yet (HTTP 404) or the new build number
# is higher and the version is not older than the newest published item; 3 when it is
# not (an older or duplicate release); 1 on any other problem (network, bad feed).
set -euo pipefail

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

[[ $# -eq 3 ]] || { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
FEED_URL="$1" BUILD="$2" VERSION="$3"
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "build '$BUILD' is not an integer"

FEED="$(mktemp)"
trap 'rm -f "$FEED"' EXIT
STATUS="$(curl -sSL --retry 3 -o "$FEED" -w '%{http_code}' "$FEED_URL")" || die "could not fetch $FEED_URL"
case "$STATUS" in
    404) echo "No published appcast at $FEED_URL yet."; exit 0 ;;
    200) ;;
    *) die "fetching $FEED_URL returned HTTP $STATUS" ;;
esac

read_item() { xmllint --xpath "string((//*[local-name()='item'])[1]/*[local-name()='$1'])" "$FEED"; }
PUBLISHED_BUILD="$(read_item version)"
PUBLISHED_VERSION="$(read_item shortVersionString)"
[[ "$PUBLISHED_BUILD" =~ ^[0-9]+$ ]] || die "published sparkle:version '$PUBLISHED_BUILD' is not an integer"
echo "Published: $PUBLISHED_VERSION ($PUBLISHED_BUILD); this release: $VERSION ($BUILD)"

if (( BUILD <= PUBLISHED_BUILD )); then
    echo "Build $BUILD is not newer than the published $PUBLISHED_BUILD."
    exit 3
fi
if [[ "$(printf '%s\n%s\n' "$PUBLISHED_VERSION" "$VERSION" | sort -V | tail -1)" != "$VERSION" ]]; then
    echo "Version $VERSION is older than the published $PUBLISHED_VERSION."
    exit 3
fi
