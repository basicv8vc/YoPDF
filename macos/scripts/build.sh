#!/usr/bin/env bash
# Build the YoPDF macOS app.
#
# Env:
#   CONFIGURATION  Debug (default) | Release
#   DESTINATION    xcodebuild destination (default: platform=macOS,arch=arm64)
#   DERIVED_DATA   derived data path (default: <repo>/macos/build/DerivedData)
#
# Derived data is kept inside the repo so builds are reproducible, easy to
# inspect, and do not depend on a global ~/Library/Developer/Xcode state.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${CONFIGURATION:-Debug}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA="${DERIVED_DATA:-build/DerivedData}"

xcodebuild \
  -project YoPDF.xcodeproj \
  -scheme YoPDF \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build
