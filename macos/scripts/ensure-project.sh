#!/usr/bin/env bash
# Keep the generated Xcode project in sync with XcodeGen's inputs.
#
# XcodeGen writes an explicit file list into project.pbxproj. Adding or
# removing a source file therefore invalidates an existing .xcodeproj even
# when project.yml has not changed: a stale project builds successfully but
# silently omits the new file (for example a newly added test). Comparing a
# manifest of input paths also catches deletions, which a modification-time
# check alone would miss.
set -euo pipefail
cd "$(dirname "$0")/.."

project="YoPDF.xcodeproj/project.pbxproj"
stamp="YoPDF.xcodeproj/.yopdf-xcodegen-inputs"
inputs=(project.yml YoPDF YoPDFCore YoPDFTests YoPDFUITests)

manifest() {
  find "${inputs[@]}" -type f ! -name '.DS_Store' -print | LC_ALL=C sort
}

digest() {
  shasum -a 256 | awk '{print $1}'
}

spec_hash="$(digest < project.yml)"
inputs_hash="$(manifest | digest)"
if [[ -f "$project" ]]; then
  project_hash="$(digest < "$project")"
else
  project_hash="missing"
fi
current="$spec_hash $inputs_hash $project_hash"

if [[ ! -f "$stamp" ]] || [[ "$(<"$stamp")" != "$current" ]]; then
  echo "XcodeGen inputs changed or project missing; regenerating..."
  ./scripts/generate.sh
  mkdir -p YoPDF.xcodeproj
  # Re-read the generated project so the stamp matches what is on disk.
  project_hash="$(digest < "$project")"
  printf '%s\n' "$spec_hash $inputs_hash $project_hash" > "$stamp"
fi
