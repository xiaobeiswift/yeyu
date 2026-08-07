# -*- coding: utf-8 -*-
"""Generate import-ready create_character UI slices (PNG)."""
from __future__ import print_function

import os

from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated")


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path, "PNG")
    print("wrote", name, img.size)


def rounded_rect(draw, box, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=width)


def make_stage_frame():
    w, h = 560, 640
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_rect(
        d, (8, 8, w - 9, h - 9), 28,
        fill=(22, 30, 28, 210), outline=(180, 160, 110, 180), width=3,
    )
    rounded_rect(
        d, (24, 24, w - 25, h - 25), 22,
        fill=(12, 18, 16, 40), outline=(120, 140, 130, 90), width=2,
    )
    vign = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vign)
    for i in range(40):
        a = int(4 + i * 1.2)
        vd.ellipse((40 + i, 60 + i, w - 40 - i, h - 40 - i), outline=(8, 12, 10, a))
    img = Image.alpha_composite(img, vign)
    d = ImageDraw.Draw(img)
    gold = (212, 181, 106, 200)
    for cx, cy in [(40, 40), (w - 40, 40), (40, h - 40), (w - 40, h - 40)]:
        d.line([(cx - 14, cy), (cx + 14, cy)], fill=gold, width=2)
        d.line([(cx, cy - 14), (cx, cy + 14)], fill=gold, width=2)
    save(img, "panel_stage_frame.png")


def make_detail_panel():
    w, h = 380, 620
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_rect(
        d, (10, 10, w - 11, h - 11), 18,
        fill=(18, 26, 24, 235), outline=(160, 145, 100, 160), width=2,
    )
    d.rectangle((30, 28, w - 30, 32), fill=(90, 120, 90, 120))
    rounded_rect(
        d, (28, 48, w - 29, h - 29), 12,
        fill=None, outline=(100, 120, 110, 70), width=1,
    )
    d.ellipse((w - 78, h - 78, w - 34, h - 34), outline=(154, 56, 48, 180), width=2)
    save(img, "panel_detail.png")


def make_roster(selected=False):
    w, h = 280, 72
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if selected:
        fill = (36, 44, 40, 240)
        outline = (212, 181, 106, 230)
        width = 3
        tick_a = 200
        name = "panel_roster_item_selected.png"
    else:
        fill = (24, 32, 30, 220)
        outline = (120, 140, 130, 140)
        width = 2
        tick_a = 100
        name = "panel_roster_item.png"
    rounded_rect(d, (2, 2, w - 3, h - 3), 12, fill=fill, outline=outline, width=width)
    d.rectangle((10, 18, 14, h - 18), fill=(212, 181, 106, tick_a))
    save(img, name)


def make_bars():
    w, h = 220, 14
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded_rect(
        d, (0, 0, w - 1, h - 1), 6,
        fill=(36, 44, 42, 230), outline=(70, 80, 76, 160), width=1,
    )
    save(img, "bar_stat_track.png")
    img2 = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d2 = ImageDraw.Draw(img2)
    rounded_rect(d2, (0, 0, w - 1, h - 1), 6, fill=(200, 170, 100, 255))
    save(img2, "bar_stat_fill.png")


def make_deco():
    w, h = 300, 28
    for side in ("left", "right"):
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        y = h // 2
        gold = (212, 181, 106, 180)
        if side == "left":
            d.line([(10, y), (w - 20, y)], fill=gold, width=2)
            d.polygon([(w - 8, y), (w - 22, y - 6), (w - 22, y + 6)], fill=gold)
        else:
            d.line([(20, y), (w - 10, y)], fill=gold, width=2)
            d.polygon([(8, y), (22, y - 6), (22, y + 6)], fill=gold)
        save(img, "deco_title_%s.png" % side)


def make_model_placeholder():
    w, h = 480, 560
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.ellipse((90, 420, 390, 520), fill=(20, 30, 28, 120))
    ink = (154, 170, 164, 200)
    d.ellipse((210, 90, 270, 160), outline=ink, width=4)
    d.line([(240, 160), (240, 300)], fill=ink, width=5)
    d.line([(240, 200), (170, 260)], fill=ink, width=4)
    d.line([(240, 200), (310, 250)], fill=ink, width=4)
    d.line([(310, 250), (340, 140)], fill=(212, 181, 106, 180), width=3)
    d.line([(240, 300), (200, 420)], fill=ink, width=5)
    d.line([(240, 300), (280, 420)], fill=ink, width=5)
    wash = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    wd = ImageDraw.Draw(wash)
    for i in range(20):
        wd.ellipse(
            (40 + i * 3, 80 + i * 2, w - 40 - i * 3, h - 60 - i * 2),
            outline=(100, 120, 110, 8),
        )
    img = Image.alpha_composite(img, wash)
    save(img, "model_placeholder.png")


def make_wireframe():
    w, h = 1920, 1080
    img = Image.new("RGBA", (w, h), (10, 14, 12, 255))
    bg_path = os.path.join(OUT, "bg_fog_clock.jpg")
    if os.path.exists(bg_path):
        bg = Image.open(bg_path).convert("RGBA").resize((w, h))
        overlay = Image.new("RGBA", (w, h), (8, 12, 12, 160))
        img = Image.alpha_composite(bg, overlay)
    d = ImageDraw.Draw(img)
    regions = [
        (40, 140, 320, 900, "layout_roster"),
        (420, 120, 980, 900, "layout_stage + model_preview"),
        (1040, 140, 1860, 900, "layout_detail"),
        (0, 0, 1920, 100, "layout_title"),
        (0, 980, 1920, 1080, "layout_button + layout_tip"),
    ]
    for x1, y1, x2, y2, label in regions:
        d.rectangle((x1, y1, x2, y2), outline=(212, 181, 106, 160), width=2)
        d.text((x1 + 12, y1 + 12), label, fill=(232, 208, 154, 220))
    d.text((860, 36), "create_character 1920x1080", fill=(232, 208, 154, 255))
    save(img, "layout_wireframe_1920.png")


def main():
    os.makedirs(OUT, exist_ok=True)
    make_stage_frame()
    make_detail_panel()
    make_roster(False)
    make_roster(True)
    make_bars()
    make_deco()
    make_model_placeholder()
    make_wireframe()
    print("done ->", OUT)


if __name__ == "__main__":
    main()
