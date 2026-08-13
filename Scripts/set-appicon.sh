#!/bin/sh
# Regenerate the app icon from one of the four concept directions.
#
#     Scripts/set-appicon.sh B            # switch the app to direction B
#     Scripts/set-appicon.sh A /tmp/icon  # …and keep the intermediates (.icns)
#
# The icon direction is not frozen: this script is the one command that undoes
# the choice. It rewrites two things and nothing else —
#
#     App/Resources/Assets.xcassets/AppIcon.appiconset/   the 10-PNG ladder
#     docs/assets/icon-256.png                            the README hero image
#
# so the shipped icon and the icon in the README can never disagree.
#
# Everything is regenerated from dev-docs/launch/icon-concepts/svg/<KEY>-*.svg via
# dev-docs/launch/icon-concepts/make-appicon.py; see dev-docs/launch/icon-pipeline.md
# for why the artwork is inset to 80.5% and why all ten sizes are kept.
#
# Rebuild after running this — actool compiles the set into Contents/Resources
# at build time, so an existing bundle keeps showing the old icon.
set -eu

usage() {
    echo "usage: Scripts/set-appicon.sh <A|B|C|D> [staging-dir]" >&2
    echo "  A  top-down cup      C  activity signal" >&2
    echo "  B  steady cursor     D  held power symbol" >&2
    exit 2
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage

ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
case "$KEY" in
    A | B | C | D) ;;
    *) usage ;;
esac

CONCEPTS="$ROOT/dev-docs/launch/icon-concepts"
DEST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
README_ICON="$ROOT/docs/assets/icon-256.png"

# Resolve the direction to exactly one source SVG. Globbing rather than a
# hardcoded table so renaming a concept file does not silently break this.
SVG=""
for candidate in "$CONCEPTS"/svg/"$KEY"-*.svg; do
    [ -f "$candidate" ] || continue
    [ -z "$SVG" ] || { echo "ambiguous: several SVGs match $KEY-*" >&2; exit 1; }
    SVG="$candidate"
done
[ -n "$SVG" ] || { echo "no concept SVG for direction $KEY in $CONCEPTS/svg" >&2; exit 1; }

command -v python3 >/dev/null || { echo "python3 missing"; exit 1; }
python3 -c "import PIL" 2>/dev/null || { echo "Pillow missing: python3 -m pip install pillow"; exit 1; }
command -v sips >/dev/null || { echo "sips missing; this script needs stock macOS"; exit 1; }

if [ $# -eq 2 ]; then
    WORK=$2
    mkdir -p "$WORK"
    KEEP=yes
else
    WORK=$(mktemp -d)
    KEEP=no
fi

# Generate into staging first, validate there, and only then touch the project:
# a failure halfway through must not leave the app with a half-written icon set.
python3 "$CONCEPTS/make-appicon.py" "$SVG" "$WORK" >/dev/null

STAGED="$WORK/AppIcon.appiconset"
[ -f "$STAGED/Contents.json" ] || { echo "generator produced no Contents.json"; exit 1; }
COUNT=$(ls "$STAGED"/*.png 2>/dev/null | wc -l | tr -d ' ')
[ "$COUNT" -eq 10 ] || { echo "expected 10 PNGs in the ladder, got $COUNT"; exit 1; }

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$STAGED" "$DEST"

# README hero: full-bleed, alpha preserved. Deliberately NOT the 80.5%-inset
# app-icon render (that margin exists to match Finder's grid) and deliberately
# not icon-concepts/png/<KEY>-256.png (those are RGB — their transparent
# corners were flattened to black, which shows as a black square on GitHub).
mkdir -p "$(dirname "$README_ICON")"
python3 - "$WORK/_master-1024.png" "$README_ICON" <<'PY'
import sys
from PIL import Image
src, dst = sys.argv[1], sys.argv[2]
Image.open(src).convert("RGBA").resize((256, 256), Image.LANCZOS).save(dst)
PY

echo "icon direction $KEY  <-  $(basename "$SVG")"
echo "  $DEST  ($COUNT PNGs)"
echo "  $README_ICON"
if [ "$KEEP" = yes ]; then
    echo "  $WORK/AppIcon.icns  (DMG volume icon, website, Homebrew page)"
else
    rm -rf "$WORK"
fi
echo "now rebuild: Scripts/run.sh"
