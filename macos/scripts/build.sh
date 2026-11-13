#!/usr/bin/env bash
# Build the YoPDF macOS app.
#
# Env:
#   CONFIGURATION  Debug (default) | Release
#   DESTINATION    xcodebuild destination (default: platform=macOS,arch=arm64)
#   DERIVED_DATA   derived data path (default: <repo>/macos/build/DerivedData)
#   SPARKLE_FEED_URL       HTTPS Sparkle appcast URL (optional)
#   SPARKLE_PUBLIC_ED_KEY  Base64 Sparkle EdDSA public key (optional)
#
# Derived data is kept inside the repo so builds are reproducible, easy to
# inspect, and do not depend on a global ~/Library/Developer/Xcode state.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/ensure-project.sh

CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA="${DERIVED_DATA:-build/DerivedData}"
SPARKLE_BUILD_SETTINGS=()

if [[ -n "${SPARKLE_FEED_URL:-}" ]]; then
  SPARKLE_BUILD_SETTINGS+=("SPARKLE_FEED_URL=$SPARKLE_FEED_URL")
fi
if [[ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
  SPARKLE_BUILD_SETTINGS+=("SPARKLE_PUBLIC_ED_KEY=$SPARKLE_PUBLIC_ED_KEY")
fi

# Workaround: with Xcode 27.2 on this machine, swiftc's internal seatbelt
# sandbox fails to apply ("sandbox-exec: sandbox_apply: Operation not
# permitted"), which breaks the macro plugin server and makes every SwiftUI
# macro (@State, etc.) fail with "swift-plugin-server produced malformed
# response". Disabling the compiler's subprocess sandbox restores macros.
# Disable this override with DISABLE_SWIFT_SANDBOX_WORKAROUND=1.
if [[ "${DISABLE_SWIFT_SANDBOX_WORKAROUND:-0}" != "1" ]]; then
  SWIFT_SANDBOX_WORKAROUND=(OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox')
else
  SWIFT_SANDBOX_WORKAROUND=()
fi

xcodebuild \
  -project YoPDF.xcodeproj \
  -scheme YoPDF \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SPARKLE_BUILD_SETTINGS[@]}" \
  "${SWIFT_SANDBOX_WORKAROUND[@]}" \
  build
