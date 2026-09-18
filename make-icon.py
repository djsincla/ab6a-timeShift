#!/usr/bin/env python3
"""Render ab6a-timeShift.icns. Build-time only - the app itself needs no third-party modules.

Requires Pillow:  python3 -m pip install pillow

Same family as ab6a-rigctl's icon: dark gradient squircle, white structure,
orange signal. Here the structure is a clock and the signal is the offset - a
second hand swung away from the true one, with an arc measuring the gap.
"""

import math
import os
import shutil
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("this script needs Pillow: python3 -m pip install pillow")

SS = 4            # supersample factor - Pillow's arc/ellipse drawing is not antialiased
SIZE = 1024
S = SIZE * SS

BG_TOP = (34, 48, 66)
BG_BOTTOM = (13, 21, 30)
FACE = (240, 245, 250)
GHOST = (108, 126, 148)
ACCENT = (255, 160, 60)

CX = CY = S // 2
R = int(0.300 * S)          # clock ring radius


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def rounded_mask(size, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1],
                                           radius=radius, fill=255)
    return mask


def hand(d, degrees, length, width, color, tail=0.0):
    """A clock hand from the hub, with rounded ends."""
    rad = math.radians(degrees)
    dx, dy = math.cos(rad), math.sin(rad)
    x0, y0 = CX - dx * tail, CY - dy * tail
    x1, y1 = CX + dx * length, CY + dy * length
    d.line([(x0, y0), (x1, y1)], fill=color, width=width)
    cap = width // 2
    for (x, y) in ((x0, y0), (x1, y1)):
        d.ellipse([x - cap, y - cap, x + cap, y + cap], fill=color)


def render():
    # vertical gradient background
    bg = Image.new("RGB", (S, S))
    top = ImageDraw.Draw(bg)
    for y in range(S):
        top.line([(0, y), (S, y)], fill=lerp(BG_TOP, BG_BOTTOM, y / (S - 1)))

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), rounded_mask(S, int(0.2237 * S)))
    d = ImageDraw.Draw(icon)

    # clock ring
    ring_w = int(0.050 * S)
    d.ellipse([CX - R, CY - R, CX + R, CY + R], outline=FACE, width=ring_w)

    # quarter ticks
    tick_w = int(0.022 * S)
    for deg in (-90, 0, 90, 180):
        rad = math.radians(deg)
        inner, outer = R - int(0.088 * S), R - int(0.036 * S)
        d.line([(CX + inner * math.cos(rad), CY + inner * math.sin(rad)),
                (CX + outer * math.cos(rad), CY + outer * math.sin(rad))],
               fill=GHOST, width=tick_w)

    # the offset, swept from true time to shifted time
    arc_r = int(0.170 * S)
    d.arc([CX - arc_r, CY - arc_r, CX + arc_r, CY + arc_r],
          start=-90, end=-28, fill=ACCENT, width=int(0.038 * S))

    # true time: hands at 12 and 4, in the ghost tone
    hand(d, -90, int(0.205 * S), int(0.040 * S), GHOST, tail=int(0.030 * S))
    hand(d, 30, int(0.150 * S), int(0.044 * S), GHOST, tail=int(0.030 * S))

    # shifted time: the same minute hand, swung clear
    hand(d, -28, int(0.205 * S), int(0.048 * S), ACCENT, tail=int(0.030 * S))

    # hub
    hub = int(0.046 * S)
    d.ellipse([CX - hub, CY - hub, CX + hub, CY + hub], fill=FACE)

    return icon.resize((SIZE, SIZE), Image.LANCZOS)


def build_icns(img, out_path):
    iconset = out_path.replace(".icns", ".iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for base in (16, 32, 128, 256, 512):
        img.resize((base, base), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d.png" % (base, base)))
        img.resize((base * 2, base * 2), Image.LANCZOS).save(
            os.path.join(iconset, "icon_%dx%d@2x.png" % (base, base)))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out_path], check=True)
    shutil.rmtree(iconset, ignore_errors=True)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "ab6a-timeShift.icns"
    image = render()
    image.save(out.replace(".icns", "-preview.png"))
    build_icns(image, out)
    print("wrote %s" % out)
