#!/usr/bin/env python3
"""Frame a screenshot so it reads as deliberate on both README themes.

    python3 Scripts/frame-screenshot.py <shot.png> <out-basename>

Writes `<out-basename>-light.png` and `<out-basename>-dark.png` next to the
source, for use in a <picture> element like the rest of docs/assets.

Why this exists: the menu screenshot is a real light-mode NSMenu, drawn by the
WindowServer and capturable only by a human — there is no dark-mode counterpart
and no way to render one offscreen. Dropped straight into the README it is a
white slab on a dark page, which looks like an oversight rather than a choice.

Framing fixes that without a second capture. The menu stays light in both
variants; what changes is the surface behind it, which matches the reader's
theme. A light card on a light page and a floating light window on a dark page
both read as intentional, because in each case the screenshot is presented
rather than pasted.

Backgrounds are GitHub's own canvas colours, so the frame meets the page
exactly rather than almost.
"""
from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

PAD = 56
RADIUS = 16
# GitHub's canvas colours: the frame should meet the page, not approximate it.
THEMES = {
    "light": {"canvas": (246, 248, 250), "border": (0, 0, 0, 26), "shadow": 46},
    "dark": {"canvas": (13, 17, 23), "border": (255, 255, 255, 30), "shadow": 84},
}


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                           radius=radius, fill=255)
    return mask


def frame(shot: Image.Image, theme: dict) -> Image.Image:
    w, h = shot.size
    out = Image.new("RGBA", (w + PAD * 2, h + PAD * 2), theme["canvas"] + (255,))

    # Soft drop shadow, so the screenshot sits ON the canvas rather than in it.
    shadow = Image.new("RGBA", out.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [PAD, PAD + 8, PAD + w, PAD + h + 8], radius=RADIUS,
        fill=(0, 0, 0, theme["shadow"]))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    out = Image.alpha_composite(out, shadow)

    rounded = shot.convert("RGBA")
    rounded.putalpha(rounded_mask(shot.size, RADIUS))
    out.paste(rounded, (PAD, PAD), rounded)

    # A hairline keeps the light menu from bleeding into a light canvas.
    ImageDraw.Draw(out).rounded_rectangle(
        [PAD, PAD, PAD + w - 1, PAD + h - 1], radius=RADIUS,
        outline=theme["border"], width=1)
    return out.convert("RGB")


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    src = Path(sys.argv[1]).expanduser()
    if not src.is_file():
        print(f"error: no such file: {src}", file=sys.stderr)
        return 1
    stem = sys.argv[2]
    shot = Image.open(src)
    for name, theme in THEMES.items():
        out_path = src.parent / f"{stem}-{name}.png"
        framed = frame(shot, theme)
        framed.save(out_path, optimize=True)
        print(f"  {out_path.name}  {framed.width}x{framed.height}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
