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
import math
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ICONSET = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset"
README_HERO = ROOT / "docs/assets/icon-256.png"
CANVAS = 1024


def squircle_path(size: float, radius: float, smoothing: float = 0.6) -> str:
    """Continuous-corner rounded rect — the iOS/macOS icon silhouette.

    A shortened circular arc joined to the straight edges by two cubic
    segments, rather than the plain quarter-circle an SVG `rx` would give.

    Inlined rather than imported. The exploration harness this was taken from
    now lives under dev-docs/, which is gitignored, and a script that installs
    the shipped icon must not stop working on a fresh clone because a local
    scratch directory is missing.
    """
    budget = size / 2.0
    if (1 + smoothing) * radius > budget:
        radius = budget / (1 + smoothing)
    p = (1 + smoothing) * radius

    arc_measure = 90.0 * (1 - smoothing)
    arc = math.sin(math.radians(arc_measure / 2)) * radius * math.sqrt(2)
    alpha = (90.0 - arc_measure) / 2
    p3p4 = radius * math.tan(math.radians(alpha / 2))
    c = p3p4 * math.cos(math.radians(alpha))
    d = c * math.tan(math.radians(alpha))
    b = (p - arc - c - d) / 3
    a = 2 * b
    r = radius
    ab, abc = a + b, a + b + c

    def n(v: float) -> str:
        return f"{v:.3f}"

    return " ".join([
        f"M {n(size - p)} 0",
        f"c {n(a)} 0 {n(ab)} 0 {n(abc)} {n(d)}",
        f"a {n(r)} {n(r)} 0 0 1 {n(arc)} {n(arc)}",
        f"c {n(d)} {n(c)} {n(d)} {n(b + c)} {n(d)} {n(abc)}",
        f"L {n(size)} {n(size - p)}",
        f"c 0 {n(a)} 0 {n(ab)} {n(-d)} {n(abc)}",
        f"a {n(r)} {n(r)} 0 0 1 {n(-arc)} {n(arc)}",
        f"c {n(-c)} {n(d)} {n(-(b + c))} {n(d)} {n(-abc)} {n(d)}",
        f"L {n(p)} {n(size)}",
        f"c {n(-a)} 0 {n(-ab)} 0 {n(-abc)} {n(-d)}",
        f"a {n(r)} {n(r)} 0 0 1 {n(-arc)} {n(-arc)}",
        f"c {n(-d)} {n(-c)} {n(-d)} {n(-(b + c))} {n(-d)} {n(-abc)}",
        f"L 0 {n(p)}",
        f"c 0 {n(-a)} 0 {n(-ab)} {n(d)} {n(-abc)}",
        f"a {n(r)} {n(r)} 0 0 1 {n(arc)} {n(-arc)}",
        f"c {n(c)} {n(-d)} {n(b + c)} {n(-d)} {n(abc)} {n(-d)}",
        "Z",
    ])


def squircle_mask(size: int) -> Image.Image:
    """Rasterise the squircle through sips, and use it as the alpha."""
    path = squircle_path(CANVAS, CANVAS * 0.2237)
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
           f'viewBox="0 0 {CANVAS} {CANVAS}">'
           f'<path d="{path}" fill="#FFFFFF"/></svg>')
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
    # Refuse to upscale. Feeding this script its own 256 px README output once
    # blew the whole ladder up from a quarter-size source and every slot came
    # out soft — the run reported success throughout, because resizing up is
    # not an error to PIL. Anything under 1024 is a mistake worth stopping for.
    if src.width < CANVAS:
        print(f"error: {src_path.name} is {src.width}px; artwork must be at least "
              f"{CANVAS}px or every icon slot is an upscale.\n"
              f"       Pass --allow-upscale only if you genuinely mean it.",
              file=sys.stderr)
        if "--allow-upscale" not in sys.argv:
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
