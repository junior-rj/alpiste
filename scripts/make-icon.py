#!/usr/bin/env python3
"""Generates Alpiste's AppIcon: birdseed grains whose heights trace a waveform.

Sparrow brand palette, navy tile with warm grains. Shapes are drawn at 4x and
downscaled with LANCZOS, because PIL has no antialiasing of its own.

    python3 scripts/make-icon.py

Rewrites Alpiste/Assets.xcassets/AppIcon.appiconset in place.
"""
import json
import pathlib
from PIL import Image, ImageDraw

S = 4  # supersample factor
SIZE = 1024 * S

NAVY = (24, 52, 81)      # #183451 Riviera Blue
IVORY = (243, 236, 222)  # #F3ECDE Soft Ivory
SAND = (212, 175, 131)   # #D4AF83 Sand Linen

# Apple's macOS grid: 824x824 of content centred in 1024, corner radius 185.
MARGIN = 100 * S
RADIUS = 185 * S

# Symmetric waveform envelope. 5 grains, because 7 turn into hairlines at 32px.
# The outermost value is tuned so the shortest grain renders as a circle: a seed,
# not a bar. Everything taller reads as the same seed stretched.
HEIGHTS = [0.30, 0.66, 1.0, 0.66, 0.30]

SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Xcode wants some files twice, once per idiom/scale pair.
CONTENTS = {
    "images": [
        {"filename": "icon_16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "icon_32.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "icon_32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "icon_64.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "icon_128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "icon_256.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "icon_256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "icon_512.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "icon_512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "icon_1024.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}


def render():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([MARGIN, MARGIN, SIZE - MARGIN, SIZE - MARGIN],
                        radius=RADIUS, fill=NAVY)

    n = len(HEIGHTS)
    content = SIZE - 2 * MARGIN
    span = content * 0.66
    # Fat grains with tight gaps, so they stay solid shapes rather than hairlines
    # once macOS scales the icon down.
    grain_w = span / (n * 1.32)
    gap = (span - n * grain_w) / (n - 1)
    left = (SIZE - span) / 2
    cy = SIZE / 2
    tallest = content * 0.62

    for i, h in enumerate(HEIGHTS):
        x0 = left + i * (grain_w + gap)
        half = tallest * h / 2
        # Ivory on the peak grains, sand on the rest: gives the waveform a crest.
        colour = IVORY if h >= 0.8 else SAND
        # Fully rounded caps turn each bar into a grain; the shortest becomes a circle.
        d.rounded_rectangle([x0, cy - half, x0 + grain_w, cy + half],
                            radius=grain_w / 2, fill=colour)
    return img


if __name__ == "__main__":
    out = pathlib.Path(__file__).resolve().parent.parent / "Alpiste/Assets.xcassets/AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    master = render()
    for size in SIZES:
        master.resize((size, size), Image.LANCZOS).save(out / f"icon_{size}.png")
    (out / "Contents.json").write_text(json.dumps(CONTENTS, indent=2) + "\n")
    print(f"wrote {len(SIZES)} PNGs + Contents.json to {out}")
