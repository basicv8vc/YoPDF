#!/usr/bin/env bash
# Run macOS GUI regression tests. This requires a logged-in Aqua session.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -d YoPDF.xcodeproj || project.yml -nt YoPDF.xcodeproj/project.pbxproj ]]; then
  echo "project.yml changed or project missing; regenerating..."
  ./scripts/generate.sh
fi

DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA="${DERIVED_DATA:-build/UITestDerivedData}"

xcodebuild \
  -project YoPDF.xcodeproj \
  -scheme YoPDF \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -parallel-testing-enabled NO \
  -only-testing:YoPDFUITests \
  test
