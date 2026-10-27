#!/usr/bin/env bash
# Publish a packaged YoPDF DMG to a GitHub Release.
#
# Only two kinds of asset are ever uploaded: a YoPDF-*.dmg and SHA256.txt.
# The image is re-verified before upload - image checksum, code signature,
# notarization staple, Gatekeeper acceptance of the image and of a quarantined
# copy of the app extracted from it - so a build directory, an .xcarchive or a
# build log cannot be attached by accident.
#
# Usage:
#   ./scripts/release.sh <tag> [options]
#
# Options:
#   --dmg PATH       Disk image to publish (default: newest build/dist-*/YoPDF-*.dmg)
#   --notes FILE     Release notes file (default: GitHub-generated notes)
#   --attach FILE    Extra asset; must still be a YoPDF-*.dmg or SHA256.txt
#   --draft          Create the release as a draft
#   --dry-run        Verify and print the plan without uploading
#   --yes, -y        Skip the confirmation prompt
#
# The tag must already exist locally and on the remote; `--verify-tag` makes gh
# refuse to create one implicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

usage() {
  local code="${1:-0}" out="/dev/stdout"
  if [[ "$code" != 0 ]]; then out="/dev/stderr"; fi
  awk 'NR == 1 { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "$0" >"$out"
  exit "$code"
}

TAG=""
DMG=""
NOTES=""
DRAFT=0
DRY_RUN=0
ASSUME_YES=0
ATTACH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) [[ $# -ge 2 ]] || fail "--dmg needs a path"; DMG="$2"; shift 2 ;;
    --notes) [[ $# -ge 2 ]] || fail "--notes needs a path"; NOTES="$2"; shift 2 ;;
    --attach) [[ $# -ge 2 ]] || fail "--attach needs a path"; ATTACH+=("$2"); shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) usage 0 ;;
    -*) fail "unknown option $1" ;;
    *) [[ -z "$TAG" ]] || fail "unexpected argument $1"; TAG="$1"; shift ;;
  esac
done

[[ -n "$TAG" ]] || usage 1

command -v gh >/dev/null 2>&1 || fail "gh is required but not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run 'gh auth login'"
git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null ||
  fail "tag $TAG does not exist; create and push the tag first"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  note "working tree is dirty; the tag, not the tree, is the released commit"
fi
note "tag $TAG -> $(git rev-parse --short "$TAG^{commit}")"

if [[ -n "$NOTES" && ! -f "$NOTES" ]]; then
  fail "notes file not found: $NOTES"
fi

if [[ -z "$DMG" ]]; then
  NEWEST=""
  shopt -s nullglob
  for candidate in build/dist-*/YoPDF-*.dmg; do
    if [[ -z "$NEWEST" || "$candidate" -nt "$NEWEST" ]]; then
      NEWEST="$candidate"
    fi
  done
  shopt -u nullglob
  [[ -n "$NEWEST" ]] ||
    fail "no build/dist-*/YoPDF-*.dmg found; run scripts/package-dmg.sh first"
  DMG="$NEWEST"
fi

# Only a signed, notarized, stapled image may be published. Everything below
# inspects the image that will actually be uploaded, not the export directory.
note "verifying $(basename "$DMG")"
[[ -e "$DMG" ]] || fail "no such file: $DMG"
[[ -f "$DMG" ]] || fail "not a regular file: $DMG"
if [[ -L "$DMG" ]]; then fail "refusing a symlink: $DMG"; fi
case "$(basename "$DMG")" in
  *.dmg) ;;
  *) fail "not a disk image: $DMG" ;;
esac

VERIFY_OUT="$(hdiutil verify "$DMG" 2>&1)" ||
  { printf '%s\n' "$VERIFY_OUT" >&2; fail "the image checksum does not verify"; }
codesign --verify "$DMG" >/dev/null 2>&1 || fail "the image is not validly signed"
xcrun stapler validate "$DMG" >/dev/null || fail "the image is not stapled"
SPCTL_IMAGE="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 || true)"
if ! grep -q 'Notarized Developer ID' <<<"$SPCTL_IMAGE"; then
  printf '%s\n' "$SPCTL_IMAGE" >&2
  fail "Gatekeeper rejects the image; it is not a notarized Developer ID build"
fi
note "image: signed, notarized, stapled"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yopdf-release.XXXXXX")"
MNT="$TMP_DIR/mnt"
cleanup() {
  if [[ -d "$MNT" ]]; then hdiutil detach "$MNT" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
APP="$MNT/YoPDF.app"
[[ -d "$APP" ]] || fail "the image does not contain YoPDF.app"
[[ -L "$MNT/Applications" ]] || fail "the image has no /Applications symlink"
xcrun stapler validate "$APP" >/dev/null || fail "the app inside the image is not stapled"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "$APP/Contents/Info.plist")"
BUILT_ARCHS="$(lipo -archs "$APP/Contents/MacOS/YoPDF")"
note "image contains YoPDF $VERSION ($BUILD) [$BUILT_ARCHS]"

