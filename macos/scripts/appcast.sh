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
#   ./scripts/appcast.sh <dist-dir> [--notes-file <file>]
#   ./scripts/appcast.sh --tag <tag> [--notes-file <file>]
#
# Release notes are embedded into the signed appcast <description> from (in order):
#   1. --notes-file <file> (HTML, plain text, or Markdown; must be non-empty)
#   2. A matching sidecar file in <dist-dir> (YoPDF-*.{html,txt,md,markdown})
#   3. The GitHub Release body for v<version> (Markdown), falling back to a
#      default summary if the release body is unavailable or empty
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

usage() {
  local code="${1:-0}" out="/dev/stdout"
  if [[ "$code" != 0 ]]; then out="/dev/stderr"; fi
  awk 'NR == 1 { next } /^set -euo/ { exit } { sub(/^# ?/, ""); print }' "$0" >"$out"
  exit "$code"
}

DIST=""
TAG=""
NOTES_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file | --notes)
      [[ $# -ge 2 ]] || fail "$1 needs a path"
      NOTES_FILE="$2"
      shift 2
      ;;
    --tag)
      [[ $# -ge 2 ]] || fail "$1 needs a release tag"
      TAG="$2"
      shift 2
      ;;
    -h | --help) usage 0 ;;
    -*) fail "unknown option $1" ;;
    *)
      [[ -z "$DIST" ]] || fail "unexpected argument $1"
      DIST="$1"
      shift
      ;;
  esac
done

if [[ -n "$DIST" && -n "$TAG" ]]; then
  fail "pass either <dist-dir> or --tag <tag>, not both"
fi
[[ -n "$DIST" || -n "$TAG" ]] || fail "usage: $0 <dist-dir> [--notes-file <file>] (or --tag <tag>)"
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || fail "notes file not found: $NOTES_FILE"

prov() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$2"
}

if [[ -n "$DIST" ]]; then
  info="$DIST/build-info.txt"
  [[ -f "$info" ]] || fail "missing $info; run scripts/package-dmg.sh first"
  VERSION="$(prov version "$info")"
  BUILD="$(prov build "$info")"
  DMG_NAME="$(prov dmg "$info")"
  [[ -n "$VERSION" && -n "$BUILD" && -n "$DMG_NAME" ]] ||
    fail "$info is missing version, build or dmg"
  [[ -f "$DIST/$DMG_NAME" ]] || fail "missing $DIST/$DMG_NAME"
  TAG="v$VERSION"
fi

TOOL="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$TOOL" ]]; then
  TOOL="$(find build -type f \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -1)"
fi
[[ -n "$TOOL" && -x "$TOOL" ]] ||
  fail "generate_appcast not found; run scripts/build.sh once to fetch the Sparkle tools"

command -v gh >/dev/null 2>&1 || fail "gh is required but not installed"
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner </dev/null)"

# A feed that points at an asset nobody can download is worse than no feed, so
# the enclosure target is checked against the release instead of assumed.
ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' </dev/null 2>/dev/null)" ||
  fail "release $TAG does not exist; run scripts/release.sh $TAG first"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/yopdf-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ -n "$DIST" ]]; then
  grep -qxF "$DMG_NAME" <<<"$ASSETS" ||
    fail "release $TAG has no asset named $DMG_NAME; publish the image first"
  cp "$DIST/$DMG_NAME" "$STAGE/"
else
  DMG_MATCHES="$(grep -E '^YoPDF-.*\.dmg$' <<<"$ASSETS" || true)"
  DMG_COUNT="$(printf '%s\n' "$DMG_MATCHES" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$DMG_COUNT" -eq 1 ]] ||
    fail "expected exactly one YoPDF-*.dmg asset in release $TAG (found $DMG_COUNT)"
  DMG_NAME="$DMG_MATCHES"
  note "downloading $DMG_NAME from $TAG"
  gh release download "$TAG" --pattern "$DMG_NAME" --dir "$STAGE" </dev/null
  [[ -f "$STAGE/$DMG_NAME" ]] || fail "failed to download $DMG_NAME from release $TAG"
  VERSION="${TAG#v}"
  if [[ "$DMG_NAME" =~ ^YoPDF-(.+)-build([0-9]+)- ]]; then
    VERSION="${BASH_REMATCH[1]}"
    BUILD="${BASH_REMATCH[2]}"
  else
    BUILD="unknown"
  fi
