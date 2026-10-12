#!/usr/bin/env python3
"""
NotchTerm AppIcon — based on ~/.claude/skills/macos-app-icon/scripts/generate_icon.py
- 9% pad + superellipse (n=5), squircle ≈82% of canvas
- Foreground matches menu-bar mark: rounded square + capsule notch + >_
"""
import json
import math
import os
import shutil
import subprocess
import sys
from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
ASSET_DIR = sys.argv[1] if len(sys.argv) > 1 else \
    os.path.join(ROOT, "Resources/Assets.xcassets/AppIcon.appiconset")

PAD_RATIO = 0.09
SUPERELLIPSE_N = 5.0

# Near-black charcoal (matches notch chrome; avoid purple defaults).
BG_FROM = (28, 30, 34)
BG_TO = (10, 11, 13)


def draw_foreground(d: ImageDraw.ImageDraw, sz: int):
    """Rounded square + top capsule notch + centered `>_` (menu-bar twin)."""
    # Soft graphite frame (not white) so it sits into the dark squircle.
    ink = (92, 98, 108, 245)
    accent = (120, 220, 175, 245)  # soft mint for prompt

    # Phone / window frame — slightly inset inside squircle.
    inset = sz * 0.18
    body = [inset, inset, sz - inset, sz - inset]
    bw = body[2] - body[0]
    bh = body[3] - body[1]
    corner = max(2, int(sz * 0.08))
    lw = max(1, int(sz * 0.045))

    d.rounded_rectangle(body, radius=corner, outline=ink, width=lw)

    # Capsule notch (Dynamic Island) at top center, inside the frame.
    notch_w = bw * 0.38
    notch_h = bh * 0.12
    nx0 = body[0] + (bw - notch_w) / 2
    ny0 = body[1] + lw * 0.85
    notch = [nx0, ny0, nx0 + notch_w, ny0 + notch_h]
    d.rounded_rectangle(notch, radius=notch_h / 2, fill=ink)

    # Prompt `>_` — center the group in the content well.
    content_top = ny0 + notch_h + bh * 0.06
    content_bot = body[3] - lw
    cy = (content_top + content_bot) / 2
    span = bw * 0.16
    half_h = bh * 0.14
    gap = bw * 0.07
    cursor_w = bw * 0.16
    group_w = span + gap + cursor_w
    # Optical left bias: stroke width + open chevron reads heavy on the right.
    group_left = body[0] + (bw - group_w) / 2 - bw * 0.02
    tip_x = group_left + span
    back_x = group_left
    plw = max(1, int(sz * 0.048))
    r = plw / 2.0

    d.line([(back_x, cy - half_h), (tip_x, cy)], fill=accent, width=plw)
    d.line([(tip_x, cy), (back_x, cy + half_h)], fill=accent, width=plw)
    for pt in [(back_x, cy - half_h), (tip_x, cy), (back_x, cy + half_h)]:
        d.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r], fill=accent)

    cx0 = tip_x + gap
    cy_line = cy + half_h
    d.line([(cx0, cy_line), (cx0 + cursor_w, cy_line)], fill=accent, width=plw)
    d.ellipse([cx0 - r, cy_line - r, cx0 + r, cy_line + r], fill=accent)
    d.ellipse(
        [cx0 + cursor_w - r, cy_line - r, cx0 + cursor_w + r, cy_line + r],
        fill=accent,
    )


def superellipse_mask(size: int, n: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    half = size / 2.0
    for y in range(size):
        for x in range(size):
            if abs((x - half) / half) ** n + abs((y - half) / half) ** n <= 1.0:
                px[x, y] = 255
    return mask


def draw_icon(canvas: int) -> Image.Image:
    pad = int(canvas * PAD_RATIO)
    sz = canvas - 2 * pad

    bg = Image.new("RGBA", (sz, sz), (0, 0, 0, 255))
    d = ImageDraw.Draw(bg)
    for y in range(sz):
        t = y / max(sz - 1, 1)
        row = (
            int(BG_FROM[0] + (BG_TO[0] - BG_FROM[0]) * t),
            int(BG_FROM[1] + (BG_TO[1] - BG_FROM[1]) * t),
            int(BG_FROM[2] + (BG_TO[2] - BG_FROM[2]) * t),
        )
        d.line([(0, y), (sz, y)], fill=row + (255,))

    draw_foreground(d, sz)

    if sz >= 32:
        bg.putalpha(superellipse_mask(sz, SUPERELLIPSE_N))
    else:
        m = Image.new("L", (sz, sz), 0)
        ImageDraw.Draw(m).rounded_rectangle(
            [0, 0, sz - 1, sz - 1], radius=int(sz * 0.32), fill=255
        )
        bg.putalpha(m)

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(bg, (pad, pad), bg)
    return out


def main():
    contents = os.path.join(ASSET_DIR, "Contents.json")
    with open(contents) as f:
        images = json.load(f)["images"]

    seen = {}
    for img in images:
        fn = img.get("filename")
        if not fn:
            continue
        base = int(img["size"].split("x")[0])
        scale = int(img["scale"].rstrip("x"))
        canvas = base * scale
        if canvas not in seen:
            seen[canvas] = draw_icon(canvas)
        seen[canvas].save(os.path.join(ASSET_DIR, fn))
        print(f"{fn}  ({canvas}px)")

    # Also write root preview + .icns via iconutil
    big = draw_icon(1024)
    preview = os.path.join(ROOT, "AppIcon-1024.png")
    big.save(preview)
    print(f"AppIcon-1024.png  (1024px)")

    iconset = os.path.join(ROOT, "AppIcon.iconset")
    if os.path.isdir(iconset):
        shutil.rmtree(iconset)
    os.makedirs(iconset)
    # iconutil naming
    mapping = {
        16: "icon_16x16.png",
        32: ["icon_16x16@2x.png", "icon_32x32.png"],
        64: "icon_32x32@2x.png",
        128: "icon_128x128.png",
        256: ["icon_128x128@2x.png", "icon_256x256.png"],
        512: ["icon_256x256@2x.png", "icon_512x512.png"],
        1024: "icon_512x512@2x.png",
    }
    for px, names in mapping.items():
        img = seen.get(px) or draw_icon(px)
        if isinstance(names, str):
            names = [names]
        for name in names:
            img.save(os.path.join(iconset, name))

    icns = os.path.join(ROOT, "AppIcon.icns")
    subprocess.check_call(["iconutil", "--convert", "icns", iconset, "--output", icns])
    print(f"Wrote {icns}")
    print("Done — filenames match Contents.json + AppIcon.icns updated")


if __name__ == "__main__":
    main()
