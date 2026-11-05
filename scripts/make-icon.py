#!/usr/bin/env python3
"""Draw VoiceBridge's app icon.

Produces the 1024×1024 master PNG; `scripts/make-icon.sh` turns it (and a
simplified small-size variant) into the .icns the app bundle ships.

Two masters on purpose: macOS renders the 16/32 px representations, where the
sound arcs turn into mud. The small variant drops them and thickens the
microphone instead. Everything is drawn at 4× and downsampled.

Why a script instead of a checked-in PSD: an icon is a design decision that
should be reviewable in a diff. Change the numbers here, re-run, look.

Run:  python3 scripts/make-icon.py Resources/AppIcon-1024.png
      python3 scripts/make-icon.py --simplified Resources/AppIcon-1024-small.png
"""

from __future__ import annotations

import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SS = 4  # supersampling factor

# Palette: an indigo→teal diagonal, dark enough that the white glyph keeps its
# contrast on a light or a dark desktop.
TOP_LEFT = (91, 75, 245)  # #5B4BF5
BOTTOM_RIGHT = (15, 181, 201)  # #0FB5C9

# The macOS icon grid: an 824 pt rounded square centred in a 1024 pt canvas.
MARGIN = 100
RADIUS = 190


def gradient(size: int) -> Image.Image:
    """A diagonal two-colour gradient, defined at 2×2 and scaled."""
    a = Image.new("RGB", (2, 2))
    a.putpixel((0, 0), TOP_LEFT)
    a.putpixel((1, 0), TOP_LEFT)
    a.putpixel((0, 1), BOTTOM_RIGHT)
    a.putpixel((1, 1), BOTTOM_RIGHT)
    return a.resize((size, size), Image.BILINEAR)


def rounded_mask(size: int, margin: int, radius: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (margin, margin, size - margin, size - margin),
        radius=radius,
        fill=255,
    )
    return mask


def draw_mic(draw: ImageDraw.ImageDraw, s: int, scale: float = 1.0, bold: bool = False) -> None:
    """White microphone: capsule, cradle, stem, base.

    Explicit 1024-point coordinates (multiplied by `s`), because a formula that
    derived the cradle from the capsule put the arc's ends out beside the
    capsule like horns. The whole glyph is 296…809 pt tall, optically centred
    on the squircle.

    `scale` grows the glyph for the small-size master; `bold` thickens the
    strokes so they survive at 16 px.
    """
    cx = 512 * s
    stroke = (58 if bold else 40) * s * scale
    tw = stroke / 2

    # Capsule.
    cap_w = 158 * s * scale * (1.14 if bold else 1.0)
    cap_top = 296 * s * scale
    cap_bottom = 588 * s * scale
    draw.rounded_rectangle(
        (cx - cap_w / 2, cap_top, cx + cap_w / 2, cap_bottom),
        radius=cap_w / 2,
        fill=(255, 255, 255, 255),
    )

    # Cradle: the bottom half of a circle centred at the capsule's base, so the
    # visible arc starts *below* the capsule instead of flaring beside it.
    cradle_cy = cap_bottom - 6 * s * scale
    cradle_r = 150 * s * scale
    draw.arc(
        (cx - cradle_r, cradle_cy - cradle_r, cx + cradle_r, cradle_cy + cradle_r),
        start=12,
        end=168,
        fill=(255, 255, 255, 255),
        width=int(stroke),
    )

    # Stem + base.
    stem_top = cradle_cy + cradle_r - tw
    stem_bottom = 782 * s * scale
    draw.rounded_rectangle(
        (cx - tw, stem_top, cx + tw, stem_bottom),
        radius=tw,
        fill=(255, 255, 255, 255),
    )
    base_w = 214 * s * scale
    draw.rounded_rectangle(
        (cx - base_w / 2, stem_bottom - stroke, cx + base_w / 2, stem_bottom),
        radius=tw,
        fill=(255, 255, 255, 255),
    )


def draw_waves(layer: Image.Image, s: int) -> None:
    """Two faded arcs each side: the 'bridge' half of the name.

    On their own layer so they can be translucent without dimming the
    microphone.
    """
    draw = ImageDraw.Draw(layer)
    cx, cy = 512 * s, 520 * s
    for i, (radius, alpha) in enumerate(((272, 110), (352, 60))):
        r = radius * s
        width = int((32 - i * 7) * s)
        colour = (255, 255, 255, alpha)
        draw.arc((cx - r, cy - r, cx + r, cy + r), start=-50, end=50, fill=colour, width=width)
        draw.arc((cx - r, cy - r, cx + r, cy + r), start=130, end=230, fill=colour, width=width)


def build(waves: bool = True, bold: bool = False) -> Image.Image:
    size = SIZE * SS

    # Soft drop shadow under the squircle (Big Sur icons carry their own).
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_mask = rounded_mask(size, MARGIN * SS, RADIUS * SS)
    shadow.putalpha(shadow_mask.point(lambda v: int(v * 0.30)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(24 * SS))
    shadow = ImageChops.offset(shadow, 0, int(14 * SS))

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(shadow)

    body = gradient(size).convert("RGBA")
    body.putalpha(rounded_mask(size, MARGIN * SS, RADIUS * SS))

    # A light sheen across the top third so the gradient does not look flat.
    sheen = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(sheen).ellipse(
        (MARGIN * SS - 60 * SS, -220 * SS, size - MARGIN * SS + 60 * SS, 420 * SS),
        fill=(255, 255, 255, 26),
    )
    sheen = sheen.filter(ImageFilter.GaussianBlur(60 * SS))
    sheen = Image.composite(
        sheen,
        Image.new("RGBA", (size, size), (0, 0, 0, 0)),
        rounded_mask(size, MARGIN * SS, RADIUS * SS),
    )
    body.alpha_composite(sheen)
    canvas.alpha_composite(body)

    if waves:
        wave_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        draw_waves(wave_layer, SS)
        canvas.alpha_composite(wave_layer)

    glyph = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw_mic(ImageDraw.Draw(glyph), SS, scale=1.12 if bold else 1.06, bold=bold)
    canvas.alpha_composite(glyph)

    return canvas.resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    simplified = "--simplified" in sys.argv
    out = args[0] if args else "Resources/AppIcon-1024.png"
    build(waves=not simplified, bold=simplified).save(out)
    print(f"wrote {out}")
