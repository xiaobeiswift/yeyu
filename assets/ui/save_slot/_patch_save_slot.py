# -*- coding: utf-8 -*-
"""Configure save_slot panel properties (layout / icons / texts / buttons)."""
import json
from copy import deepcopy

PATH = r"D:\y3\games\2.0\game\LocalData\yeyu\maps\EntryMap\ui\save_slot.json"

# icons (TGA alpha packages: *_2 / *_3)
BG = 134230791
DECO_L = 134254990
DECO_R = 134227534
BTN_GHOST = 134264308
BTN_DANGER_N = 134262316
BTN_DANGER_H = 134270167
BTN_SEC_N = 134251056
BTN_SEC_H = 134239083
BTN_PRI_N = 134236853
BTN_PRI_H = 134254184
BTN_PRI_P = 134231881

INDEX_LABELS = ["位 一", "位 二", "位 三", "位 四", "位 五"]
# card center X in layout_slot (1920 x 520), Y=260
CARD_XS = [316.0, 638.0, 960.0, 1282.0, 1604.0]


def tup(items):
    return {"__tuple__": True, "items": list(items)}


def set_size(n, w, h):
    n["size"] = tup([float(w), float(h)])


def set_pos(n, x, y, parent_w=None, parent_h=None, mode=0):
    """mode 0: keep as absolute-focused; still fill percent when parent known."""
    if parent_w and parent_h:
        px = round(float(x) / float(parent_w) * 100, 4)
        py = round(float(y) / float(parent_h) * 100, 4)
        n["pos_data"] = tup([float(x), float(y), px, py, 1, 1])
    else:
        # preserve mode flags if present
        old = n.get("pos_data", {}).get("items", [x, y, 50, 50, 0, 0])
        mx = old[4] if len(old) > 4 else 0
        my = old[5] if len(old) > 5 else 0
        px = old[2] if len(old) > 2 else 50
        py = old[3] if len(old) > 3 else 50
        n["pos_data"] = tup([float(x), float(y), float(px), float(py), mx, my])


def set_pos_pct(n, x, y, parent_w, parent_h):
    px = round(float(x) / float(parent_w) * 100, 4)
    py = round(float(y) / float(parent_h) * 100, 4)
    n["pos_data"] = tup([float(x), float(y), px, py, 1, 1])


def ensure_anchor(n, ax=0.5, ay=0.5):
    n["anchor"] = tup([ax, ay])


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


def find_all(n, name, acc=None):
    if acc is None:
        acc = []
    if n.get("name") == name:
        acc.append(n)
    for c in n.get("children") or []:
        find_all(c, name, acc)
    return acc


def configure_button(btn, *, text, normal, hover=None, press=None, font_color=None, size=(160, 52)):
    hover = hover or normal
    press = press or hover
    font_color = font_color or rgba(232, 208, 154)
    dark_ink = rgba(11, 18, 20)
    # primary uses dark text on gold
    is_primary = normal == BTN_PRI_N
    nfc = dark_ink if is_primary else font_color
    danger = normal == BTN_DANGER_N
    if danger:
        nfc = rgba(240, 200, 192)

    spaced = text
    if len(text) == 2 and " " not in text:
        spaced = text[0] + "  " + text[1]

    set_size(btn, size[0], size[1])
    ensure_anchor(btn, 0.5, 0.5)
    btn["font"] = tup(["MSYH", 18])
    btn["normal_picture"] = int(normal)
    btn["suspend_picture"] = int(hover)
    btn["press_picture"] = int(press)
    btn["disabled_picture"] = int(normal)
    btn["normal_text"] = tup([spaced, False])
    btn["suspend_text"] = tup([spaced, False])
    btn["press_text"] = tup([spaced, False])
    btn["disabled_text"] = tup([spaced, False])
    btn["normal_font_color"] = nfc
    btn["suspend_font_color"] = nfc
    btn["press_font_color"] = nfc
    btn["disabled_font_color"] = rgba(120, 120, 120)
    btn["hover_status_added"] = True
    btn["pressed_status_added"] = True
    btn["disabled_status_added"] = True
    btn["visible"] = True
    btn["opacity"] = 1.0
    btn["open_adapter"] = False
    btn["can_drag"] = False


