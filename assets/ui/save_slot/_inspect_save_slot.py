# -*- coding: utf-8 -*-
import json

p = r"D:\y3\games\2.0\game\LocalData\yeyu\maps\EntryMap\ui\save_slot.json"
with open(p, "r", encoding="utf-8") as f:
    d = json.load(f)


def walk(n, depth=0):
    ind = "  " * depth
    name = n.get("name")
    ct = n.get("comp_type") or n.get("type")
    size = n.get("size")
    if isinstance(size, dict):
        size = size.get("items")
    pos = n.get("pos_data")
    if isinstance(pos, dict):
        pos = pos.get("items")
    img = n.get("image")
    text = n.get("text")
    if isinstance(text, dict):
        text = text.get("items")
    font = n.get("font")
    if isinstance(font, dict):
        font = font.get("items")
    visible = n.get("visible", True)
    opacity = n.get("opacity")
    keys_extra = []
    for k in ("prefab_key", "prefab_id", "prefab_instance_key", "instance_key"):
        if n.get(k):
            keys_extra.append(f"{k}={n.get(k)}")
    # detect prefab instance by type
    print(
        f"{ind}{name} type={ct} img={img} size={size} pos={pos} "
        f"text={text} font={font} vis={visible} op={opacity} {' '.join(keys_extra)}"
    )
    for c in n.get("children") or []:
        walk(c, depth + 1)


print("top keys", list(d.keys()))
print("root name", d.get("name"), "type", d.get("type"), "uid", d.get("uid"))
walk(d)
print("--- all node names ---")


def names(n, acc):
    acc.append(n.get("name"))
    for c in n.get("children") or []:
        names(c, acc)


acc = []
names(d, acc)
print(acc)
