#!/usr/bin/env bash
# Generate the signed Sparkle appcast for an already published DMG.
#
# Sparkle downloads updates straight from the GitHub Release asset, so the
# release must exist before the feed is written: the enclosure URL is derived
# from the tag. The result is written to appcast.xml at the repository root,
# which is served as
#   https://raw.githubusercontent.com/<owner>/<repo>/main/appcast.xml
# and has to be committed and pushed for clients to see a new version.
#
# Usage:
#   ./scripts/appcast.sh <dist-dir>
#
# Env:
#   SPARKLE_GENERATE_APPCAST  Override the path to Sparkle's generate_appcast.
#   SPARKLE_ED_KEY_FILE       Read the private key from this file instead of the
#                             Keychain; '-' reads it from standard input.
#
# The private EdDSA key is read from the login Keychain; it is never written to
# the repository or passed on the command line. The Keychain item only trusts
# the tools that created it, so on a machine where generate_appcast is blocked
# by that ACL (it waits forever on a prompt nobody can answer) pipe the key in
# through SPARKLE_ED_KEY_FILE=-, without letting it touch the disk.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(cd .. && pwd)"
FEED="$REPO_ROOT/appcast.xml"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

DIST="${1:-}"
[[ -n "$DIST" ]] || fail "usage: $0 <dist-dir>"
info="$DIST/build-info.txt"
[[ -f "$info" ]] || fail "missing $info; run scripts/package-dmg.sh first"

prov() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$info"
}

VERSION="$(prov version)"
BUILD="$(prov build)"
DMG_NAME="$(prov dmg)"
[[ -n "$VERSION" && -n "$BUILD" && -n "$DMG_NAME" ]] ||
  fail "$info is missing version, build or dmg"
[[ -f "$DIST/$DMG_NAME" ]] || fail "missing $DIST/$DMG_NAME"

TAG="v$VERSION"

TOOL="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$TOOL" ]]; then
  TOOL="$(find build -type f \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
fi
[[ -n "$TOOL" && -x "$TOOL" ]] ||
  fail "generate_appcast not found; run scripts/build.sh once to fetch the Sparkle tools"

command -v gh >/dev/null 2>&1 || fail "gh is required but not installed"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

# A feed that points at an asset nobody can download is worse than no feed, so
# the enclosure target is checked against the release instead of assumed.
ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null)" ||
  fail "release $TAG does not exist; run scripts/release.sh $TAG first"
grep -qxF "$DMG_NAME" <<<"$ASSETS" ||
  fail "release $TAG has no asset named $DMG_NAME; publish the image first"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/yopdf-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$DIST/$DMG_NAME" "$STAGE/"
# generate_appcast merges into an existing feed. Seeding it keeps older
# versions listed, which is what a client on an older build needs.
if [[ -f "$FEED" ]]; then cp "$FEED" "$STAGE/appcast.xml"; fi

note "signing $DMG_NAME for $TAG"
# bash 3.2 treats "${arr[@]}" on an empty array as unbound under `set -u`, so
# the two invocations are spelled out instead of building an argument array.
FEED_URL_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
LINK_URL="https://github.com/$REPO/releases"
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  "$TOOL" --ed-key-file "$SPARKLE_ED_KEY_FILE" \
    --download-url-prefix "$FEED_URL_PREFIX" --link "$LINK_URL" \
    "$STAGE" >/dev/null
else
  "$TOOL" \
    --download-url-prefix "$FEED_URL_PREFIX" --link "$LINK_URL" \
    "$STAGE" >/dev/null
fi

cp "$STAGE/appcast.xml" "$FEED"

note "wrote appcast.xml for $VERSION ($BUILD)"
printf '  feed: %s\n' "https://raw.githubusercontent.com/$REPO/main/appcast.xml"
printf '  publish it with: git add appcast.xml && git commit && git push\n'
