# -*- coding: utf-8 -*-
"""Apply clean v2 assets + readability polish to save_slot UI."""
import json
from pathlib import Path

ROOT = Path(r"D:\y3\games\2.0\game\LocalData\yeyu")

V2 = {
    "panel_slot": 134282360,
    "panel_slot_selected": 134264868,
    "btn_primary": 134234435,
    "btn_primary_hover": 134277181,
    "btn_primary_pressed": 134264298,
    "btn_secondary": 134257827,
    "btn_secondary_hover": 134273946,
    "btn_danger": 134264627,
    "btn_danger_hover": 134266657,
    "btn_ghost": 134220982,
    "icon_empty": 134259271,
    # keep working transparent deco/portrait if still ok
    "deco_left": 134254990,
    "deco_right": 134227534,
    "portrait": 134253687,
    "portrait_ring": 134270566,
    "bg": 134230791,
}


def tup(items):
    return {"__tuple__": True, "items": list(items)}


def rgba(r, g, b, a=255):
    return [int(r), int(g), int(b), int(a)]


def find(n, name):
    if n.get("name") == name:
        return n
    for c in n.get("children") or []:
        r = find(c, name)
        if r:
            return r
    return None


def set_size(n, w, h):
    n["size"] = tup([float(w), float(h)])


def set_pos_pct(n, x, y, pw, ph):
    n["pos_data"] = tup(
        [float(x), float(y), round(x / pw * 100, 4), round(y / ph * 100, 4), 1, 1]
    )


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(path, doc):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=4)
        f.write("\n")


def polish_button(btn, label, normal, hover, press, text_color):
    spaced = label[0] + "  " + label[1] if len(label) == 2 else label
    set_size(btn, 180, 56)
    btn["font"] = tup(["MSYH", 20])
    btn["normal_picture"] = normal
    btn["suspend_picture"] = hover
    btn["press_picture"] = press
    btn["disabled_picture"] = normal
    for k in ("normal_text", "suspend_text", "press_text", "disabled_text"):
        btn[k] = tup([spaced, False])
    for k in ("normal_font_color", "suspend_font_color", "press_font_color"):
        btn[k] = text_color
    btn["disabled_font_color"] = rgba(120, 120, 120)
    btn["hover_status_added"] = True
    btn["pressed_status_added"] = True
    btn["disabled_status_added"] = True
    btn["visible"] = True
    btn["opacity"] = 1.0
    btn["open_adapter"] = False
    btn["color"] = rgba(255, 255, 255)


