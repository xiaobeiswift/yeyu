# 第一卷任务冻结表（方向 3）

> chapter_id：`chapter_01_bell_below_no_name`  
> 与 `docs/story/chapters/chapter-01-钟下无名/主线任务链.md` 对齐。

## 主线链

| 序 | quest_id | 中文名 | 接取 | 前置 | 阶段数 | 终局奖励占位 |
|---:|---|---|---|---|---:|---|
| 1 | quest_main_01_night_ferry | 夜投雾津 | AUTO_EVENT | — | 2 | reward_main_01 |
| 2 | quest_main_02_road_silencing | 驿道灭口 | AUTO_EVENT | 01 | 4 | reward_main_02 |
| 3 | quest_main_03_mist_and_wood | 雾病与黑木 | AUTO_EVENT | 02 | 2 | reward_main_03 |
| 4 | quest_main_04_no_bandits | 岭上没有匪 | AUTO_EVENT | 03 | 2 | reward_main_04 |
| 5 | quest_main_05_proof_taker | 夺证之人 | AUTO_EVENT | 04 | 3 | reward_main_05 |
| 6 | quest_main_06_midnight_bell | 子夜旧钟 | AUTO_EVENT | 05 | 2 | reward_main_06 |
| 7 | quest_main_07_proof_under_bell | 钟下遗证 | AUTO_EVENT | 06 | 3 | reward_main_07 |
| 8 | quest_main_08_last_warden | 守院人 | AUTO_EVENT | 07 | 3 | reward_main_08 |
| 9 | quest_main_09_who_holds_proof | 证物交谁 | MANUAL_NPC 驿丞 | 08 | 1 | reward_main_09 |

主线 `abandon_policy=DENY`，`failure_policy=NO_FAIL`，`reward_policy=AUTO_ON_COMPLETE`（卷末 09 可用 TURN_IN 语义由对话分支表达，奖励仍 AUTO 简化）。

## 支线

| quest_id | 中文名 | 前置主线 | 接取 NPC/入口 |
|---|---|---|---|
| quest_side_01_find_bell | 雾里寻铃 | 01 完成可接 | npc_post_boy |
| quest_side_02_black_resin | 乌檀取脂 | 03 | npc_partner_su_jianwei |
| quest_side_03_axle_rivet | 断轴重铆 | 02 | npc_relay_carter |
| quest_side_04_three_steps | 三步护行 | 03 | npc_partner_liang_jibai |
| quest_side_05_stele_behind_door | 石门后的碑 | 04；HIDDEN_UNTIL_REVEALED | 隐藏交互 |
| quest_side_06_night_talk | 夜谈刀剑 | 05 | 夜宿 AUTO / 伙伴 |

## 关键 target 占位（跨表后续补）

| 类型前缀 | 示例 ID |
|---|---|
| dialogue_ | dialogue_main_01_post_hire, dialogue_main_02_ambush_arrive, dialogue_main_02_ambush_site, dialogue_main_05_ke_confront, dialogue_main_05_aftermath, dialogue_main_07_proof_under_bell, dialogue_main_08_meng_confront, dialogue_main_08_meng_aftermath, dialogue_main_09_proof_choice |
| encounter_ | encounter_main_02_road_ambush, encounter_main_05_ke_lishan, encounter_main_08_meng_jiansheng |
| location_ | location_mist_ferry_hall, location_road_ambush, location_blackwood_gate, location_sunken_bell_court, location_bell_cavern |
| interact_ | interact_ambush_search, interact_ridge_kiln, interact_ridge_stele, interact_cavern_nameplate, interact_side_bell, interact_side_hidden_stele |
| traversal_cell_ | traversal_cell_ridge_gap_landing |
| item_ | item_black_resin, item_axle_rivet, item_side_bell |

## 中文案 key 约定

- 任务标题：`quest.<id>.title` / `quest.<id>.summary`
- 阶段：`stage.<id>.journal`
- 目标：`objective.<id>.desc` / `objective.<id>.done`

正文见内容模块旁 `chapter_01_zh.md` 或 story 文档；运行时本地化表后续挂 19。
