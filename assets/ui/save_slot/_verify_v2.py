# -*- coding: utf-8 -*-
import json
from pathlib import Path

res = json.loads(
    Path(r"D:/y3/games/2.0/game/LocalData/yeyu/editor_table/resicon.json").read_text(
        encoding="utf-8"
    )
)
id2 = {v["default_editor_id"]: v["name"] for v in res.values()}

want = {
    "frame": 134282360,  # v2_panel_slot
    "empty_icon": 134259271,  # v2_icon_empty
    "portrait": 134253687,  # portrait_placeholder_2
}

prefab_path = Path(
    r"D:/y3/games/2.0/game/LocalData/yeyu/maps/EntryMap/ui/prefab/save_slot_card.json"
)
prefab = json.loads(prefab_path.read_text(encoding="utf-8"))
print("=== PREFAB", prefab_path, "===")
print("mtime check via size", prefab_path.stat().st_size)
for c in prefab["data"]["children"]:
    name = c.get("name")
    img = c.get("image")
    if name in want or img is not None:
        mark = ""
        if name in want:
            mark = "OK" if img == want[name] else f"WRONG want {want[name]}"
        print(f"  {name}: {img} ({id2.get(img, '?')}) {mark}")

panel_path = Path(
    r"D:/y3/games/2.0/game/LocalData/yeyu/maps/EntryMap/ui/save_slot.json"
)
panel = json.loads(panel_path.read_text(encoding="utf-8"))
print("=== PANEL INSTANCES ===")


def find_cards(n, acc=None):
    if acc is None:
        acc = []
    if str(n.get("name", "")).startswith("save_slot_card"):
        acc.append(n)
    for c in n.get("children") or []:
        find_cards(c, acc)
    return acc


for card in find_cards(panel):
    for c in card.get("children") or []:
        if c.get("name") in ("frame", "empty_icon", "selected_mark"):
            img = c.get("image")
            name = c.get("name")
            mark = ""
            if name in want:
                mark = "OK" if img == want[name] else f"WRONG want {want[name]}"
            print(
                f"  {card['name']}.{name}: {img} ({id2.get(img, '?')}) "
                f"vis={c.get('visible', True)} {mark}"
            )

# package existence
print("=== PACKAGES ===")
for pkg, expect_id in [
    ("v2_panel_slot", 134282360),
    ("v2_icon_empty", 134259271),
]:
    p = Path(r"D:/y3/games/2.0/game/LocalData/yeyu/custom/OriginalRes/icon") / (
        pkg + ".package"
    )
    print(pkg, "exists", p.is_dir(), "meta id", end=" ")
    if p.is_dir():
        meta = json.loads((p / "meta.json").read_text(encoding="utf-8"))
        print(meta.get("id"), "match" if meta.get("id") == expect_id else "DIFF")
    else:
        print("MISSING")
