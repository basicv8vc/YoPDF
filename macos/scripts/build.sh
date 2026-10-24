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

if [[ ! -d YoPDF.xcodeproj || project.yml -nt YoPDF.xcodeproj/project.pbxproj ]]; then
  echo "project.yml changed or project missing; regenerating..."
  ./scripts/generate.sh
fi

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

xcodebuild \
  -project YoPDF.xcodeproj \
  -scheme YoPDF \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${SPARKLE_BUILD_SETTINGS[@]}" \
  build
