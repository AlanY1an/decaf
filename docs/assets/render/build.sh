#!/bin/bash
# Refresh the App source copies from the repo, then build the harness.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
DEST="$HERE/Sources/DecafRender/App"

rm -rf "$DEST"
mkdir -p "$DEST"
for f in "$REPO"/App/*.swift; do
  base="$(basename "$f")"
  # DecafApp.swift carries @main; main.swift is the harness entry point.
  [ "$base" = "DecafApp.swift" ] && continue
  cp "$f" "$DEST/$base"
done

cd "$HERE"
swift build -c release "$@"