def main():
    with open(PATH, "r", encoding="utf-8") as f:
        doc = json.load(f)

    # --- root ---
    doc["visible"] = True
    doc["opacity"] = 1.0
    doc["zorder"] = 400

    layout_main = find(doc, "layout_main")
    if layout_main:
        set_size(layout_main, 1920, 1080)
        set_pos_pct(layout_main, 960, 540, 1920, 1080)
        layout_main["can_drag"] = False
        layout_main["open_adapter"] = False

    # --- bg ---
    bg = find(doc, "image_bg")
    if bg:
        bg["image"] = BG
        set_size(bg, 1920, 1080)
        set_pos_pct(bg, 960, 540, 1920, 1080)
        bg["opacity"] = 0.55
        bg["color"] = rgba(40, 48, 50)
        bg["visible"] = True
        bg["can_drag"] = False
        bg["open_adapter"] = False
        ensure_anchor(bg)

    # --- title band ---
    title_band = find(doc, "text")
    if title_band:
        set_size(title_band, 1600, 140)
        # near top of screen in layout_main coords
        set_pos_pct(title_band, 960, 980, 1920, 1080)
        title_band["can_drag"] = False
        title_band["open_adapter"] = False

    title = find(doc, "角色选择")
    if title:
        title["text"] = tup(["选择角色", False])
        title["font"] = tup(["HKWeiBeiW7", 64])
        title["font_color"] = rgba(232, 208, 154)
        title["alignment"] = tup([2, 8])
        set_size(title, 420, 72)
        # local to title_band 1600x140
        set_pos_pct(title, 800, 78, 1600, 140)
        title["open_adapter"] = False
        ensure_anchor(title)
        if "shadow" in title or True:
            title["shadow"] = True
            title["text_shadow_color"] = rgba(0, 0, 0, 200)
            title["text_shadow_offset"] = tup([2, -2])

    left = find(doc, "image_left")
    if left:
        left["image"] = DECO_L
        set_size(left, 320, 36)
        # left of title: title center 800, half-width 210 -> left tip near 590
        set_pos_pct(left, 430, 78, 1600, 140)
        left["open_adapter"] = False
        left["opacity"] = 1.0
        left["scale"] = tup([1.0, 1.0])
        left["color"] = rgba(255, 255, 255)
        ensure_anchor(left)
        # disable broken adapter
        left["adapter_option"] = [False, False, False, False, 0, 0, 0, 0]

    right = find(doc, "image_right")
    if right:
        right["image"] = DECO_R
        set_size(right, 320, 36)
        set_pos_pct(right, 1170, 78, 1600, 140)
        right["open_adapter"] = False
        right["opacity"] = 1.0
        right["scale"] = tup([1.0, 1.0])
        right["color"] = rgba(255, 255, 255)
        ensure_anchor(right)
        right["adapter_option"] = [False, False, False, False, 0, 0, 0, 0]

    # --- slots row ---
    layout_slot = find(doc, "layout_slot")
    if layout_slot:
        set_size(layout_slot, 1920, 520)
        set_pos_pct(layout_slot, 960, 540, 1920, 1080)
        layout_slot["can_drag"] = False
        layout_slot["open_adapter"] = False

    for i in range(1, 6):
        card = find(doc, f"save_slot_card_{i}")
        if not card:
            continue
        set_size(card, 300, 520)
        set_pos_pct(card, CARD_XS[i - 1], 260, 1920, 520)
        card["can_drag"] = False
        ensure_anchor(card)

        # patch children that are inlined instances
        idx = None
        for c in card.get("children") or []:
            if c.get("name") == "index":
                idx = c
            if c.get("name") == "selected_mark":
                c["visible"] = False
            if c.get("name") == "portrait_ring":
                c["visible"] = False
            if c.get("name") == "portrait":
                c["visible"] = False
            if c.get("name") == "empty_icon":
                c["visible"] = True
            # text colors / align inside tishi
            if c.get("name") == "tishi":
                for t in c.get("children") or []:
                    if t.get("type") == 3 or t.get("comp_type") == "TextLabel":
                        t["alignment"] = tup([2, 8])
                        if t.get("name") == "name":
                            t["font"] = tup(["MSYH", 22])
                            t["font_color"] = rgba(232, 208, 154)
                            t["text"] = tup(["空 位", False])
                            set_size(t, 200, 40)
                        elif t.get("name") == "chapter":
                            t["font"] = tup(["MSYH", 14])
                            t["font_color"] = rgba(168, 184, 182)
                            t["text"] = tup(["尚未立档", False])
                            set_size(t, 200, 30)
                        elif t.get("name") == "time":
                            t["font"] = tup(["MSYH", 13])
                            t["font_color"] = rgba(106, 124, 126)
                            t["text"] = tup(["点「新建」创建角色", False])
                            set_size(t, 220, 40)
        if idx:
            idx["text"] = tup([INDEX_LABELS[i - 1], False])
            idx["font"] = tup(["MSYH", 16])
            idx["font_color"] = rgba(201, 164, 92)
            idx["alignment"] = tup([2, 8])

    # --- message ---
    layout_tip = find(doc, "layout_提示")
    if layout_tip:
        set_size(layout_tip, 900, 40)
        set_pos_pct(layout_tip, 960, 220, 1920, 1080)
        layout_tip["can_drag"] = False

    tip = find(doc, "Lable_提示")
    if tip:
        tip["text"] = tup(["点选角色位 · 空位可新建 · 有档可进入", False])
        tip["font"] = tup(["MSYH", 16])
        tip["font_color"] = rgba(201, 164, 92)
        tip["alignment"] = tup([2, 8])
        set_size(tip, 900, 40)
        set_pos_pct(tip, 450, 20, 900, 40)
        tip["open_adapter"] = False
        tip["visible"] = True
        ensure_anchor(tip)

    # --- buttons ---
    layout_btn = find(doc, "layout_button")
    if layout_btn:
        set_size(layout_btn, 1080, 80)
        set_pos_pct(layout_btn, 960, 100, 1920, 1080)
        layout_btn["can_drag"] = False

    # even centers in 1080 panel, y=40
    btn_specs = [
        ("button_返回", "返回", BTN_GHOST, BTN_GHOST, BTN_GHOST, 180),
        ("button_删除", "删除", BTN_DANGER_N, BTN_DANGER_H, BTN_DANGER_N, 400),
        ("button_新建", "新建", BTN_SEC_N, BTN_SEC_H, BTN_SEC_N, 680),
        ("button_进入", "进入", BTN_PRI_N, BTN_PRI_H, BTN_PRI_P, 900),
    ]
    for name, label, n, h, p, x in btn_specs:
        btn = find(doc, name)
        if not btn:
            continue
        configure_button(btn, text=label, normal=n, hover=h, press=p, size=(168, 52))
        set_pos_pct(btn, x, 40, 1080, 80)

    with open(PATH, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=4)
        f.write("\n")

    print("patched", PATH)
    # summary
    for name in [
        "image_bg",
        "角色选择",
        "image_left",
        "image_right",
        "Lable_提示",
        "button_返回",
        "button_删除",
        "button_新建",
        "button_进入",
        "save_slot_card_1",
        "save_slot_card_5",
    ]:
        n = find(doc, name)
        if not n:
            print("MISSING", name)
            continue
        size = n.get("size")
        if isinstance(size, dict):
            size = size.get("items")
        pos = n.get("pos_data")
        if isinstance(pos, dict):
            pos = pos.get("items")
        print(
            f"{name:16} img={n.get('image') or n.get('normal_picture')} "
            f"size={size} pos={pos[:2] if pos else None} "
            f"text={n.get('text') or n.get('normal_text')}"
        )


if __name__ == "__main__":
    main()
