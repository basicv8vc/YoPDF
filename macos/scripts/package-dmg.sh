#!/usr/bin/env bash
# Build, sign, notarize and package a distributable YoPDF DMG.
#
# The result is a Universal (arm64 + x86_64) Release build signed with a
# Developer ID Application certificate and hardened runtime. Both the .app and
# the .dmg are notarized and stapled, so a copy dragged out of the image also
# passes Gatekeeper offline.
#
# Env:
#   SIGN_IDENTITY      Developer ID Application identity: full name or SHA-1.
#                      Default: the only Developer ID identity in the keychain;
#                      it must be unambiguous.
#   TEAM_ID            Apple Developer team ID. Default: from the identity.
#   MARKETING_VERSION  Default: MARKETING_VERSION in project.yml.
#   BUILD_NUMBER       Default: CURRENT_PROJECT_VERSION in project.yml.
#   ARCHS              Default: "arm64 x86_64".
#   VOLUME_NAME        Default: YoPDF.
#   DMG_NAME           Default: YoPDF-<version>-<build>-<sha>-universal.dmg.
#   DERIVED_DATA       Default: <repo>/macos/build/DerivedData.
#   OUT_DIR            Default: <repo>/macos/build/dist-<version>-<build>-<sha>.
#   NOTARIZE           1 (default) notarize and staple; 0 only sign and package.
#   NOTARY_TOOL        auto (default) | asc | notarytool.
#   NOTARY_PROFILE     notarytool keychain profile (default: AC_PASSWORD).
#   NOTARY_TIMEOUT     Default: 30m.
#
# Requirements: Xcode, XcodeGen, and notarization credentials:
#   - asc:        `asc auth login` (or ASC_* environment variables), or
#   - notarytool: `xcrun notarytool store-credentials <profile>`.
# Credentials stay in the keychain; nothing secret is written to the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

# Read a scalar setting from project.yml without requiring a YAML parser.
# awk is used instead of grep | head so an early exit cannot raise SIGPIPE under
# `set -o pipefail` and abort the script.
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

[[ -f project.yml ]] || fail "run from macos/ (project.yml not found)"

MARKETING="${MARKETING_VERSION:-$(yml_value MARKETING_VERSION project.yml)}"
BUILD="${BUILD_NUMBER:-$(yml_value CURRENT_PROJECT_VERSION project.yml)}"
[[ -n "$MARKETING" ]] || fail "MARKETING_VERSION is missing from project.yml"
[[ -n "$BUILD" ]] || fail "CURRENT_PROJECT_VERSION is missing from project.yml"

ARCHS="${ARCHS:-arm64 x86_64}"
VOLUME_NAME="${VOLUME_NAME:-YoPDF}"
NOTARIZE="${NOTARIZE:-1}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
DERIVED_DATA="${DERIVED_DATA:-build/DerivedData}"

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  note "working tree is dirty; the DMG will not match commit $GIT_SHA"
fi

# --- signing identity -------------------------------------------------------
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null |
  grep 'Developer ID Application' || true)"
[[ -n "$IDENTITIES" ]] ||
  fail "no Developer ID Application identity in the keychain; see macos/README.md"

REQUESTED="${SIGN_IDENTITY:-}"
if [[ -z "$REQUESTED" ]]; then
  COUNT="$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')"
  [[ "$COUNT" -eq 1 ]] ||
    { printf '%s\n' "$IDENTITIES" >&2
      fail "several Developer ID identities; set SIGN_IDENTITY to one SHA-1"; }
  IDENTITY_LINE="$IDENTITIES"
elif [[ "$REQUESTED" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  IDENTITY_LINE="$(grep -iF -m1 "$REQUESTED" <<<"$IDENTITIES" || true)"
  [[ -n "$IDENTITY_LINE" ]] || fail "no Developer ID identity with SHA-1 $REQUESTED"
else
  IDENTITY_LINE="$(grep -F -m1 "\"$REQUESTED\"" <<<"$IDENTITIES" || true)"
  [[ -n "$IDENTITY_LINE" ]] || fail "no Developer ID identity named '$REQUESTED'"
  MATCHES="$(grep -cF "\"$REQUESTED\"" <<<"$IDENTITIES" || true)"
  [[ "$MATCHES" -eq 1 ]] ||
    { printf '%s\n' "$IDENTITIES" >&2
      fail "'$REQUESTED' matches $MATCHES identities; use a SHA-1 instead"; }
fi

IDENTITY_HASH="$(printf '%s\n' "$IDENTITY_LINE" | awk '{print $2}')"
IDENTITY_NAME="$(printf '%s\n' "$IDENTITY_LINE" | sed -n 's/.*"\(.*\)".*/\1/p')"
TEAM="${TEAM_ID:-$(printf '%s' "$IDENTITY_NAME" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"
[[ -n "$TEAM" ]] || fail "cannot derive TEAM_ID from '$IDENTITY_NAME'; set TEAM_ID"

