#!/usr/bin/env bash
# Fetch the pinned PdfCraft source tree used by the Rust path dependencies.
# Never uses a moving branch: the exact commit is fetched and verified.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="2ad7717f87ad6f15b14bdf22cddc1019d6fd0aed" # PdfCraft v0.20.0
DEST="$ROOT/third_party/pdfcraft"
URL="https://github.com/storytold/pdfcraft.git"

if [[ -d "$DEST/.git" ]]; then
  HEAD="$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$HEAD" == "$PIN" ]]; then
    echo "PdfCraft already pinned at $PIN"
    exit 0
  fi
  echo "error: $DEST exists at $HEAD, expected $PIN." >&2
  echo "Move it aside manually before re-running; this script never deletes a checkout." >&2
  exit 1
fi

mkdir -p "$(dirname "$DEST")"
echo "Cloning PdfCraft at $PIN ..."
git clone --filter=blob:none --no-checkout --depth 1 "$URL" "$DEST"
git -C "$DEST" fetch --filter=blob:none --depth 1 origin "$PIN"
git -C "$DEST" checkout --detach FETCH_HEAD

HEAD="$(git -C "$DEST" rev-parse HEAD)"
if [[ "$HEAD" != "$PIN" ]]; then
  echo "error: checked out $HEAD, expected $PIN" >&2
  exit 1
fi
echo "PdfCraft pinned at $HEAD"
