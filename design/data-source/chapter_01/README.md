# 第一卷内容包（方向 3）

叙事权威：`docs/story/`  
可加载中间稿（非 generated）：

| 包 | 路径 |
|---|---|
| 任务 | `wzx/config/content/quest/chapter_01.lua` |
| 对话 | `wzx/config/content/dialogue/chapter_01.lua` |
| 世界 | `wzx/config/content/world/chapter_01.lua` |
| 遭遇 | `wzx/config/content/encounter/chapter_01.lua` |
| 奖励 | `wzx/config/content/reward/chapter_01.lua` |
| 聚合 | `wzx/config/content/chapter_01_bundle.lua` |

## 校验

```powershell
.\tools\test.ps1 -Match "chapter_01_content"
```

覆盖：各包 seal/build + 任务 TALK/REACH/SEARCH/ENCOUNTER/reward 跨包引用。

## 尚未挂接

| 项 | 说明 |
|---|---|
| `traversal_cell_ridge_gap_landing` | 轻功格属 12/26 烘焙，本包不建假坐标 |
| `item_black_resin` / `item_axle_rivet` | 物品表未开工；支线 OWN/DELIVER 先挂 ID |
| 对白正文 | 仅 text_key；中文脚本另表 |
| 遭遇数值 | 占位 profile，非最终平衡 |