# --- notarization tool ------------------------------------------------------
if [[ "$NOTARIZE" == "1" && -z "${NOTARY_TOOL:-}" ]]; then
  ASC_STATUS=""
  if command -v asc >/dev/null 2>&1; then
    ASC_STATUS="$(asc auth status 2>/dev/null || true)"
  fi
  if grep -Eq '"credentials"[[:space:]]*:[[:space:]]*\[\{' <<<"$ASC_STATUS"; then
    NOTARY_TOOL=asc
  else
    NOTARY_TOOL=notarytool
  fi
fi
NOTARY_TOOL="${NOTARY_TOOL:-none}"
if [[ "$NOTARIZE" == "1" && "$NOTARY_TOOL" == "none" ]]; then
  fail "NOTARIZE=1 requires NOTARY_TOOL=asc or notarytool"
fi
case "$NOTARY_TOOL" in
  asc) command -v asc >/dev/null || fail "NOTARY_TOOL=asc but asc is not installed" ;;
  notarytool | none) ;;
  *) fail "unsupported NOTARY_TOOL '$NOTARY_TOOL' (use asc or notarytool)" ;;
esac

# --- output paths -----------------------------------------------------------
OUT_DIR="${OUT_DIR:-build/dist-${MARKETING}-${BUILD}-${GIT_SHA}}"
DMG_NAME="${DMG_NAME:-YoPDF-${MARKETING}-${BUILD}-${GIT_SHA}-universal.dmg}"
ARCHIVE="$OUT_DIR/YoPDF.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
APP="$EXPORT_DIR/YoPDF.app"
DMG="$OUT_DIR/$DMG_NAME"
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/yopdf-pkg.XXXXXX")"
MNT="$TMP_DIR/mnt"
MNT_CHECK="$TMP_DIR/mnt-check"
cleanup() {
  [[ -d "$MNT" ]] && hdiutil detach "$MNT" >/dev/null 2>&1 || true
  [[ -d "$MNT_CHECK" ]] && hdiutil detach "$MNT_CHECK" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

note "YoPDF $MARKETING ($BUILD) from $GIT_SHA"
note "identity: $IDENTITY_NAME [$IDENTITY_HASH], team $TEAM"
note "arches: $ARCHS; notarization: $([[ "$NOTARIZE" == 1 ]] && echo "$NOTARY_TOOL" || echo skipped)"
note "output: $OUT_DIR"

# --- archive ----------------------------------------------------------------
if [[ ! -d YoPDF.xcodeproj || project.yml -nt YoPDF.xcodeproj/project.pbxproj ]]; then
  note "generating YoPDF.xcodeproj"
  ./scripts/generate.sh
fi

note "archiving"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
  -project YoPDF.xcodeproj \
  -scheme YoPDF \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$DERIVED_DATA" \
  "ARCHS=$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$MARKETING" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$IDENTITY_HASH" \
  DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  archive >"$OUT_DIR/archive.log" 2>&1 ||
  { tail -40 "$OUT_DIR/archive.log" >&2; fail "archive failed; see $OUT_DIR/archive.log"; }

# --- export with Developer ID ----------------------------------------------
cat >"$OUT_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingCertificate</key>
    <string>$IDENTITY_HASH</string>
</dict>
</plist>
PLIST

note "exporting Developer ID build"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" \
  >"$OUT_DIR/export.log" 2>&1 ||
  { tail -40 "$OUT_DIR/export.log" >&2; fail "export failed; see $OUT_DIR/export.log"; }
[[ -d "$APP" ]] || fail "export did not produce $APP"

# --- notarize and staple the app -------------------------------------------
notarize() { # $1 file, $2 label
  local file="$1" label="$2" json="$OUT_DIR/notarize-$2.json" id
  local err="$OUT_DIR/notarize-$2.err"
  if [[ "$NOTARIZE" != "1" ]]; then
    note "skipping notarization for $label"
    return 0
  fi
  note "notarizing $label ($(basename "$file"))"
  case "$NOTARY_TOOL" in
    asc)
      asc notarization submit --file "$file" --wait --timeout "$NOTARY_TIMEOUT" \
        >"$json" 2>"$err" ||
        { cat "$json" "$err" >&2; fail "notarization submission failed for $label"; }
      ;;
    notarytool)
      xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" \
        --wait --timeout "$NOTARY_TIMEOUT" --output-format json >"$json" 2>"$err" ||
        { cat "$json" "$err" >&2
          fail "notarization submission failed for $label (check the '$NOTARY_PROFILE' profile)"; }
      ;;
  esac
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$json" ||
    { cat "$json" "$err" >&2; fail "notarization was not accepted for $label"; }
  id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json")"
  id="${id%%$'\n'*}"
  note "notarization accepted for $label${id:+ ($id)}"
}

staple() { # $1 item
  [[ "$NOTARIZE" == "1" ]] || return 0
  xcrun stapler staple "$1" >/dev/null || fail "stapling failed for $1"
  xcrun stapler validate "$1" >/dev/null || fail "staple validation failed for $1"
}