codesign -dvv "$APP" >"$TMP_DIR/codesign.txt" 2>&1 || true
grep -q 'flags=.*runtime' "$TMP_DIR/codesign.txt" ||
  fail "the app inside the image is not signed with the hardened runtime"

# A copy dragged out of the image must pass on its own stapled ticket.
cp -R "$APP" "$TMP_DIR/extracted.app"
xattr -w com.apple.quarantine "0081;00000000;Safari;" "$TMP_DIR/extracted.app"
SPCTL_APP="$(spctl -a -vvv -t exec "$TMP_DIR/extracted.app" 2>&1 || true)"
if ! grep -q 'Notarized Developer ID' <<<"$SPCTL_APP"; then
  printf '%s\n' "$SPCTL_APP" >&2
  fail "a copy extracted from the image is rejected by Gatekeeper"
fi
note "extracted app: accepted by Gatekeeper"

hdiutil detach "$MNT" >/dev/null
rmdir "$MNT"

# --- assets ----------------------------------------------------------------
SHA_FILE="$(dirname "$DMG")/SHA256.txt"
ACTUAL_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
if [[ -f "$SHA_FILE" ]]; then
  EXPECTED_SHA="$(cut -d' ' -f1 "$SHA_FILE")"
  [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] ||
    fail "SHA256.txt does not match the image; rerun scripts/package-dmg.sh"
else
  printf '%s  %s\n' "$ACTUAL_SHA" "$(basename "$DMG")" >"$SHA_FILE"
fi

ASSETS=("$DMG" "$SHA_FILE")
if [[ ${#ATTACH[@]} -gt 0 ]]; then
  for extra in "${ATTACH[@]}"; do
    ASSETS+=("$extra")
  done
fi

# The allowlist is the point of this script: build logs, archives, plists and
# notarization responses must never become Release assets.
assert_allowed_asset() {
  local file="$1" base
  if [[ ! -e "$file" ]]; then fail "asset does not exist: $file"; fi
  if [[ -L "$file" ]]; then fail "refusing to upload a symlink: $file"; fi
  if [[ ! -f "$file" ]]; then fail "refusing to upload a non-file: $file"; fi
  base="$(basename "$file")"
  case "$base" in
    SHA256.txt | YoPDF-*.dmg) ;;
    *) fail "refusing to upload '$base': only YoPDF-*.dmg and SHA256.txt are allowed" ;;
  esac
}

# Plain string comparison keeps this working on the system bash 3.2, which has
# no associative arrays. Asset names are allowlisted above, so spaces and
# glob characters cannot appear in them.
SEEN_NAMES=""
for asset in "${ASSETS[@]}"; do
  assert_allowed_asset "$asset"
  base="$(basename "$asset")"
  case " $SEEN_NAMES " in
    *" $base "*) fail "duplicate asset name: $base" ;;
  esac
  SEEN_NAMES="$SEEN_NAMES $base"
done

note "assets to publish"
for asset in "${ASSETS[@]}"; do
  printf '  %-60s %s\n' "$(basename "$asset")" "$(du -h "$asset" | cut -f1)"
done

if gh release view "$TAG" >/dev/null 2>&1; then
  ACTION=upload
else
  ACTION=create
fi

GH_ARGS=()
if [[ "$ACTION" == "create" ]]; then
  GH_ARGS=(release create "$TAG" "${ASSETS[@]}" --verify-tag
    --title "YoPDF $VERSION ($BUILD)")
  if [[ -n "$NOTES" ]]; then
    GH_ARGS+=(--notes-file "$NOTES")
  else
    GH_ARGS+=(--generate-notes)
  fi
  if [[ "$DRAFT" == 1 ]]; then GH_ARGS+=(--draft); fi
else
  GH_ARGS=(release upload "$TAG" "${ASSETS[@]}" --clobber)
  if [[ -n "$NOTES" || "$DRAFT" == 1 ]]; then
    note "release $TAG already exists; --notes and --draft only apply to new releases"
  fi
fi

if [[ "$DRY_RUN" == 1 ]]; then
  note "dry run: would run"
  printf '  gh'
  printf ' %q' "${GH_ARGS[@]}"
  printf '\n'
  exit 0
fi

if [[ "$ASSUME_YES" == 0 ]]; then
  if ! read -r -p "Publish ${#ASSETS[@]} asset(s) to release $TAG? [y/N] " answer; then
    fail "aborted"
  fi
  [[ "$answer" == [yY] ]] || fail "aborted"
fi

note "publishing to release $TAG"
gh "${GH_ARGS[@]}"
gh release view "$TAG" --json url --jq '.url'
