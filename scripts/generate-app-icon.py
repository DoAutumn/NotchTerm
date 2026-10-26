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
from PIL import Image, ImageChops, ImageDraw

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

    # Prompt `>_` — drawn large (via supersample in draw_icon), then downscaled for smooth AA.
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
    plw = max(2, int(round(sz * 0.052)))
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
    """Coverage-sampled superellipse (soft edge). Avoids white halo from binary cutouts."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    half = size / 2.0
    # Sub-pixel samples per axis; keep cheap on huge supersampled canvases.
    grid = (-0.25, 0.25)
    samples = len(grid) * len(grid)
    for y in range(size):
        for x in range(size):
            inside = 0
            for dy in grid:
                for dx in grid:
                    nx = abs((x + 0.5 + dx - half) / half)
                    ny = abs((y + 0.5 + dy - half) / half)
                    if nx ** n + ny ** n <= 1.0:
                        inside += 1
            if inside:
                px[x, y] = int(round(255 * inside / samples))
    return mask


def _render(canvas: int) -> Image.Image:
    pad = int(round(canvas * PAD_RATIO))
    sz = canvas - 2 * pad
    if sz < 1:
        raise ValueError(f"canvas {canvas} is too small for padding")

    bg = Image.new("RGBA", (sz, sz), (0, 0, 0, 255))
    d = ImageDraw.Draw(bg)
    px = bg.load()
    for y in range(sz):
        t = y / max(sz - 1, 1)
        row = (
            int(BG_FROM[0] + (BG_TO[0] - BG_FROM[0]) * t),
            int(BG_FROM[1] + (BG_TO[1] - BG_FROM[1]) * t),
            int(BG_FROM[2] + (BG_TO[2] - BG_FROM[2]) * t),
            255,
        )
        for x in range(sz):
            px[x, y] = row

    draw_foreground(d, sz)
    # Always superellipse — small sizes get smoothness from supersampling below.
    bg.putalpha(superellipse_mask(sz, SUPERELLIPSE_N))

    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    out.paste(bg, (pad, pad), bg)
    return out


def _resize_premultiplied(im: Image.Image, size: tuple[int, int]) -> Image.Image:
    """LANCZOS on straight alpha fringes light colors into the edge; premultiply first."""
    r, g, b, a = im.split()
    r = ImageChops.multiply(r, a)
    g = ImageChops.multiply(g, a)
    b = ImageChops.multiply(b, a)
    pre = Image.merge("RGBA", (r, g, b, a))
    scaled = pre.resize(size, Image.Resampling.LANCZOS)
    # Clamp premult RGB ≤ alpha (LANCZOS ringing), then un-premultiply.
    # Outer-edge RGB is also capped to charcoal so ringing can't become a white halo.
    bg_cap = max(BG_FROM + BG_TO) + 10
    px_r, px_g, px_b, px_a = scaled.split()
    pr = ImageChops.darker(px_r, px_a).load()
    pg = ImageChops.darker(px_g, px_a).load()
    pb = ImageChops.darker(px_b, px_a).load()
    pa = px_a.load()
    w, h = size
    out = Image.new("RGBA", size)
    op = out.load()
    for y in range(h):
        for x in range(w):
            alpha = pa[x, y]
            if alpha < 8:
                op[x, y] = (0, 0, 0, 0)
                continue
            if alpha >= 255:
                r, g, b = pr[x, y], pg[x, y], pb[x, y]
            else:
                r = (pr[x, y] * 255 + alpha // 2) // alpha
                g = (pg[x, y] * 255 + alpha // 2) // alpha
                b = (pb[x, y] * 255 + alpha // 2) // alpha
                # Soft outer rim only (not mint accent AA).
                if not (g > r + 30 and g > b + 20):
                    r = min(r, bg_cap)
                    g = min(g, bg_cap)
                    b = min(b, bg_cap)
            op[x, y] = (r, g, b, alpha)
    return out


def draw_icon(canvas: int) -> Image.Image:
    # Draw large, then LANCZOS down — curves and `>_` stay anti-aliased (no jaggies / hard mask halo).
    ss = 4
    return _resize_premultiplied(_render(canvas * ss), (canvas, canvas))


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
