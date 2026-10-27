#!/usr/bin/env bash
# Publish a packaged YoPDF DMG to a GitHub Release.
#
# Only two assets are ever uploaded: the YoPDF-*.dmg named by its build-info.txt
# and the matching SHA256.txt. The image is re-verified before upload - image
# checksum, code signature, notarization staple, Gatekeeper acceptance of the
# image and of a quarantined copy of the app extracted from it - and its
# provenance (commit, dirty state, version, build number, hash) must match the
# release tag. A build directory, an .xcarchive or an Xcode log cannot be
# attached by accident, and an image built from another commit or a dirty tree
# cannot be published under a tag.
#
# Usage:
#   ./scripts/release.sh <tag> [options]
#
# Options:
#   --dmg PATH        Image to publish (default: newest build/dist-*/YoPDF-*.dmg)
#   --notes-file FILE Release notes (default: GitHub-generated notes)
#   --draft           Create the release as a draft
#   --replace         Overwrite assets that already exist in the release
#   --dry-run         Verify and print the plan without uploading
#   --yes, -y         Skip the confirmation prompt
#
# The tag must exist locally and on the remote and point at the commit recorded
# in the image's build-info.txt.
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
REPLACE=0
DRY_RUN=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg) [[ $# -ge 2 ]] || fail "--dmg needs a path"; DMG="$2"; shift 2 ;;
    --notes-file | --notes) [[ $# -ge 2 ]] || fail "$1 needs a path"; NOTES="$2"; shift 2 ;;
    --draft) DRAFT=1; shift ;;
    --replace) REPLACE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) usage 0 ;;
    -*) fail "unknown option $1" ;;
    *) [[ -z "$TAG" ]] || fail "unexpected argument $1"; TAG="$1"; shift ;;
  esac
done

[[ -n "$TAG" ]] || usage 1
if [[ -n "$NOTES" && ! -f "$NOTES" ]]; then
  fail "notes file not found: $NOTES"
fi

command -v gh >/dev/null 2>&1 || fail "gh is required but not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run 'gh auth login'"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

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

# --- the image must be provably the artifact of this tag --------------------
# The commit recorded at build time is authoritative. The short SHA in the file
# name is only a label and is deliberately not trusted.
INFO_FILE="$(dirname "$DMG")/build-info.txt"
[[ -f "$INFO_FILE" ]] ||
  fail "missing $INFO_FILE; rebuild the image with scripts/package-dmg.sh"

prov() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$INFO_FILE"
}

PROV_SCHEMA="$(prov schema)"
PROV_VERSION="$(prov version)"
PROV_BUILD="$(prov build)"
PROV_COMMIT="$(prov commit)"
PROV_DIRTY="$(prov dirty)"
PROV_DMG="$(prov dmg)"
PROV_SHA="$(prov dmg-sha256)"

[[ "$PROV_SCHEMA" == "1" ]] || fail "unsupported build-info.txt schema '$PROV_SCHEMA'"
[[ "$PROV_COMMIT" =~ ^[0-9a-f]{40}$ ]] ||
  fail "build-info.txt has no full commit (got '$PROV_COMMIT'); rebuild the image"
[[ "$PROV_DIRTY" == "0" ]] ||
  fail "the image was built from a dirty working tree; commit the sources and rebuild"
[[ "$PROV_DMG" == "$(basename "$DMG")" ]] ||
  fail "build-info.txt describes '$PROV_DMG', not '$(basename "$DMG")'"

LOCAL_TAG_COMMIT="$(git rev-parse --verify --quiet "refs/tags/$TAG^{commit}")" ||
  fail "tag $TAG does not exist locally; create and push the tag first"
[[ "$LOCAL_TAG_COMMIT" == "$PROV_COMMIT" ]] ||
  fail "the image was built from ${PROV_COMMIT:0:7} but tag $TAG points at ${LOCAL_TAG_COMMIT:0:7}"

# The remote is what other people actually get; an annotated tag has to be
# peeled once more to reach its commit. gh may print API errors on stdout, so
# the exit status - not the captured text - decides whether the tag exists.
if ! REMOTE_TYPE="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.type 2>/dev/null)"; then
  fail "tag $TAG does not exist on the remote; push it first"
fi
REMOTE_SHA="$(gh api "repos/$REPO/git/ref/tags/$TAG" --jq .object.sha 2>/dev/null)" ||
  fail "cannot read remote tag $TAG"
if [[ "$REMOTE_TYPE" == "tag" ]]; then
  REMOTE_SHA="$(gh api "repos/$REPO/git/tags/$REMOTE_SHA" --jq .object.sha 2>/dev/null)" ||
    fail "cannot resolve annotated tag $TAG"
fi
[[ "$REMOTE_SHA" == "$PROV_COMMIT" ]] ||
  fail "remote tag $TAG points at ${REMOTE_SHA:0:7}, but the image was built from ${PROV_COMMIT:0:7}"
note "tag $TAG -> ${PROV_COMMIT:0:7} (image, local tag and remote tag agree)"

# --- verify the image that will actually be uploaded -----------------------
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

[[ "$VERSION" == "$PROV_VERSION" ]] ||
  fail "the app reports version $VERSION, build-info.txt reports $PROV_VERSION"
[[ "$BUILD" == "$PROV_BUILD" ]] ||
  fail "the app reports build $BUILD, build-info.txt reports $PROV_BUILD"

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

# --- checksums --------------------------------------------------------------
ACTUAL_SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
[[ "$ACTUAL_SHA" == "$PROV_SHA" ]] ||
  fail "the image hash changed after packaging; rebuild it with scripts/package-dmg.sh"

SHA_FILE="$(dirname "$DMG")/SHA256.txt"
[[ -f "$SHA_FILE" ]] || fail "missing $SHA_FILE; rerun scripts/package-dmg.sh"
read -r SHA_HASH SHA_NAME <<<"$(cut -d' ' -f1,3 "$SHA_FILE")"
[[ "$SHA_HASH" == "$ACTUAL_SHA" ]] ||
  fail "SHA256.txt does not match the image; rerun scripts/package-dmg.sh"
[[ "$SHA_NAME" == "$(basename "$DMG")" ]] ||
  fail "SHA256.txt names '$SHA_NAME', not '$(basename "$DMG")'"

# --- assets ----------------------------------------------------------------
ASSETS=("$DMG" "$SHA_FILE")

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

for asset in "${ASSETS[@]}"; do
  assert_allowed_asset "$asset"
done

note "assets to publish"
for asset in "${ASSETS[@]}"; do
  printf '  %-60s %s\n' "$(basename "$asset")" "$(du -h "$asset" | cut -f1)"
done

if gh release view "$TAG" >/dev/null 2>&1; then
  ACTION=upload
  EXISTING="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null || true)"
  EXISTING="$(printf '%s' "$EXISTING" | tr '\n' ' ')"
  COLLISION=""
  for asset in "${ASSETS[@]}"; do
    base="$(basename "$asset")"
    case " $EXISTING " in
      *" $base "*) COLLISION="$COLLISION $base" ;;
    esac
  done
  if [[ -n "$COLLISION" && "$REPLACE" != 1 ]]; then
    fail "assets already exist in release $TAG:$COLLISION; pass --replace to overwrite published binaries"
  fi
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
  GH_ARGS=(release upload "$TAG" "${ASSETS[@]}")
  if [[ "$REPLACE" == 1 ]]; then GH_ARGS+=(--clobber); fi
  if [[ -n "$NOTES" || "$DRAFT" == 1 ]]; then
    note "release $TAG already exists; --notes-file and --draft only apply to new releases"
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
