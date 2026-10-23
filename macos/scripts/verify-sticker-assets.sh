#!/usr/bin/env bash
# Verify the sticker artwork that YoPDF ships.
#
# Usage:
#   macos/scripts/verify-sticker-assets.sh [path/to/YoPDF.app]
#
# Defaults to the Debug build produced by macos/scripts/build.sh. Checks:
#   1. STICKER_ASSETS_MANIFEST.md lists exactly 20 assets and every source PNG
#      still matches its SHA-256.
#   2. The source Asset Catalog has exactly the 20 expected imagesets.
#   3. The built app's Assets.car contains exactly those 20 names, 256x256 with
#      alpha, and no loose PNGs or original-resolution artwork.
#   4. AppKit can actually load every asset from the built application bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/DerivedData/Build/Products/Debug/YoPDF.app}"
MANIFEST="$ROOT/../STICKER_ASSETS_MANIFEST.md"
CATALOG="$ROOT/YoPDF/Resources/Assets.xcassets"

fail() { echo "error: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "app bundle not found: $APP"
[[ -f "$MANIFEST" ]] || fail "manifest not found: $MANIFEST"
[[ -d "$CATALOG" ]] || fail "asset catalog not found: $CATALOG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. Manifest hashes and inventory.
python3 - "$ROOT" "$MANIFEST" > "$TMP/expected.tsv" <<'PY'
import hashlib, pathlib, sys

repo = pathlib.Path(sys.argv[1]).parent
manifest = pathlib.Path(sys.argv[2])
rows = []
for raw in manifest.read_text().splitlines():
    if not raw.startswith("| `"):
        continue
    cells = [cell.strip() for cell in raw.strip().strip("|").split("|")]
    if len(cells) != 6:
        continue
    motif, _collection, _title, asset, path, digest = cells
    sha = digest.strip("`")
    if len(sha) != 64:
        continue
    rows.append((motif.strip("`"), asset.strip("`"), path.strip("`"), sha))

if len(rows) != 20:
    sys.exit(f"expected 20 manifest rows, found {len(rows)}")

for motif, asset, relative, expected in rows:
    file = repo / relative
    if not file.is_file():
        sys.exit(f"missing source asset for {motif}: {relative}")
    actual = hashlib.sha256(file.read_bytes()).hexdigest()
    if actual != expected:
        sys.exit(f"hash mismatch for {motif}: {actual} != {expected}")
    print(f"{motif}\t{asset}\t{actual}")
PY

echo "manifest: $(wc -l < "$TMP/expected.tsv" | tr -d ' ') assets, all SHA-256 hashes match"

# 2. Exactly the expected twenty imagesets and no extras.
EXPECTED_NAMES="$(cut -f2 "$TMP/expected.tsv" | sort)"
CATALOG_NAMES="$(find "$CATALOG" -maxdepth 1 -name 'PDFSticker*.imageset' -type d | while read -r directory; do
  basename "$directory" .imageset
done | sort)"
CATALOG_COUNT="$(printf '%s\n' "$CATALOG_NAMES" | wc -l | tr -d ' ')"
[[ "$CATALOG_COUNT" == "20" ]] || fail "expected 20 imagesets in the catalog, found $CATALOG_COUNT"
[[ "$CATALOG_NAMES" == "$EXPECTED_NAMES" ]] || fail "catalog imagesets do not match the manifest"

while IFS=$'\t' read -r _motif name _sha; do
  [[ -f "$CATALOG/$name.imageset/sticker.png" ]] || fail "$name has no sticker.png"
  [[ -f "$CATALOG/$name.imageset/Contents.json" ]] || fail "$name has no Contents.json"
done < "$TMP/expected.tsv"

echo "catalog: 20 imagesets, each with sticker.png and Contents.json"

# 3. Built bundle contents.
CAR="$APP/Contents/Resources/Assets.car"
[[ -f "$CAR" ]] || fail "Assets.car not found in $APP"

if find "$APP" \( -name 'PDFSticker*.png' -o -name 'sticker.png' \) | grep -q .; then
  fail "loose sticker PNGs were copied into the app bundle"
fi
if find "$APP" \( -iname '*pdf-sticker-original*' -o -iname '*pdf-sticker-prompt*' \) | grep -q .; then
  fail "original artwork or generation prompts were copied into the app bundle"
fi

xcrun assetutil --info "$CAR" > "$TMP/assets.json"
python3 - "$TMP/assets.json" "$TMP/expected.tsv" <<'PY'
import json, sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
expected = {}
with open(sys.argv[2]) as handle:
    for line in handle:
        motif, asset, _sha = line.rstrip("\n").split("\t")
        expected[asset] = motif

images = [
    item for item in data
    if isinstance(item, dict)
    and item.get("AssetType") == "Image"
    and str(item.get("Name", "")).startswith("PDFSticker")
]
names = {item["Name"] for item in images}
if len(images) != 20:
    sys.exit(f"expected 20 sticker renditions in Assets.car, found {len(images)}")
if names != set(expected):
    sys.exit(f"Assets.car names differ from the manifest: {sorted(names ^ set(expected))}")
for item in images:
    if (item.get("PixelWidth"), item.get("PixelHeight")) != (256, 256):
        sys.exit(f"{item['Name']} is not 256x256")
    if item.get("Opaque") is not False or not str(item.get("Encoding", "")).startswith("ARGB"):
        sys.exit(f"{item['Name']} lost its alpha channel")
print("Assets.car: 20 sticker renditions, 256x256, alpha, names match the manifest")
PY

# 4. Load every asset through AppKit from the actual application bundle.
cat > "$TMP/load.swift" <<'SWIFT'
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 1, let bundle = Bundle(path: arguments[1]) else {
    FileHandle.standardError.write(Data("cannot open app bundle\n".utf8))
    exit(2)
}
var loaded = 0
for name in arguments.dropFirst(2) {
    guard let image = bundle.image(forResource: name) else {
        FileHandle.standardError.write(Data("missing asset: \(name)\n".utf8))
        exit(3)
    }
    guard image.size.width == 256, image.size.height == 256 else {
        FileHandle.standardError.write(Data("wrong size: \(name)\n".utf8))
        exit(4)
    }
    loaded += 1
}
print("AppKit loaded \(loaded) sticker assets from \(arguments[1])")
SWIFT
xcrun swiftc "$TMP/load.swift" -o "$TMP/load" -framework AppKit
# Asset names are ASCII and space-free, so word splitting is safe here.
NAME_ARGS="$(cut -f2 "$TMP/expected.tsv")"
# shellcheck disable=SC2086
"$TMP/load" "$APP" $NAME_ARGS

echo "verified: $APP"
