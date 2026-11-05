#!/usr/bin/env bash
# Cut a YoPDF release end to end.
#
# Every step in here exists because the manual sequence failed at least once.
# The checks are deliberately hard failures instead of warnings, because the
# expensive mistakes (a dirty image, a wrong asset, a stale feed) are otherwise
# only discovered after notarization has already run twice.
#
# The steps: preflight -> package -> tag -> publish -> refresh the feed.
#
# Usage:
#   ./scripts/release-all.sh [options]
#
# Options:
#   --draft             Create the GitHub release as a draft
#   --notes-file FILE   Release notes (default: GitHub-generated notes)
#   --dry-run           Run every check, print the plan, publish nothing
#   --resume            Continue after a partial run: allow the tag to already
#                       exist at HEAD and replace assets already uploaded
#   --yes, -y           Do not stop for confirmation before publishing
#
# Env:
#   SIGN_IDENTITY   Developer ID Application identity (name or SHA-1). Required
#                   when the keychain holds more than one.
#   TEAM_ID, ARCHS, NOTARIZE, NOTARY_TOOL, NOTARY_PROFILE, VOLUME_NAME,
#   SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY, DERIVED_DATA
#                   Forwarded to scripts/package-dmg.sh.
#   SPARKLE_ED_KEY_FILE
#                   Private EdDSA key for the feed. Defaults to reading it from
#                   the login Keychain through `security`, which is the only
#                   reader the Keychain ACL actually allows without a prompt.
#
# Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml and commit
# that before running. The tag is derived from the version, and an existing tag
# is refused, so a forgotten bump cannot silently re-publish a version.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(cd .. && pwd)"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
phase() { printf '\n### %s\n' "$*"; }

usage() {
  local code="${1:-0}" out="/dev/stdout"
  if [[ "$code" != 0 ]]; then out="/dev/stderr"; fi
  awk 'NR == 1 { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "$0" >"$out"
  exit "$code"
}

yml_value() {
  awk -v key="$1" '
    $1 == key ":" {
      sub(/^[^:]*:[ \t]*/, "")
      sub(/[ \t]*#.*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' "$2"
}

DRAFT=0
NOTES=""
DRY_RUN=0
RESUME=0
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --draft) DRAFT=1; shift ;;
    --notes-file | --notes) [[ $# -ge 2 ]] || fail "$1 needs a path"; NOTES="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --resume) RESUME=1; shift ;;
    --yes | -y) ASSUME_YES=1; shift ;;
    -h | --help) usage 0 ;;
    *) fail "unknown option $1" ;;
  esac
done

[[ -z "$NOTES" || -f "$NOTES" ]] || fail "notes file not found: $NOTES"

# --- preflight --------------------------------------------------------------
# Everything below runs before a single byte is compiled, so an avoidable
# mistake costs seconds instead of two rounds of notarization.
phase "preflight"

command -v gh >/dev/null 2>&1 || fail "gh is required but not installed"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run 'gh auth login'"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required but not installed"

git -C "$REPO_ROOT" fetch --quiet origin main || fail "cannot fetch origin/main"

BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "releases are cut from main; this checkout is on '$BRANCH'"

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$REPO_ROOT" rev-parse origin/main)"
[[ "$HEAD_SHA" == "$REMOTE_SHA" ]] ||
  fail "main is not pushed: HEAD is ${HEAD_SHA:0:7}, origin/main is ${REMOTE_SHA:0:7}"

# A dirty tree is recorded in build-info.txt and makes the image unpublishable,
# which is only discovered after the archive and both notarizations.
DIRTY="$(git -C "$REPO_ROOT" status --porcelain)"
if [[ -n "$DIRTY" ]]; then
  printf '%s\n' "$DIRTY" >&2
  if grep -q 'macos/Config/Info.plist' <<<"$DIRTY"; then
    fail "Config/Info.plist is generated from project.yml; commit the regenerated file before releasing"
  fi
  fail "the working tree is dirty; a release build must record a clean commit"
fi

VERSION="$(yml_value MARKETING_VERSION project.yml)"
BUILD="$(yml_value CURRENT_PROJECT_VERSION project.yml)"
[[ -n "$VERSION" && -n "$BUILD" ]] ||
  fail "MARKETING_VERSION or CURRENT_PROJECT_VERSION is missing from project.yml"
TAG="v$VERSION"

# The tag is derived from the version, so an existing tag means the version was
# not bumped. That is a refusal, not a prompt: re-publishing over a tag other
# people may already have is never the right answer.
if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  if [[ "$RESUME" == 1 ]]; then
    TAG_SHA="$(git -C "$REPO_ROOT" rev-parse "refs/tags/$TAG^{commit}")"
    [[ "$TAG_SHA" == "$HEAD_SHA" ]] ||
      fail "tag $TAG points at ${TAG_SHA:0:7}, not HEAD (${HEAD_SHA:0:7}); --resume cannot help"
    note "resuming: tag $TAG already points at HEAD"
  else
    fail "tag $TAG already exists; bump MARKETING_VERSION in project.yml and commit it"
  fi
fi

IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null |
  grep 'Developer ID Application' || true)"
