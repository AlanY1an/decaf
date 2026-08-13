#!/usr/bin/env python3
"""Install a 1024-ish square PNG as the app icon.

    python3 Scripts/install-appicon-png.py <artwork.png>

Companion to Scripts/set-appicon.sh, which regenerates the icon from one of the
four concept SVGs. This one takes finished raster artwork instead — an image
model's output, say — and does the three things such artwork always needs:

  1. RESIZE to exactly 1024. Generators rarely emit 1024; the one this was
     written for came out 1254.

  2. PUNCH THE CORNERS TO ALPHA. The traditional macOS ladder expects artwork
     that carries its own rounded shape on a TRANSPARENT ground. Generators
     bake the squircle and fill outside it with opaque black, which installs as
     a black square with a rounded tile floating inside it. The mask here is
     the same continuous-curvature squircle render.py draws, so the corner
     matches what macOS itself would cut.

  3. WRITE THE LADDER, 16 through 512@2x, plus docs/assets/icon-256.png so the
     shipped icon and the icon in the README cannot drift apart — the same
     guarantee set-appicon.sh makes.

It does NOT touch the menu bar. That glyph is drawn in App/IconRenderer.swift
from SF Symbols at runtime and shares nothing with this artwork.

Small sizes are plain downscales. Detailed artwork goes soft by 16 px and that
is expected: Apple ships separately drawn small variants, and so should this
once a direction is settled. `--report` prints what each size looks like so the
decision is made against evidence rather than against the 1024.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"
README_HERO = ROOT / "docs/assets/icon-256.png"
CANVAS = 1024


def squircle_mask(size: int) -> Image.Image:
    """Rasterise render.py's squircle through sips, and use it as the alpha."""
    sys.path.insert(0, str(ROOT / "docs/launch/icon-concepts"))
    import render as r1  # noqa: E402

    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
           f'viewBox="0 0 {r1.CANVAS} {r1.CANVAS}">'
           f'<path d="{r1.SQUIRCLE}" fill="#FFFFFF"/></svg>')
    tmp_svg = ROOT / "build" / "_squircle.svg"
    tmp_png = ROOT / "build" / "_squircle.png"
    tmp_svg.parent.mkdir(parents=True, exist_ok=True)
    tmp_svg.write_text(svg)
    subprocess.run(["sips", "-s", "format", "png", str(tmp_svg), "--out", str(tmp_png)],
                   check=True, capture_output=True)
    mask = Image.open(tmp_png).convert("L").resize((size, size), Image.LANCZOS)
    tmp_svg.unlink(missing_ok=True)
    tmp_png.unlink(missing_ok=True)
    return mask


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src_path = Path(sys.argv[1]).expanduser()
    if not src_path.is_file():
        print(f"error: no such file: {src_path}", file=sys.stderr)
        return 1

    src = Image.open(src_path).convert("RGBA")
    if src.width != src.height:
        print(f"error: artwork must be square, got {src.width}x{src.height}", file=sys.stderr)
        return 1
    print(f"source      {src_path.name}  {src.width}x{src.height}")

    master = src.resize((CANVAS, CANVAS), Image.LANCZOS)
    corners_before = master.getpixel((2, 2))
    master.putalpha(squircle_mask(CANVAS))
    print(f"corners     {corners_before} -> alpha 0  (squircle punched)")

    entries = json.loads((ICONSET / "Contents.json").read_text())["images"]
    for entry in entries:
        base = int(entry["size"].split("x")[0])
        px = base * int(entry["scale"].rstrip("x"))
        master.resize((px, px), Image.LANCZOS).save(ICONSET / entry["filename"])
    print(f"ladder      {len(entries)} files written to {ICONSET.relative_to(ROOT)}")

    README_HERO.parent.mkdir(parents=True, exist_ok=True)
    master.resize((256, 256), Image.LANCZOS).save(README_HERO)
    print(f"README hero {README_HERO.relative_to(ROOT)}")

    if "--report" in sys.argv:
        print("\nwhat each size actually looks like:")
        for px in (512, 256, 128, 64, 32, 16):
            small = master.resize((px, px), Image.LANCZOS).convert("L")
            lo, hi = small.getextrema()
            print(f"  {px:>4}px  luminance range {lo}-{hi}  contrast {hi - lo}")
        print("  (a collapsing range at 16px is the artwork going to mush)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
