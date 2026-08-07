import json
from pathlib import Path
res=json.loads(Path(r"D:/y3/games/2.0/game/LocalData/yeyu/editor_table/resicon.json").read_text(encoding="utf-8"))
id2={v["default_editor_id"]:v["name"] for v in res.values()}
pf=json.loads(Path(r"D:/y3/games/2.0/game/LocalData/yeyu/maps/EntryMap/ui/prefab/save_slot_card.json").read_text(encoding="utf-8"))
print("prefab", pf.get("name"), pf.get("key"))
for c in pf["data"].get("children") or []:
    img=c.get("image")
    print(c.get("name"), "img=", img, id2.get(img, "?"), "vis=", c.get("visible", True))
    if c.get("name")=="tishi":
        for t in c.get("children") or []:
            print(" ", t.get("name"), t.get("text"), t.get("font_color"))
