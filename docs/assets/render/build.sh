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

# The renderer writes into its CWD. Running it from this directory silently
# scatters PNGs here while docs/assets keeps the stale ones — which cost an
# afternoon of "my fix had no effect" before anyone checked an mtime.
echo
echo "Render with:  ./.build/release/DecafRender .."
