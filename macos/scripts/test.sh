#!/usr/bin/env bash
# Run the YoPDF unit tests.
#
# Env:
#   DESTINATION     xcodebuild destination (default: platform=macOS,arch=arm64)
#   DERIVED_DATA    derived data path (default: <repo>/macos/build/TestDerivedData)
#   XCODEBUILD_TEST set to 1 to use `xcodebuild test` instead of the direct runner
#
# Tests are logic tests: they link YoPDFCore and never launch the app, so no GUI
# session, window server, or accessibility permission is required.
#
# By default the script builds with `xcodebuild build-for-testing` and then runs
# the bundle with Apple's `xctest` CLI. Reason: with Xcode 26.3 / macOS 26.5.1,
# `xcodebuild test` / `test-without-building` intermittently fails right after a
# fresh build with
#   "Failed to create a bundle instance representing .../YoPDFTests.xctest"
# even though the bundle exists, is signed, and the same tests pass through
# `xcrun xctest` in the same second. The direct runner bypasses testmanagerd and
# has been stable across repeated runs. Set XCODEBUILD_TEST=1 when you need an
# .xcresult bundle or code coverage.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d YoPDF.xcodeproj || project.yml -nt YoPDF.xcodeproj/project.pbxproj ]]; then
  echo "project.yml changed or project missing; regenerating..."
  ./scripts/generate.sh
fi

DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA="${DERIVED_DATA:-build/TestDerivedData}"

common=(
  -project YoPDF.xcodeproj
  -scheme YoPDF
  -configuration Debug
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA"
)

xcodebuild "${common[@]}" build-for-testing

if [[ "${XCODEBUILD_TEST:-0}" == "1" ]]; then
  xcodebuild "${common[@]}" test-without-building
  exit $?
fi

bundle="$DERIVED_DATA/Build/Products/Debug/YoPDFTests.xctest"
if [[ ! -d "$bundle" ]]; then
  echo "error: test bundle not found at $bundle" >&2
  exit 1
fi

xcrun xctest "$bundle"