[[ -n "$IDENTITIES" ]] ||
  fail "no Developer ID Application identity in the keychain; see macos/README.md"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  COUNT="$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')"
  if [[ "$COUNT" -ne 1 ]]; then
    printf '%s\n' "$IDENTITIES" >&2
    fail "several Developer ID identities; set SIGN_IDENTITY to one SHA-1"
  fi
fi

# The Sparkle tools hang forever when the Keychain ACL blocks them, so the key
# is fetched here and piped in later. Failing now beats freezing at step five.
KEY_FROM_KEYCHAIN=0
if [[ -z "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  security find-generic-password -a ed25519 -s "https://sparkle-project.org" -w \
    >/dev/null 2>&1 ||
    fail "no Sparkle EdDSA key in the Keychain; set SPARKLE_ED_KEY_FILE or import one"
  KEY_FROM_KEYCHAIN=1
fi

OUT_DIR="build/dist-$VERSION-$BUILD-$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD)"
DMG_NAME="YoPDF-$VERSION-build$BUILD-universal.dmg"

note "version $VERSION (build $BUILD) from ${HEAD_SHA:0:7} on main"
note "tag $TAG, output $OUT_DIR"
note "notarization: $([[ "${NOTARIZE:-1}" == 1 ]] && echo yes || echo skipped); draft: $([[ "$DRAFT" == 1 ]] && echo yes || echo no)"

if [[ "$DRY_RUN" == 1 ]]; then
  note "dry run: would package, tag, publish and refresh appcast.xml"
  exit 0
fi

if [[ "$ASSUME_YES" == 0 ]]; then
  if ! read -r -p "Package and publish $TAG? [y/N] " answer; then fail "aborted"; fi
  [[ "$answer" == [yY] ]] || fail "aborted"
fi

# --- package ----------------------------------------------------------------
# Regenerate first. XcodeGen rewrites the tracked Config/Info.plist whenever
# project.yml changes, and packaging before committing that file produces a
# dirty image that release.sh rejects minutes later.
phase "generate project"
./scripts/ensure-project.sh
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  git -C "$REPO_ROOT" status --porcelain >&2
  fail "generating the project changed tracked files; commit them and run again"
fi

phase "package"
# package-dmg.sh clears its output directory with rm -rf, which a delete guard
# can block halfway through. Move a previous run aside instead of deleting it.
if [[ -d "$OUT_DIR" ]]; then
  ARCHIVE_OLD="${TMPDIR:-/tmp}/yopdf-superseded-$VERSION-$BUILD-$(date +%s)"
  mv "$OUT_DIR" "$ARCHIVE_OLD"
  note "previous output moved to $ARCHIVE_OLD"
fi
./scripts/package-dmg.sh

DMG="$OUT_DIR/$DMG_NAME"
[[ -f "$DMG" ]] || fail "package-dmg.sh did not produce $DMG"

# --- tag --------------------------------------------------------------------
# Pushed before the release so release.sh can prove the image matches a tag
# other people can see, not just a local one.
phase "tag $TAG"
if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null; then
  note "tag already present, not recreated"
else
  git -C "$REPO_ROOT" tag "$TAG" "$HEAD_SHA"
  git -C "$REPO_ROOT" push origin "refs/tags/$TAG" ||
    fail "cannot push tag $TAG"
fi

# --- publish ----------------------------------------------------------------
phase "publish"
RELEASE_ARGS=("$TAG" --dmg "$DMG" --yes)
if [[ -n "$NOTES" ]]; then RELEASE_ARGS+=(--notes-file "$NOTES"); fi
if [[ "$DRAFT" == 1 ]]; then RELEASE_ARGS+=(--draft); fi
# --replace only exists to finish an interrupted run; a fresh tag never
# collides, so colliding assets here mean the previous attempt uploaded them.
if [[ "$RESUME" == 1 ]]; then RELEASE_ARGS+=(--replace); fi
RELEASE_URL="$(./scripts/release.sh "${RELEASE_ARGS[@]}" | tail -1)"

# --- feed -------------------------------------------------------------------
# The feed points at the release asset, so it has to be written after the
# upload. It is committed and pushed right away: a feed that exists only in the
# working tree leaves every installed copy checking a stale file.
phase "appcast"
if [[ "$KEY_FROM_KEYCHAIN" == 1 ]]; then
  security find-generic-password -a ed25519 -s "https://sparkle-project.org" -w |
    SPARKLE_ED_KEY_FILE=- ./scripts/appcast.sh "$OUT_DIR"
else
  ./scripts/appcast.sh "$OUT_DIR"
fi

git -C "$REPO_ROOT" add appcast.xml
git -C "$REPO_ROOT" commit -q -m "chore: publish appcast for $VERSION"
git -C "$REPO_ROOT" push origin main || fail "cannot push appcast.xml"

if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  git -C "$REPO_ROOT" status --porcelain >&2
  fail "the working tree is dirty after publishing; check appcast.xml"
fi

printf '\n'
note "released $TAG"
printf '  release: %s\n' "$RELEASE_URL"
printf '  dmg:     %s/%s\n' "$OUT_DIR" "$DMG_NAME"
printf '  feed:    %s\n' "https://raw.githubusercontent.com/$(gh repo view --json nameWithOwner --jq .nameWithOwner)/main/appcast.xml"
