#!/usr/bin/env python3
"""Generates the FLEX UP app icon + launch logo (original artwork, drawn procedurally with Pillow).

Mark: a stylised "F" whose middle bar is an arrow pointing up-right ("flex up"),
filled with the violet→turquoise brand gradient on a graphite tile with a soft glow.
Usage: python3 scripts/generate_icons.py   (requires Pillow)
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.join(os.path.dirname(__file__), "..", "FlexUp", "Resources", "Assets.xcassets")
VIOLET = (138, 43, 255)
TEAL = (25, 227, 209)
GRAPHITE = (14, 15, 19)


def gradient(size):
    w, h = size
    g = Image.new("RGB", size)
    px = g.load()
    for y in range(h):
        for x in range(w):
            t = min(1.0, max(0.0, (x / w * 0.55 + (1 - y / h) * 0.45)))
            px[x, y] = tuple(int(VIOLET[i] + (TEAL[i] - VIOLET[i]) * t) for i in range(3))
    return g


def mark_mask(size, box):
    """Polygon mask of the mark inside box=(x0,y0,w,h); mirrors FlexMark in Components.swift."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    x0, y0, w, h = box
    r = int(w * 0.06)
    d.rounded_rectangle([x0 + w * 0.08, y0 + h * 0.18, x0 + w * 0.28, y0 + h * 0.98], radius=r, fill=255)
    d.rounded_rectangle([x0 + w * 0.08, y0 + h * 0.18, x0 + w * 0.70, y0 + h * 0.36], radius=r, fill=255)
    pts = [(0.28, 0.66), (0.70, 0.46), (0.64, 0.38), (0.95, 0.02), (0.92, 0.50), (0.84, 0.44), (0.28, 0.84)]
    d.polygon([(x0 + w * px, y0 + h * py) for px, py in pts], fill=255)
    return m


def icon(size=1024, background=True):
    img = Image.new("RGBA", (size, size), GRAPHITE + (255,) if background else (0, 0, 0, 0))
    if background:
        # Subtle radial violet glow in the corner.
        glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        gd.ellipse([size * 0.35, -size * 0.25, size * 1.25, size * 0.65], fill=VIOLET + (90,))
        gd.ellipse([-size * 0.3, size * 0.55, size * 0.5, size * 1.3], fill=TEAL + (55,))
        glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
        img = Image.alpha_composite(img, glow)
    box = (size * 0.2, size * 0.2, size * 0.6, size * 0.6)
    mask = mark_mask((size, size), box)
    # Neon glow behind the mark.
    halo = Image.new("RGBA", (size, size), VIOLET + (0,))
    halo.putalpha(mask.filter(ImageFilter.GaussianBlur(size * 0.035)).point(lambda v: int(v * 0.85)))
    img = Image.alpha_composite(img, halo)
    fill = gradient((size, size)).convert("RGBA")
    fill.putalpha(mask)
    img = Image.alpha_composite(img, fill)
    return img


def write_json(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)


def main():
    os.makedirs(ROOT, exist_ok=True)
    write_json(os.path.join(ROOT, "Contents.json"), {"info": {"author": "xcode", "version": 1}})

    appicon = os.path.join(ROOT, "AppIcon.appiconset")
    os.makedirs(appicon, exist_ok=True)
    icon(1024).convert("RGB").save(os.path.join(appicon, "AppIcon-1024.png"))  # no alpha for App Store
    write_json(os.path.join(appicon, "Contents.json"), {
        "images": [{"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}})

    launch = os.path.join(ROOT, "LaunchLogo.imageset")
    os.makedirs(launch, exist_ok=True)
    for scale in (1, 2, 3):
        icon(120 * scale, background=False).save(os.path.join(launch, f"LaunchLogo@{scale}x.png"))
    write_json(os.path.join(launch, "Contents.json"), {
        "images": [{"filename": f"LaunchLogo@{s}x.png", "idiom": "universal", "scale": f"{s}x"} for s in (1, 2, 3)],
        "info": {"author": "xcode", "version": 1}})

    def color_set(name, light, dark):
        d = os.path.join(ROOT, f"{name}.colorset")
        os.makedirs(d, exist_ok=True)

        def comp(rgb):
            return {"color-space": "srgb", "components": {"red": f"{rgb[0] / 255:.3f}", "green": f"{rgb[1] / 255:.3f}",
                                                           "blue": f"{rgb[2] / 255:.3f}", "alpha": "1.000"}}
        write_json(os.path.join(d, "Contents.json"), {
            "colors": [
                {"idiom": "universal", "color": comp(light)},
                {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(dark)},
            ],
            "info": {"author": "xcode", "version": 1}})

    color_set("AccentColor", (106, 27, 224), (176, 124, 255))
    color_set("LaunchBackground", GRAPHITE, GRAPHITE)  # brand splash is always graphite
    print("Icons and colours written to", os.path.abspath(ROOT))


if __name__ == "__main__":
    main()
