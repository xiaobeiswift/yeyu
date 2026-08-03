# 内容数据源目录

本目录将成为策划可写的唯一内容源；`wzx/config/generated` 和 Y3 物编映射都是生成物，禁止手工修改。当前只冻结生产契约，尚未填入角色、武学、装备、敌人、任务或地图正式内容。

## 单写者与生成顺序

1. 对应系统 owner 维护自己的源表和 Schema 版本。
2. 生成器先校验 ID、类型、范围、排序、概率、引用、任务可达和轻功世界图能力来源。
3. 全部通过后，以稳定顺序生成只读 Lua 与必要的 Y3 物编变更；生成结果携带 generator/content/rules/foundation 版本。
4. 领域测试读取生成结果；Y3 只消费已通过的同一 manifest。

## 首批表族及 owner

| 表族 | owner | 首批关键输出 |
|---|---:|---|
| character/talent/stat_curve | 01 | CharacterBuildSnapshot 来源 DTO |
| martial/move/lightness_profile | 04/26 | 武学定义、TraversalCapabilitySpec |
| effect | 05 | 声明式效果与预算 |
| enemy/encounter | 07 | 敌人、波次、首领机制 |
| equipment/affix | 08 | 装备模板与合法原始词条 |
| item/inventory_rule | 09 | 物品与容量规则 |
| reward/drop/currency | 10 | RewardEntry 与掉落表 |
| world/traversal_grid/cell/link/water_zone | 12/26 | 空间事实、预烘焙候选索引 |
| dialogue | 13 | 对话图与选择后果引用 |
| quest | 14 | QuestDefinition 与可完成性图 |
| shop/recipe | 16 | 商店与制作配方 |
| ui/localization/tutorial | 19/24 | 文案键、页面映射、教程步骤 |

字段级 Schema 以 `docs/systems/23-数据生成与配置校验.md` 为入口。任何表头变化先更新对应系统文档和 Schema 版本，再更新生成器；不得在 Excel 中增加未登记的隐式列。
