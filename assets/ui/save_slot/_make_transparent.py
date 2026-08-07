# -*- coding: utf-8 -*-
"""Strip solid dark UI generation backgrounds to real alpha."""
from pathlib import Path
from collections import deque
from PIL import Image

GEN = Path(r"D:\y3\games\2.0\game\LocalData\yeyu\assets\ui\save_slot\generated")
BAK = GEN / "_opaque_src"
PKG = Path(r"D:\y3\games\2.0\game\LocalData\yeyu\custom\OriginalRes\icon")

# All UI cutouts that need outer transparency
FILES = [
    "btn_primary_normal.png",
    "btn_primary_hover.png",
    "btn_primary_pressed.png",
    "btn_secondary_normal.png",
    "btn_secondary_hover.png",
    "btn_danger_normal.png",
    "btn_danger_hover.png",
    "btn_ghost_normal.png",
    "panel_slot.png",
    "panel_slot_selected.png",
    "panel_modal.png",
    "icon_empty_slot.png",
    "icon_cloud_lock.png",
    "icon_backend_local.png",
    "icon_backend_cloud.png",
    "portrait_placeholder.png",
    "portrait_ring.png",
    "deco_title_line_left.png",
    "deco_title_line_right.png",
]


def is_bg_rgb(r, g, b, ref=(26, 26, 26), dist=32, max_chroma=22):
    """Near solid #1a1a1a generation background."""
    dr, dg, db = r - ref[0], g - ref[1], b - ref[2]
    if dr * dr + dg * dg + db * db <= dist * dist:
        return True
    # near-black flat
    mx, mn = max(r, g, b), min(r, g, b)
    if mx <= 38 and (mx - mn) <= max_chroma:
        return True
    return False


def flood_alpha(im: Image.Image) -> Image.Image:
    """Flood from edges through background-like pixels -> alpha 0."""
    im = im.convert("RGBA")
    w, h = im.size
    px = im.load()
    visited = [[False] * w for _ in range(h)]
    q = deque()

    def try_push(x, y):
        if x < 0 or y < 0 or x >= w or y >= h or visited[y][x]:
            return
        r, g, b, a = px[x, y]
        if not is_bg_rgb(r, g, b):
            return
        visited[y][x] = True
        q.append((x, y))

    # seed all border pixels that look like bg
    for x in range(w):
        try_push(x, 0)
        try_push(x, h - 1)
    for y in range(h):
        try_push(0, y)
        try_push(w - 1, y)

    while q:
        x, y = q.popleft()
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            try_push(nx, ny)

    # write alpha
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if visited[y][x]:
                px[x, y] = (r, g, b, 0)
            else:
                # soft fringe: near-bg but not flooded (anti-alias on subject edge)
                if is_bg_rgb(r, g, b, dist=40, max_chroma=28):
                    # keep partial alpha only if not pure bg; already not flooded so subject-adjacent
                    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    chroma = max(r, g, b) - min(r, g, b)
                    if chroma < 12 and lum < 45:
                        px[x, y] = (r, g, b, min(a, 40))
                    else:
                        px[x, y] = (r, g, b, 255)
                else:
                    px[x, y] = (r, g, b, 255)
    return im


def process_one(name: str):
    src = GEN / name
    if not src.exists():
        print("skip missing", name)
        return
    BAK.mkdir(parents=True, exist_ok=True)
    bak = BAK / name
    if not bak.exists():
        # if current already transparent, prefer opaque backup if present
        alt = GEN / name.replace(".png", "_opaque_bg.png")
        if alt.exists():
            bak.write_bytes(alt.read_bytes())
        else:
            bak.write_bytes(src.read_bytes())

    im = Image.open(bak)
    out = flood_alpha(im)
    out.save(src, "PNG")
    # stats
    a = out.split()[3]
    zeros = sum(1 for v in a.getdata() if v == 0)
    total = out.size[0] * out.size[1]
    print(f"{name}: transparent={100*zeros/total:.1f}%  size={out.size}")

    # overwrite package copies if any
    stem = name.replace(".png", "")
    for pkg_name in (stem, f"{stem}_1"):
        pkg = PKG / f"{pkg_name}.package"
        if not pkg.is_dir():
            continue
        for png in pkg.glob("*.png"):
            out.save(png, "PNG")
            print(f"  -> package {pkg_name}/{png.name}")


def main():
    for name in FILES:
        process_one(name)
    print("done")


if __name__ == "__main__":
    main()
