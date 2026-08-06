# -*- coding: utf-8 -*-
"""Patch save_slot_card prefab layout / icons / default texts."""
import json

path = r"D:\y3\games\2.0\game\LocalData\yeyu\maps\EntryMap\ui\prefab\save_slot_card.json"
with open(path, "r", encoding="utf-8") as f:
    doc = json.load(f)

PANEL = 134262246  # panel_slot_2 tga alpha
EMPTY = 134273868  # icon_empty_slot_2
RING = 134270566  # portrait_ring_2
PORTRAIT_PLACEHOLDER = 134253687  # portrait_placeholder_2
MARK = 134236853  # btn_primary_normal_2


def tup(items):
    return {"__tuple__": True, "items": list(items)}


# pos_data = [abs_x, abs_y, percent_x, percent_y, mode_x, mode_y]
# percent 是相对父节点的位置比例（不是锚点）。锚点在 anchor 字段。
PARENT_W, PARENT_H = 300.0, 520.0


def set_pos(node, x, y, mx=1, my=1):
    px = round(float(x) / PARENT_W * 100, 4)
    py = round(float(y) / PARENT_H * 100, 4)
    node["pos_data"] = tup([float(x), float(y), px, py, mx, my])
    node["anchor"] = tup([0.5, 0.5])


def set_size(node, w, h):
    node["size"] = tup([float(w), float(h)])


def set_font(node, size, r, g, b, a=255):
    node["font"] = tup(["MSYH", int(size)])
    node["font_color"] = tup([int(r), int(g), int(b), int(a)])
    node["font_min_size"] = max(12, int(size) - 4)


def set_text(node, s):
    node["text"] = tup([str(s), False])


def set_align_center(node):
    # H: 1左 2中 4右 · V: 0上 8中 16下
    node["alignment"] = tup([2, 8])


root = doc["data"]
root["size"] = tup([300.0, 520.0])
root["open_adapter"] = False
root["adapter_option"] = [False, False, False, False, 0.0, 0.0, 0.0, 0.0]
root["opacity"] = 1.0
root["visible"] = True
if "clip_enabled" in root:
    root["clip_enabled"] = False

# parent 300x520, center (150, 260), Y up
LAYOUT = {
    "frame": (150, 260, 300, 520),
    "index": (150, 478, 240, 32),
    "portrait": (150, 360, 132, 132),
    "empty_icon": (150, 360, 132, 132),
    "portrait_ring": (150, 360, 160, 160),
    "name": (150, 248, 260, 40),
    "chapter": (150, 204, 260, 30),
    "time": (150, 162, 260, 48),
    "selected_mark": (150, 42, 120, 28),
}

by = {c["name"]: c for c in root["children"]}
missing = [k for k in LAYOUT if k not in by]
if missing:
    raise SystemExit("missing nodes: " + ",".join(missing))

n = by["frame"]
set_pos(n, LAYOUT["frame"][0], LAYOUT["frame"][1])
set_size(n, LAYOUT["frame"][2], LAYOUT["frame"][3])
n["image"] = PANEL
n["open_adapter"] = False
n["is_scale9_enable"] = False
n["visible"] = True
n["opacity"] = 1.0
n["cap_insets"] = tup([48, 48, 48, 48])

n = by["index"]
set_pos(n, *LAYOUT["index"][:2])
set_size(n, *LAYOUT["index"][2:])
set_font(n, 16, 201, 164, 92)
set_text(n, "位 一")
set_align_center(n)
n["open_adapter"] = False
n["visible"] = True
n["shadow"] = True
n["text_shadow_color"] = tup([0, 0, 0, 180])
n["text_shadow_offset"] = tup([1, -1])

n = by["portrait"]
set_pos(n, *LAYOUT["portrait"][:2])
set_size(n, *LAYOUT["portrait"][2:])
n["image"] = PORTRAIT_PLACEHOLDER
n["open_adapter"] = False
n["visible"] = False
n["opacity"] = 1.0

n = by["empty_icon"]
set_pos(n, *LAYOUT["empty_icon"][:2])
set_size(n, *LAYOUT["empty_icon"][2:])
n["image"] = EMPTY
n["open_adapter"] = False
n["visible"] = True
n["opacity"] = 1.0

n = by["portrait_ring"]
set_pos(n, *LAYOUT["portrait_ring"][:2])
set_size(n, *LAYOUT["portrait_ring"][2:])
n["image"] = RING
n["open_adapter"] = False
n["visible"] = False
n["opacity"] = 1.0

n = by["name"]
set_pos(n, *LAYOUT["name"][:2])
set_size(n, *LAYOUT["name"][2:])
set_font(n, 22, 232, 208, 154)
set_text(n, "空 位")
set_align_center(n)
n["open_adapter"] = False
n["visible"] = True
n["shadow"] = True
n["text_shadow_color"] = tup([0, 0, 0, 200])
n["text_shadow_offset"] = tup([1, -1])

n = by["chapter"]
set_pos(n, *LAYOUT["chapter"][:2])
set_size(n, *LAYOUT["chapter"][2:])
set_font(n, 14, 168, 184, 182)
set_text(n, "尚未立档")
set_align_center(n)
n["open_adapter"] = False
n["visible"] = True

n = by["time"]
set_pos(n, *LAYOUT["time"][:2])
set_size(n, *LAYOUT["time"][2:])
set_font(n, 13, 106, 124, 126)
set_text(n, "点「新建」创建角色")
set_align_center(n)
n["open_adapter"] = False
n["visible"] = True

n = by["selected_mark"]
set_pos(n, *LAYOUT["selected_mark"][:2])
set_size(n, *LAYOUT["selected_mark"][2:])
n["image"] = MARK
n["open_adapter"] = False
n["visible"] = False
n["opacity"] = 0.95

with open(path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=False, indent=4)
    f.write("\n")

print("patched", path)
for c in doc["data"]["children"]:
    sz = c["size"]["items"]
    pos = c["pos_data"]["items"]
    tx = c.get("text", {}).get("items", ["-"])[0] if isinstance(c.get("text"), dict) else "-"
    print(
        f"{c['name']:16} vis={str(c['visible']):5} img={c.get('image')} "
        f"size={sz} pos=({pos[0]},{pos[1]}) text={tx}"
    )
