#!/usr/bin/env bash
# Points the Homebrew cask (Casks/colon.rb in the Syfraxing/homebrew-tap checkout) at a
# release's DMG.
#
# Usage: scripts/bump-cask.sh [--push] <tap-dir> <version> <dmg-sha256>
#
#   <tap-dir>     A git clone of the tap.
#   <version>     The release's CFBundleShortVersionString, e.g. 0.6.0 (no leading "v").
#   <dmg-sha256>  SHA-256 of Colon-<version>.dmg, as in the release's SHA256SUMS.txt.
#
# Without --push this is a dry run: the cask is rewritten in the working tree and the diff
# printed, nothing is committed. With --push the checkout is reset to origin's default
# branch, rewritten, committed as "colon <version>" and pushed, retrying on a rejected push.
# Idempotent: a cask that already names this version and checksum is left alone.
set -euo pipefail

die() { printf '::error::%s\n' "$*" >&2; exit 1; }

PUSH=false
if [[ "${1:-}" == --push ]]; then PUSH=true; shift; fi
[[ $# -eq 3 ]] || { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 64; }
TAP="$1" VERSION="$2" SHA256="$3"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$VERSION' is not a final X.Y.Z"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || die "'$SHA256' is not a lowercase SHA-256"
CASK="$TAP/Casks/colon.rb"

# Rewrites the cask's top-level version and sha256 stanzas; the url derives from #{version}.
rewrite() {
    [[ -f "$CASK" ]] || die "$CASK not found"
    [[ "$(grep -cE '^  version "[^"]+"$' "$CASK")" == 1 ]] || die "$CASK: expected one version stanza"
    [[ "$(grep -cE '^  sha256 "[0-9a-f]{64}"$' "$CASK")" == 1 ]] || die "$CASK: expected one sha256 stanza"
    grep -qF '/v#{version}/Colon-#{version}.dmg"' "$CASK" || die "$CASK: url does not derive from version"
    sed -E \
        -e "s/^  version \"[^\"]+\"$/  version \"$VERSION\"/" \
        -e "s/^  sha256 \"[0-9a-f]{64}\"$/  sha256 \"$SHA256\"/" \
        "$CASK" > "$CASK.tmp"
    mv "$CASK.tmp" "$CASK"
}

if [[ "$PUSH" == false ]]; then
    rewrite
    if git -C "$TAP" diff --quiet -- Casks/colon.rb; then
        echo "Cask already at $VERSION ($SHA256); nothing to do."
    else
        git -C "$TAP" --no-pager diff -- Casks/colon.rb
    fi
    exit 0
fi

BRANCH="$(git -C "$TAP" symbolic-ref --short refs/remotes/origin/HEAD)"
BRANCH="${BRANCH#origin/}"
for attempt in 1 2 3; do
    # Start from the remote tip each time, so a concurrent commit to the tap is kept
    # rather than rebased over.
    git -C "$TAP" fetch --quiet origin "$BRANCH"
    git -C "$TAP" checkout --quiet -B "$BRANCH" FETCH_HEAD
    rewrite
    if git -C "$TAP" diff --quiet -- Casks/colon.rb; then
        echo "Cask already at $VERSION ($SHA256); nothing to push."
        exit 0
    fi
    git -C "$TAP" --no-pager diff -- Casks/colon.rb
    git -C "$TAP" commit --quiet -m "colon $VERSION" -- Casks/colon.rb
    if git -C "$TAP" push --quiet origin "HEAD:$BRANCH"; then
        echo "Pushed colon $VERSION to the tap."
        exit 0
    fi
    echo "Push rejected (attempt $attempt); retrying from the new tip." >&2
    sleep $((attempt * 5))
done
die "could not push the cask bump after 3 attempts"
