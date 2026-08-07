# -*- coding: utf-8 -*-
"""Force-bind save_slot UI to latest transparent TGA icon IDs; set image color white."""
import json
from pathlib import Path

# latest TGA-alpha reimport (*_2 / *_3)
IDS = {
    "panel_slot": 134262246,
    "panel_slot_selected": 134248490,
    "btn_primary_normal": 134236853,
    "btn_primary_hover": 134254184,
    "btn_primary_pressed": 134231881,
    "btn_secondary_normal": 134251056,
    "btn_secondary_hover": 134239083,
    "btn_danger_normal": 134262316,
    "btn_danger_hover": 134270167,
    "btn_ghost_normal": 134264308,
    "icon_empty_slot": 134273868,
    "portrait_placeholder": 134253687,
    "portrait_ring": 134270566,
    "deco_left": 134254990,
    "deco_right": 134227534,
    "loading_bg": 134230791,
}

# any historical id -> new
OLD_TO_NEW = {
    # panels
    134266962: IDS["panel_slot"],
    134224739: IDS["panel_slot"],
    134226841: IDS["panel_slot_selected"],
    134223904: IDS["panel_slot_selected"],
    # primary
    134248131: IDS["btn_primary_normal"],
    134227373: IDS["btn_primary_normal"],
    134218584: IDS["btn_primary_hover"],
    134278658: IDS["btn_primary_hover"],
    134231186: IDS["btn_primary_pressed"],
    134268501: IDS["btn_primary_pressed"],
    # secondary
    134242431: IDS["btn_secondary_normal"],
    134265660: IDS["btn_secondary_normal"],
    134246465: IDS["btn_secondary_hover"],
    134279658: IDS["btn_secondary_hover"],
    # danger
    134244576: IDS["btn_danger_normal"],
    134280729: IDS["btn_danger_normal"],
    134272161: IDS["btn_danger_hover"],
    134245286: IDS["btn_danger_hover"],
    # ghost
    134269797: IDS["btn_ghost_normal"],
    134220887: IDS["btn_ghost_normal"],
    # empty / portrait
    134244552: IDS["icon_empty_slot"],
    134239404: IDS["icon_empty_slot"],
    134262480: IDS["portrait_placeholder"],
    134232798: IDS["portrait_placeholder"],
    134259647: IDS["portrait_ring"],
    134269431: IDS["portrait_ring"],
    # deco
    134241741: IDS["deco_left"],
    134253971: IDS["deco_left"],
    134268749: IDS["deco_left"],
    134263686: IDS["deco_right"],
    134275516: IDS["deco_right"],
    134282527: IDS["deco_right"],
}

IMG_KEYS = (
    "image",
    "normal_picture",
    "suspend_picture",
    "press_picture",
    "disabled_picture",
)


def tup(items):
    return {"__tuple__": True, "items": list(items)}


def fix_node(n, stats):
    for k in IMG_KEYS:
        v = n.get(k)
        if isinstance(v, int) and v in OLD_TO_NEW:
            n[k] = OLD_TO_NEW[v]
            stats[v] = stats.get(v, 0) + 1
    # white tint so engine doesn't multiply gray/black color over texture
    if n.get("type") == 4 or n.get("comp_type") == "Image":
        n["color"] = [255, 255, 255, 255]
    if n.get("type") == 1:  # button
        # ensure pictures point to latest if already set via keys above
        pass
    for c in n.get("children") or []:
        fix_node(c, stats)


def load(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save(path, doc):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=4)
        f.write("\n")


def main():
    root = Path(r"D:\y3\games\2.0\game\LocalData\yeyu")
    for rel in [
        "maps/EntryMap/ui/save_slot.json",
        "maps/EntryMap/ui/prefab/save_slot_card.json",
    ]:
        path = root / rel
        doc = load(path)
        stats = {}
        if "data" in doc:
            fix_node(doc["data"], stats)
        else:
            fix_node(doc, stats)
        save(path, doc)
        print(rel, "remaps", sum(stats.values()), stats)

    # icon_ids
    icons = {k: {"name": k, "icon_id": v, "role": "transparent_tga"} for k, v in IDS.items()}
    out = {
        "note": "Use these IDs only. Generated with real alpha (TGA import). Do not re-save editor before hotfix reload.",
        "icons": icons,
    }
    (root / "assets/ui/save_slot/icon_ids.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print("ok")


if __name__ == "__main__":
    main()
