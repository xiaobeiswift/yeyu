# -*- coding: utf-8 -*-
"""Retarget save_slot UI JSON to transparent icon IDs."""
import json
from pathlib import Path

# logical -> new transparent icon_id
NEW = {
    # old IDs -> new
    134248131: 134227373,  # btn_primary_normal
    134218584: 134278658,  # btn_primary_hover
    134231186: 134268501,  # btn_primary_pressed
    134242431: 134265660,  # btn_secondary_normal
    134246465: 134279658,  # btn_secondary_hover
    134244576: 134280729,  # btn_danger_normal
    134272161: 134245286,  # btn_danger_hover
    134269797: 134220887,  # btn_ghost_normal
    134266962: 134224739,  # panel_slot
    134226841: 134223904,  # panel_slot_selected
    134228414: 134229656,  # panel_modal
    134244552: 134239404,  # icon_empty_slot
    134262480: 134232798,  # portrait_placeholder
    134259647: 134269431,  # portrait_ring
    134241741: 134268749,  # deco left (was _1 transparent)
    134263686: 134282527,  # deco right
    134253971: 134268749,  # old opaque left
    134275516: 134282527,  # old opaque right
    134250496: 134250496,  # cloud lock not reimported latest - leave
}

IMAGE_KEYS = {
    "image",
    "normal_picture",
    "suspend_picture",
    "press_picture",
    "disabled_picture",
    "bg_image",
    "mask_image",
}


def remap_node(n, stats):
    for k in IMAGE_KEYS:
        if k in n and isinstance(n[k], int) and n[k] in NEW:
            old = n[k]
            n[k] = NEW[old]
            stats[old] = stats.get(old, 0) + 1
    for c in n.get("children") or []:
        remap_node(c, stats)


def remap_file(path: Path):
    with open(path, "r", encoding="utf-8") as f:
        doc = json.load(f)
    stats = {}
    if "data" in doc and isinstance(doc["data"], dict):
        remap_node(doc["data"], stats)
    else:
        remap_node(doc, stats)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=4)
        f.write("\n")
    print(path.name, stats)


def main():
    root = Path(r"D:\y3\games\2.0\game\LocalData\yeyu")
    remap_file(root / "maps/EntryMap/ui/save_slot.json")
    remap_file(root / "maps/EntryMap/ui/prefab/save_slot_card.json")

    # icon_ids.json rewrite
    icons = {
        "panel_slot": {"name": "panel_slot_1", "icon_id": 134224739, "role": "角色位卡片框（透明外底）"},
        "panel_slot_selected": {"name": "panel_slot_selected_1", "icon_id": 134223904, "role": "选中位框"},
        "panel_modal": {"name": "panel_modal_1", "icon_id": 134229656, "role": "弹窗面板"},
        "btn_primary_normal": {"name": "btn_primary_normal_1", "icon_id": 134227373, "role": "进入·常态"},
        "btn_primary_hover": {"name": "btn_primary_hover_1", "icon_id": 134278658, "role": "进入·悬停"},
        "btn_primary_pressed": {"name": "btn_primary_pressed_1", "icon_id": 134268501, "role": "进入·按下"},
        "btn_secondary_normal": {"name": "btn_secondary_normal_1", "icon_id": 134265660, "role": "新建·常态"},
        "btn_secondary_hover": {"name": "btn_secondary_hover_1", "icon_id": 134279658, "role": "新建·悬停"},
        "btn_danger_normal": {"name": "btn_danger_normal_1", "icon_id": 134280729, "role": "删除·常态"},
        "btn_danger_hover": {"name": "btn_danger_hover_1", "icon_id": 134245286, "role": "删除·悬停"},
        "btn_ghost_normal": {"name": "btn_ghost_normal_1", "icon_id": 134220887, "role": "返回·常态"},
        "icon_empty_slot": {"name": "icon_empty_slot_1", "icon_id": 134239404, "role": "空位+"},
        "portrait_placeholder": {"name": "portrait_placeholder_1", "icon_id": 134232798, "role": "有档头像占位"},
        "portrait_ring": {"name": "portrait_ring_1", "icon_id": 134269431, "role": "选中头像环"},
        "deco_title_line_left": {"name": "deco_title_line_left_2", "icon_id": 134268749, "role": "标题左装饰（透明）"},
        "deco_title_line_right": {"name": "deco_title_line_right_2", "icon_id": 134282527, "role": "标题右装饰（透明）"},
        "loading_bg": {"name": "loading_bg", "icon_id": 134230791, "role": "全屏底（有背景，故意）"},
    }
    out = {
        "generated_at": "2026-08-07",
        "note": "优先使用 *_1 / *_2 透明版 icon_id；旧无实心底的 ID 已弃用",
        "source_dir": "assets/ui/save_slot/generated",
        "icons": icons,
    }
    p = root / "assets/ui/save_slot/icon_ids.json"
    p.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("wrote", p)


if __name__ == "__main__":
    main()