if [[ "$NOTARIZE" == "1" ]]; then
  ditto -c -k --keepParent --zlibCompressionLevel 9 "$APP" "$TMP_DIR/app.zip"
  notarize "$TMP_DIR/app.zip" app
  note "stapling the app"
  staple "$APP"
fi

# --- build the disk image ---------------------------------------------------
# hdiutil create -srcfolder is avoided on purpose: on some hosts it fails with
# "Operation not permitted" while copy-helper writes a signed bundle into the
# new volume. Mounting a read-write image and copying explicitly is equivalent.
APP_MB="$(du -sm "$APP" | cut -f1)"
note "creating $DMG_NAME"
hdiutil create -volname "$VOLUME_NAME" -size "$((APP_MB + 64))m" -fs HFS+ \
  -ov "$TMP_DIR/rw.dmg" >/dev/null
mkdir -p "$MNT"
hdiutil attach -nobrowse -noautoopen -mountpoint "$MNT" "$TMP_DIR/rw.dmg" >/dev/null
ditto "$APP" "$MNT/YoPDF.app"
ln -s /Applications "$MNT/Applications"
sync
hdiutil detach "$MNT" >/dev/null
rmdir "$MNT"
hdiutil convert "$TMP_DIR/rw.dmg" -format UDZO -imagekey zlib-level=9 \
  -o "$TMP_DIR/final.dmg" >/dev/null
cp "$TMP_DIR/final.dmg" "$DMG"

note "signing the disk image"
codesign --force --sign "$IDENTITY_HASH" --timestamp "$DMG"

if [[ "$NOTARIZE" == "1" ]]; then
  notarize "$DMG" dmg
  note "stapling the disk image"
  staple "$DMG"
fi

# --- verification -----------------------------------------------------------
note "verifying"

codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null 2>&1 ||
  fail "code signature verification failed for the app"

BINARY="$APP/Contents/MacOS/YoPDF"
BUILT_ARCHS="$(lipo -archs "$BINARY")"
for arch in $ARCHS; do
  case " $BUILT_ARCHS " in
    *" $arch "*) ;;
    *) fail "missing architecture $arch (built: $BUILT_ARCHS)" ;;
  esac
done

codesign -dvv "$APP" >"$TMP_DIR/codesign.txt" 2>&1 || true
grep -q 'flags=.*runtime' "$TMP_DIR/codesign.txt" ||
  fail "the app is not signed with the hardened runtime"

codesign -d --entitlements - "$APP" >"$TMP_DIR/entitlements.txt" 2>/dev/null || true
if grep -q 'get-task-allow' "$TMP_DIR/entitlements.txt"; then
  fail "the app carries the debug get-task-allow entitlement"
fi

PLIST_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$PLIST_BUILD" == "$BUILD" ]] ||
  fail "CFBundleVersion is $PLIST_BUILD, expected $BUILD"
[[ "$PLIST_VERSION" == "$MARKETING" ]] ||
  fail "CFBundleShortVersionString is $PLIST_VERSION, expected $MARKETING"

if [[ "$NOTARIZE" == "1" ]]; then
  xcrun stapler validate "$APP" >/dev/null || fail "the app staple is missing"
  xcrun stapler validate "$DMG" >/dev/null || fail "the disk image staple is missing"

  spctl -a -vvv -t open --context context:primary-signature "$DMG" \
    >"$TMP_DIR/spctl-dmg.txt" 2>&1 || true
  grep -q 'Notarized Developer ID' "$TMP_DIR/spctl-dmg.txt" ||
    { cat "$TMP_DIR/spctl-dmg.txt" >&2; fail "Gatekeeper rejects the disk image"; }

  mkdir -p "$MNT_CHECK"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT_CHECK" "$DMG" >/dev/null
  cp -R "$MNT_CHECK/YoPDF.app" "$TMP_DIR/dmg-copy.app"
  hdiutil detach "$MNT_CHECK" >/dev/null
  rmdir "$MNT_CHECK"
  # A quarantined copy outside the image must pass on its own stapled ticket.
  xattr -w com.apple.quarantine "0081;00000000;Safari;" "$TMP_DIR/dmg-copy.app"
  spctl -a -vvv -t exec "$TMP_DIR/dmg-copy.app" \
    >"$TMP_DIR/spctl-app.txt" 2>&1 || true
  grep -q 'Notarized Developer ID' "$TMP_DIR/spctl-app.txt" ||
    { cat "$TMP_DIR/spctl-app.txt" >&2
      fail "a copy extracted from the disk image is rejected by Gatekeeper"; }
fi

( cd "$OUT_DIR" && shasum -a 256 "$DMG_NAME" | tee SHA256.txt )

note "done"
printf '  app:     %s\n  dmg:     %s\n  sha256:  %s\n  logs:    %s\n' \
  "$APP" "$DMG" "$(cut -d' ' -f1 "$OUT_DIR/SHA256.txt")" "$OUT_DIR"
