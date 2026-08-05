# 任务数据源（Quest）

> Owner：系统 14  
> 叙事权威：`docs/story/`（方向 3 · v0.2）  
> 运行时 Schema：`wzx/config/schema/quest/*`  
> 可加载中间稿：`maps/EntryMap/script/wzx/config/content/quest/chapter_01.lua`（管线落地前手写对齐源，**不是** `config/generated`）

## 当前冻结范围

| 包 | 内容 | 状态 |
|---|---|---|
| `chapter_01` | 主线 9 + 支线 6 | 已冻结 ID / 阶段 / 目标类型 / 中文案 key |

## 生产约定

1. **先改叙事与本目录说明**，再改 `wzx/config/content/quest/chapter_01.lua`。
2. Excel 生成器就绪后：本目录 CSV/源表 → 生成器 → `wzx/config/generated`；禁止手改 generated。
3. 奖励 `reward_*` 目前为占位 ID，数值表未冻结；`reward_policy=NO_REWARD` 的支线可不挂奖励。
4. 目标 `target_id` 引用对话 / 遭遇 / 地点 / 交互物 / 轻功格，属跨表引用；首章内容包只保证**任务图自洽**（QuestCatalog seal），跨表引用在后续 world/dialogue/encounter 源表补齐。

## 文件

| 文件 | 说明 |
|---|---|
| `chapter_01_freeze.md` | 人读冻结表（中文 + ID） |
| `../README.md` | data-source 总说明 |

## 校验

```powershell
# 仓库根目录
.\tools\test.ps1 -Match quest_chapter_01
```