def main():
    # --- prefab ---
    prefab_path = ROOT / "maps/EntryMap/ui/prefab/save_slot_card.json"
    prefab = load(prefab_path)
    root = prefab["data"]
    for c in root.get("children") or []:
        name = c.get("name")
        if name == "frame":
            c["image"] = V2["panel_slot"]
            c["color"] = rgba(255, 255, 255)
            c["visible"] = True
        elif name == "empty_icon":
            c["image"] = V2["icon_empty"]
            c["color"] = rgba(255, 255, 255)
            c["visible"] = True
        elif name == "portrait":
            c["image"] = V2["portrait"]
            c["color"] = rgba(255, 255, 255)
            c["visible"] = False
        elif name == "portrait_ring":
            c["image"] = V2["portrait_ring"]
            c["visible"] = False
        elif name == "selected_mark":
            c["visible"] = False  # never show gold pill on empty
            c["image"] = V2["btn_primary"]
        elif name == "index":
            c["font"] = tup(["MSYH", 16])
            c["font_color"] = rgba(232, 208, 154)
            c["alignment"] = tup([2, 8])
        elif name == "tishi":
            for t in c.get("children") or []:
                tn = t.get("name")
                t["alignment"] = tup([2, 8])
                t["visible"] = True
                if tn == "name":
                    t["font"] = tup(["MSYH", 24])
                    t["font_color"] = rgba(240, 220, 170)
                    t["text"] = tup(["空 位", False])
                    set_size(t, 220, 40)
                elif tn == "chapter":
                    t["font"] = tup(["MSYH", 15])
                    t["font_color"] = rgba(180, 195, 190)
                    t["text"] = tup(["尚未立档", False])
                    set_size(t, 220, 30)
                elif tn == "time":
                    t["font"] = tup(["MSYH", 14])
                    t["font_color"] = rgba(140, 160, 155)
                    t["text"] = tup(["点击新建角色", False])
                    set_size(t, 220, 36)
    save(prefab_path, prefab)

    # --- panel ---
    panel_path = ROOT / "maps/EntryMap/ui/save_slot.json"
    doc = load(panel_path)

    bg = find(doc, "image_bg")
    if bg:
        bg["image"] = V2["bg"]
        bg["opacity"] = 0.72  # darker for contrast
        bg["color"] = rgba(20, 28, 30)

    title = find(doc, "角色选择")
    if title:
        title["text"] = tup(["选择角色", False])
        title["font"] = tup(["HKWeiBeiW7", 68])
        title["font_color"] = rgba(240, 215, 140)
        title["alignment"] = tup([2, 8])

    left = find(doc, "image_left")
    if left:
        left["image"] = V2["deco_left"]
        left["color"] = rgba(255, 255, 255)
        set_size(left, 300, 28)
    right = find(doc, "image_right")
    if right:
        right["image"] = V2["deco_right"]
        right["color"] = rgba(255, 255, 255)
        right["scale"] = tup([1.0, 1.0])
        set_size(right, 300, 28)

    # five cards
    labels = ["位 一", "位 二", "位 三", "位 四", "位 五"]
    xs = [316.0, 638.0, 960.0, 1282.0, 1604.0]
    for i in range(1, 6):
        card = find(doc, f"save_slot_card_{i}")
        if not card:
            continue
        set_size(card, 300, 520)
        set_pos_pct(card, xs[i - 1], 260, 1920, 520)
        for c in card.get("children") or []:
            n = c.get("name")
            if n == "frame":
                c["image"] = V2["panel_slot"]
                c["color"] = rgba(255, 255, 255)
            elif n == "empty_icon":
                c["image"] = V2["icon_empty"]
                c["color"] = rgba(255, 255, 255)
                c["visible"] = True
            elif n == "portrait":
                c["image"] = V2["portrait"]
                c["visible"] = False
            elif n == "portrait_ring":
                c["visible"] = False
            elif n == "selected_mark":
                c["visible"] = False
            elif n == "index":
                c["text"] = tup([labels[i - 1], False])
                c["font"] = tup(["MSYH", 16])
                c["font_color"] = rgba(232, 208, 154)
                c["alignment"] = tup([2, 8])
            elif n == "tishi":
                for t in c.get("children") or []:
                    tn = t.get("name")
                    t["alignment"] = tup([2, 8])
                    if tn == "name":
                        t["font"] = tup(["MSYH", 24])
                        t["font_color"] = rgba(240, 220, 170)
                        t["text"] = tup(["空 位", False])
                    elif tn == "chapter":
                        t["font"] = tup(["MSYH", 15])
                        t["font_color"] = rgba(180, 195, 190)
                        t["text"] = tup(["尚未立档", False])
                    elif tn == "time":
                        t["font"] = tup(["MSYH", 14])
                        t["font_color"] = rgba(150, 170, 165)
                        t["text"] = tup(["点击新建角色", False])

    tip = find(doc, "Lable_提示")
    if tip:
        tip["text"] = tup(["点选角色位 · 空位可新建 · 有档可进入", False])
        tip["font"] = tup(["MSYH", 18])
        tip["font_color"] = rgba(220, 195, 130)
        tip["alignment"] = tup([2, 8])
        tip["opacity"] = 1.0

    # buttons — high contrast text
    polish_button(
        find(doc, "button_返回"),
        "返回",
        V2["btn_ghost"],
        V2["btn_ghost"],
        V2["btn_ghost"],
        rgba(230, 230, 230),
    )
    polish_button(
        find(doc, "button_删除"),
        "删除",
        V2["btn_danger"],
        V2["btn_danger_hover"],
        V2["btn_danger"],
        rgba(255, 230, 220),
    )
    polish_button(
        find(doc, "button_新建"),
        "新建",
        V2["btn_secondary"],
        V2["btn_secondary_hover"],
        V2["btn_secondary"],
        rgba(240, 220, 160),
    )
    polish_button(
        find(doc, "button_进入"),
        "进入",
        V2["btn_primary"],
        V2["btn_primary_hover"],
        V2["btn_primary_pressed"],
        rgba(30, 22, 10),  # dark on gold
    )
    # even positions
    for name, x in [
        ("button_返回", 180),
        ("button_删除", 400),
        ("button_新建", 680),
        ("button_进入", 900),
    ]:
        b = find(doc, name)
        if b:
            set_pos_pct(b, x, 40, 1080, 80)

    layout_btn = find(doc, "layout_button")
    if layout_btn:
        set_size(layout_btn, 1080, 80)
        set_pos_pct(layout_btn, 960, 100, 1920, 1080)

    save(panel_path, doc)

    # icon map
    (ROOT / "assets/ui/save_slot/icon_ids.json").write_text(
        json.dumps(
            {
                "version": "v2_clean",
                "note": "Clean UI set: smooth panel, high-contrast buttons, magenta-keyed alpha. Prefer these IDs.",
                "icons": {k: {"icon_id": v} for k, v in V2.items()},
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    print("applied v2 clean assets")


if __name__ == "__main__":
    main()