fi

# generate_appcast merges into an existing feed. Seeding it keeps older
# versions listed, which is what a client on an older build needs.
if [[ -f "$FEED" ]]; then cp "$FEED" "$STAGE/appcast.xml"; fi

DMG_BASE="${DMG_NAME%.dmg}"
stage_notes_file() {
  local src="$1" ext="$2" dest="$STAGE/$DMG_BASE.$2"
  grep -q '[^[:space:]]' "$src" || return 1
  if [[ "$ext" == "html" ]]; then
    cp "$src" "$dest"
  else
    tr -d '\r' <"$src" >"$dest"
  fi
}

STAGED_NOTES=0
if [[ -n "$NOTES_FILE" ]]; then
  notes_ext="md"
  case "${NOTES_FILE##*.}" in
    [Hh][Tt][Mm][Ll] | [Hh][Tt][Mm]) notes_ext="html" ;;
    [Tt][Xx][Tt]) notes_ext="txt" ;;
  esac
  stage_notes_file "$NOTES_FILE" "$notes_ext" ||
    fail "notes file is empty: $NOTES_FILE"
  STAGED_NOTES=1
else
  if [[ -n "$DIST" ]]; then
    for ext in html txt md markdown; do
      if [[ -f "$DIST/$DMG_BASE.$ext" ]] && stage_notes_file "$DIST/$DMG_BASE.$ext" "$ext"; then
        STAGED_NOTES=1
        break
      fi
    done
  fi
  if [[ "$STAGED_NOTES" -eq 0 ]]; then
    NOTES_BODY=""
    NOTES_FETCHED=1
    if ! NOTES_BODY="$(gh release view "$TAG" --json body --jq '.body // ""' </dev/null)"; then
      NOTES_FETCHED=0
      note "warning: failed to fetch release notes for $TAG; using default description"
    else
      NOTES_BODY="$(tr -d '\r' <<<"$NOTES_BODY")"
    fi
    if grep -q '[^[:space:]]' <<<"$NOTES_BODY"; then
      printf '%s\n' "$NOTES_BODY" >"$STAGE/$DMG_BASE.md"
    else
      if [[ "$NOTES_FETCHED" -eq 1 ]]; then
        note "warning: release $TAG has no release notes; using default description"
      fi
      printf 'YoPDF %s — Bug fixes and improvements.\n' "$VERSION" >"$STAGE/$DMG_BASE.md"
    fi
    STAGED_NOTES=1
  fi
fi

note "signing $DMG_NAME for $TAG"
# bash 3.2 treats "${arr[@]}" on an empty array as unbound under `set -u`, so
# the two invocations are spelled out instead of building an argument array.
# --embed-release-notes puts Markdown/plain-text/HTML notes directly into the
# signed appcast <description>, because release.sh only uploads the DMG and SHA256.
FEED_URL_PREFIX="https://github.com/$REPO/releases/download/$TAG/"
LINK_URL="https://github.com/$REPO/releases"
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  "$TOOL" --ed-key-file "$SPARKLE_ED_KEY_FILE" \
    --embed-release-notes \
    --download-url-prefix "$FEED_URL_PREFIX" --link "$LINK_URL" \
    "$STAGE" >/dev/null
else
  "$TOOL" \
    --embed-release-notes \
    --download-url-prefix "$FEED_URL_PREFIX" --link "$LINK_URL" \
    "$STAGE" >/dev/null
fi

cp "$STAGE/appcast.xml" "$FEED"

note "wrote appcast.xml for $VERSION ($BUILD)"
printf '  feed: %s\n' "https://raw.githubusercontent.com/$REPO/main/appcast.xml"
printf '  publish it with: git add appcast.xml && git commit && git push\n'
