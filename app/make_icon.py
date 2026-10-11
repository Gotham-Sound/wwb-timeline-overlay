#!/usr/bin/env python3
"""
make_icon.py: draw the WWB Overlay app icon with Pillow and build app/AppIcon.icns via iconutil.
The icon is the dashboard in miniature: a dark rounded tile with three RF level bars and an
antenna with signal arcs. Run from anywhere; writes next to this script.
"""
import math
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024


def rgba(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


def draw_icon(size=SIZE):
    s = size / 1024
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # macOS-style rounded tile with a subtle vertical gradient
    inset = int(100 * s)
    tile = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    td.rounded_rectangle((inset, inset, size - inset, size - inset), radius=int(190 * s), fill=rgba("0b0f14"))
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    top, bot = (28, 38, 52), (9, 12, 17)
    for y in range(inset, size - inset):
        f = (y - inset) / (size - 2 * inset)
        col = tuple(int(top[k] + (bot[k] - top[k]) * f) for k in range(3)) + (255,)
        gd.line((inset, y, size - inset, y), fill=col)
    tile = Image.composite(grad, tile, tile.getchannel("A"))
    # soft drop shadow
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((inset, inset + int(18 * s), size - inset, size - inset + int(18 * s)),
                                             radius=int(190 * s), fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(22 * s)))
    img.alpha_composite(shadow)
    img.alpha_composite(tile)
    d = ImageDraw.Draw(img)

    # antenna mast + arcs (left)
    mx = int(330 * s)
    base_y, top_y = int(760 * s), int(430 * s)
    d.line((mx, base_y, mx, top_y), fill=rgba("e8eef5"), width=int(34 * s))
    d.ellipse((mx - int(40 * s), top_y - int(40 * s), mx + int(40 * s), top_y + int(40 * s)), fill=rgba("e8eef5"))
    d.polygon([(mx - int(110 * s), base_y + int(30 * s)), (mx + int(110 * s), base_y + int(30 * s)),
               (mx + int(24 * s), base_y - int(40 * s)), (mx - int(24 * s), base_y - int(40 * s))], fill=rgba("e8eef5"))
    for k, r in enumerate((120, 200, 280)):
        rr = int(r * s)
        w = int(30 * s)
        col = rgba("9fd3ff", 255 - k * 50)
        d.arc((mx - rr, top_y - rr, mx + rr, top_y + rr), start=235, end=305, fill=col, width=w)

    # three level bars (right), green / yellow / red like the dashboard
    bx = int(560 * s)
    bw, bh, gap = int(330 * s), int(70 * s), int(50 * s)
    y0 = int(410 * s)
    for k, (fill, frac) in enumerate(((rgba("39d353"), 0.92), (rgba("f2c94c"), 0.66), (rgba("ff4d4d"), 0.38))):
        y = y0 + k * (bh + gap)
        d.rounded_rectangle((bx, y, bx + bw, y + bh), radius=int(18 * s), fill=(255, 255, 255, 30))
        d.rounded_rectangle((bx, y, bx + int(bw * frac), y + bh), radius=int(18 * s), fill=fill)
    return img


def build_icns():
    out = os.path.join(HERE, "AppIcon.icns")
    base = draw_icon(1024)
    base.save(os.path.join(HERE, "AppIcon-1024.png"))
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                im = base.resize((px, px), Image.LANCZOS)
                name = f"icon_{pt}x{pt}" + ("@2x" if scale == 2 else "") + ".png"
                im.save(os.path.join(iconset, name))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print("wrote", out)


if __name__ == "__main__":
    if shutil.which("iconutil") is None:
        raise SystemExit("iconutil not found (needs Xcode command line tools)")
    build_icns()
