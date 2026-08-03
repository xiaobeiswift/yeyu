# 《雾州侠行》NPC 交互与对话系统工程规格

> 状态：工程实施规格候选稿；仅描述未来实现，不代表 NPC、对白文本、配音或脚本已经制作。
>
> 上位约束：[00-通用工程约定](./00-通用工程约定.md)。

## 1. 目标与非目标

### 1.1 目标

- 定义 NPC 身份、世界生成表现、交互入口、对话图、条件分支、选择、检查点、一次性效果和会话恢复。
- 支持主线、支线、隐藏事件、好感/门派/昼夜条件、普通寒暄、功能入口和剧情选项，同时避免任意脚本注入。
- 对话文本、说话人、头像、表情、镜头、音效和动作均由稳定 ID/本地化 Key 驱动；领域层不持有 Y3 句柄。
- `ChooseDialogueOption` 只提交对话拥有的选择/记忆事实和跨系统后果意图；任务、奖励、伙伴与世界结果由应用层调用唯一 owner，并以父/子收据按 18 Saga 恢复。
- 支持快速显示、自动播放、跳过已读、日志回看和关键选择确认；表现速度不得改变规则结果。

### 1.2 非目标

- 不实现自然语言生成、玩家自由输入、实时语音识别、多人投票对话、动态 AI NPC、恋爱专用系统或分支剧情编辑器本身。
- 不拥有任务状态机、物品/货币、世界交互状态、伙伴好感或商店库存；只通过端口查询/请求。
- 不允许在对话配置中嵌 Lua、任意函数名、Y3 句柄或直接修改其他聚合的字段。
- V1 不保证在任意对白字符位置精确恢复；只在显式检查点恢复。

## 2. 依赖、所有权与跨系统接口

| 系统 | 本系统读取 | 本系统输出/调用 |
|---|---|---|
| 02 伙伴与好感 | 伙伴状态、好感条件 | 带子收据的好感/招募后果意图；不直接改聚合 |
| 09/10 背包与经济 | 物品/货币条件 | 带子收据的消耗/奖励后果意图 |
| 12 世界 | NPC 可见性、距离、世界时间/flag、输入锁 | 会话锁、世界 flag/时间白名单效果 |
| 14 任务 | 任务状态、可接/可交条件 | 带子收据的接取、分支或交付后果意图 |
| 15/16 门派、商店 | 身份/声望与功能可用性 | 打开门派/商店应用页面 |
| 18 存档 | 槽2对话事实/检查点、槽5收据 | 会话恢复和幂等提交 |
| 19 UI/表现 | 文本、选择、跳过、镜头、输入 | 视图 DTO 和表现提示 |
| 23 数据生成 | NPC/对话/条件/效果表 | 图可达性、断链、局部化校验 |

### 2.1 对外端口

| 端口 | 契约 |
|---|---|
| `NpcQuery.get_interaction(npc_id,context)` | 返回当前最高优先入口、可用原因和视图，不启动会话 |
| `DialogueQuery.get_resume_state()` | 返回是否存在可恢复检查点，禁止暴露未提交选择 |
| `DialogueCommand.start` | 绑定 NPC/世界上下文和配置版本，创建唯一会话 |
| `DialogueCommand.advance` | 确认当前非选择节点已完整展示或允许快进后推进 |
| `DialogueCommand.choose` | 只提交选择/记忆事实与规范化 `DialogueOutcomeIntent[]`，必含会话/节点修订和幂等键 |
| `DialogueCommand.cancel` | 仅可取消配置允许节点；关键会话返回禁止原因 |
| `DialogueOutcomeCoordinator.process` | 按稳定顺序把已提交后果意图交给唯一 owner；每项使用派生子收据，跨槽按 18 Saga 前向恢复 |
| `DialogueConditionPort.evaluate` | 对任务/物品/伙伴/门派/世界事实做只读查询 |
| `DialoguePresentationPort` | 镜头、表情、动画、声音；失败不改变会话事实 |

功能入口（商店、编队、经脉等）不是对白 effect；使用 `OPEN_FEATURE` 表现动作返回应用层，在关闭功能页后恢复对话会话。

## 3. 未来模块拆分

| 模块 | 职责 |
|---|---|
| `domain/dialogue/dialogue_graph` | 节点、边、选择和图不变量 |
| `domain/dialogue/dialogue_session` | 当前节点、修订、检查点和状态机 |
| `domain/dialogue/condition_evaluator` | 白名单条件逻辑、短路与诊断 |
| `domain/dialogue/effect_plan` | 后果意图规范化、来源唯一键和处理阶段；不修改外部聚合 |
| `domain/npc/npc_interaction_policy` | 多入口优先级和可见性 |
| `application/use_cases/dialogue/*` | 开始、推进、选择、取消、恢复、结束 |
| `application/ports/dialogue_*` | 世界/任务/奖励/好感/功能/表现端口 |
| `presentation/dialogue/dialogue_vm` | UI 状态、逐字、自动、历史、选择确认 |
| `adapters/y3/presentation/dialogue_director` | 相机、角色朝向、动作、音频适配 |
| `config/schema/dialogue_*` | NPC、图、节点、边、条件、效果 Schema |
| `tests/unit/dialogue/*` | 图、会话、条件、事务和恢复测试 |

## 4. 领域模型

### 4.1 `NpcDefinition`

| 字段 | 类型/范围 | 说明 |
|---|---|---|
| `npc_id` | `npc_*` | 稳定身份 ID，和世界 interactable 分离 |
| `name_key/title_key` | 本地化 Key | 称谓 |
| `portrait_id/model_id` | 稳定资源 ID | UI/Y3 映射 |
| `faction_id` | 稳定 ID 或空 | 查询条件 |
| `default_expression_id` | `expression_*` | 默认表情 |
| `interaction_entry_ids` | 有序 `npcentry_*` | 多入口规则 |
| `world_interactable_ids` | 有序 `interact_*` | 同 NPC 可有多个剧情形态 |
| `codex_profile_id` | 可空 | 图鉴信息 |
| `deprecated` | 布尔 | 旧对话兼容 |

### 4.2 `NpcInteractionEntry`

| 字段 | 说明 |
|---|---|
| `entry_id` | `npcentry_*` |
| `npc_id` | 所属 NPC |
| `priority` | 整数 -1000–1000，高者先 |
| `condition_set_id` | 可空；是否命中 |
| `entry_type` | `DIALOGUE/SHOP/QUEST_BOARD/FORMATION/TRAVEL/INSPECT` |
| `entry_ref_id` | 对应稳定 ID |
| `fallback` | 是否为无条件寒暄入口；每 NPC 每形态至多一个 |
| `once_key` | 可空；一次性入口事实 |

若多个入口同优先级且均命中，按 `entry_id` 升序；生成器应给出警告，因为通常表示策划歧义。

### 4.3 `DialogueDefinition`

字段：`dialogue_id`、`start_node_id`、`node_ids`、`graph_version`、`interrupt_policy`（ALLOW_AT_SAFE_NODE/DENY）、`save_policy`（CHECKPOINT_ONLY/NO_RESUME）、`read_tracking_policy`、`default_camera_profile_id`、`completion_key?`、`deprecated`。

### 4.4 节点类型与公共字段

所有节点都有：`node_id`、`dialogue_id`、`node_type`、`condition_set_id?`、`next_node_id?`、`checkpoint_policy`、`presentation_cue_set_id?`、`effect_set_id?`、`skippable`、`loggable`。

| 类型 | 必需专有字段 | 语义 |
|---|---|---|
| `LINE` | speaker、text_key、expression、voice/pace | 展示一段对白 |
| `NARRATION` | text_key、style | 旁白 |
| `CHOICE` | choice_set_id | 等玩家选择；无默认超时选择 |
| `BRANCH` | ordered branch 条件+目标 | 无 UI，确定性选第一命中 |
| `ACTION` | effect_set_id | 执行权威效果/表现动作 |
| `FEATURE_GATE` | feature_id、resume_node | 打开功能页并挂起 |
| `END` | end_reason、completion_effect_set? | 结束并释放锁 |

### 4.5 `DialogueChoice`

| 字段 | 类型/说明 |
|---|---|
| `choice_id` | `choice_*`，在对话内稳定 |
| `choice_set_id` / `entry_order` | 所属及显示顺序 |
| `text_key` | 本地化文本 |
| `visibility_condition_id` | 不满足则完全隐藏 |
| `enable_condition_id` | 不满足则显示禁用和原因（若配置允许） |
| `next_node_id` | 选择后节点 |
| `effect_set_id` | 选择效果；可空 |
| `confirmation_key` | 关键/不可逆选择确认文本；可空 |
| `choice_memory_key` | 需要持久记录时的稳定 key |
| `once_per_save` | 布尔 |

### 4.6 `DialogueSession`

| 字段 | 说明 |
|---|---|
| `session_id` | 本次会话唯一 ID |
| `dialogue_id/graph_version` | 绑定版本 |
| `npc_id/world_interactable_id` | 发起上下文 |
| `current_node_id` | 当前权威节点 |
| `state` | `STARTING/PRESENTING/WAITING_ADVANCE/WAITING_CHOICE/EXECUTING/HANGING_FEATURE/ENDING/ENDED/FAILED/UNKNOWN` |
| `session_revision` | 每次节点/选择提交加 1 |
| `last_checkpoint_node_id` | 已提交安全恢复点 |
| `visited_node_count` | 防无限循环，V1 单会话上限 1000 |
| `context_snapshot` | 只含剧情要求的稳定上下文 ID，不缓存余额等易变条件 |

条件在进入节点/显示选项时重算；不能用开始会话时的旧余额绕过消费条件。

## 5. 配置表与字段

### 5.1 表拆分

- `npc_definitions`、`npc_interaction_entries`。
- `dialogue_definitions`、`dialogue_nodes`、`dialogue_edges`。
- `dialogue_choices`、`dialogue_branch_cases`。
- `condition_sets`、`condition_terms`。
- `effect_sets`、`effect_entries`。
- `presentation_cue_sets`、`presentation_cues`。

### 5.2 条件 DSL

条件集合字段：`condition_set_id`、`operator`（ALL/ANY/NONE）、`failure_message_key?`。term 字段：`entry_order`、`condition_type`、`subject_id`、`comparator`、`value_type`、`value`。

允许的 `condition_type`：任务状态/目标、物品拥有数、货币余额、伙伴加入/好感阶、门派/声望、世界 flag、世界时间阶段、地点发现、对话选择记忆、功能开关。比较器只允许 `EQ/NE/GE/GT/LE/LT/CONTAINS` 的合法类型组合。禁止条件嵌套任意表达式；复杂逻辑用有序集合与多个分支节点表达。

### 5.3 效果白名单与后果所有权

| `effect_type` | 目标端口 | 约束 |
|---|---|---|
| `SET_WORLD_FLAG` | 世界 | flag 已注册、值类型合法 |
| `ADVANCE_WORLD_TIME` | 世界 | delta 0–10080、原因白名单 |
| `ACCEPT_QUEST` | 任务 | quest 可接；失败行为显式 |
| `REQUEST_QUEST_TURN_IN` | 14 任务 | 目标已完成；由任务 owner 决定交付和奖励 |
| `SET_QUEST_BRANCH` | 任务 | 仅当前活动任务的合法分支 |
| `REQUEST_REWARD_GRANT` | 10 奖励 | reward ID、PENDING 策略和永久子收据 |
| `CONSUME_RESOURCES` | 经济/背包 | 成本集合、全有全无 |
| `REQUEST_AFFINITY_CHANGE` | 02 伙伴 | 正负整数、来源上限；02 是唯一写 owner |
| `REQUEST_COMPANION_RECRUIT` | 02 伙伴 | 伙伴配置和队伍容量策略；02 是唯一写 owner |
| `UNLOCK_TRAVEL` | 世界 | route ID 合法 |
| `MARK_DIALOGUE_MEMORY` | 本系统 | key和值类型注册 |
| `REQUEST_ENCOUNTER` | 战斗应用 | 只能作为检查点后终止/挂起动作 |

纯表现 cue 不放在 effect set：`CAMERA_FOCUS`、`PLAY_GESTURE`、`SET_EXPRESSION`、`PLAY_SOUND`、`SCREEN_FADE`、`WAIT_PRESENTATION`。表现失败不得阻止权威流程，除非资源缺失在发布前被校验阻断。

`SUBMIT_QUEST`、`GRANT_REWARD`、`CHANGE_AFFINITY`、`JOIN_COMPANION` 是禁止生成的旧直写名称；加载旧配置时必须显式迁移到上表 `REQUEST_*` 类型，不能把旧名称当别名静默执行。除 `MARK_DIALOGUE_MEMORY` 外，所有跨系统 effect 都只生成后果意图，不在对话领域内修改目标状态。

`DialogueOutcomeIntent` 至少包含：`intent_id`、`source_occurrence_id`、`owner_type`、`operation_type`、`target_ref`、规范化参数哈希、`child_receipt_id`、`required`、`failure_node_id?`、`state`。固定规则：

- `source_occurrence_id = dialogue_id + node_id + choice_id/phase + consequence_key`。
- `child_receipt_id = "dialogue:" + parent_receipt_id + ":" + intent_order + ":" + owner_type`。
- 同一 `source_occurrence_id + owner_type + semantic_target` 只能有一个写路径；意图、事件订阅器和任务/伙伴内容解析器不得同时执行相同后果。
- owner 返回 COMMITTED 后只记录结果摘要；对话不得根据事件再执行第二次，也不得直接改 owner 聚合。

### 5.4 效果阶段

每个 effect entry 有 `phase`：`BEFORE_NODE/ON_ENTER/ON_CHOICE/ON_EXIT/ON_END`，以及 `failure_policy`：

- `ABORT_BEFORE_CHOICE`：默认；只允许在选择事实写入前因预校验失败而不提交。
- `BRANCH_TO_NODE`：预期业务失败跳到配置错误处理节点，目标节点必填。
- `DEFER_REWARD_ONLY`：只允许奖励容量不足转待领，仍视为业务成功。

选择事实与后果意图一旦提交便不可因后续 owner 故障回滚。后果处理失败或未知时会话停在 `OUTCOME_PENDING/OUTCOME_UNKNOWN`，按同一子收据恢复；明确业务拒绝才按 `BRANCH_TO_NODE` 进入已配置分支。不得配置“忽略扣费失败继续剧情”。跨 Encounter 的效果必须在启动前提交检查点，战斗结果由新会话/任务事件接续。

## 6. 运行时状态与不变量

### 6.1 不变量

1. 同一玩家同时最多一个权威 DialogueSession；功能页挂起仍占会话锁。
2. `current_node_id` 必须属于绑定 dialogue/version；未知节点进入恢复而不是跳 END。
3. `WAITING_CHOICE` 只能接受当前 choice set 中可见且可用的 choice ID。
4. 同一 `session_id+node_id+effect_phase+effect_entry` 最多生成一个意图；目标 owner 按 `child_receipt_id` 去重。
5. 已提交 choice memory 不因重看/跳过改变；同会话重试返回原选择结果。
6. UI 展示完毕、逐字速度、音频时长和动画结束不属于权威剧情事实。
7. 进入检查点前，前一个节点的 required 后果意图必须全部明确 COMMITTED/PENDING_REWARD；保存只指向已提交检查点。
8. 单会话节点访问超过 1000 次返回 `DIALOGUE_LOOP_GUARD` 并进入安全结束/诊断。
9. `DialogueChoiceCommitted` 只证明选择事实，不是奖励、好感、招募或任务交付命令；这些结果必须有对应 owner 子收据。

### 6.2 条件一致性

- BRANCH 条件在执行该节点时按 `entry_order` 重算，选第一命中；必须配置唯一 fallback。
- CHOICE 的可见/可用性在展示时计算，提交时再次计算。二者变化导致 `DIALOGUE_CHOICE_STALE`，刷新选择而非自动代选。
- 文本可基于已确定的安全展示变量（角色显示名、物品显示名）插值；插值不改变节点 ID、条件或效果。

## 7. 会话、推进与恢复规则

### 7.1 开始会话

1. 世界系统确认 NPC 可见、交互距离与输入锁。
2. `NpcInteractionPolicy` 过滤入口并按优先级/ID选择。
3. 非对话功能入口直接委派；对话入口绑定配置版本并创建 session ID。
4. 获取世界/镜头输入锁，记录起始安全 marker；进入 start node。
5. start 节点条件不满足时不得扫描任意后继猜测；配置可用显式 BRANCH。

### 7.2 节点推进

- LINE/NARRATION：表现层发送“显示完成/用户推进”，应用层验证当前 revision 后执行 ON_EXIT 并进入 next。
- BRANCH：不等待 UI，按条件选边；连续自动节点每次都增加 visited count，最多每个应用 tick 处理 50 个，余下排队避免卡帧。
- ACTION：执行 effect set；成功后推进，失败按 policy。
- CHOICE：等待用户；没有超时默认选项。只有无任何可见选择才是配置/运行错误。
- END：提交 completion effect/memory，清除恢复点（或记录完成），释放输入与镜头锁。

### 7.3 跳过/自动/已读

- 快速显示只结束当前逐字/语音等待，不直接越过选择或未提交 ACTION。
- 自动播放仅自动推进 LINE/NARRATION，遇 CHOICE、FEATURE_GATE、不可跳过节点和错误停止。
- “跳过已读”按 `dialogue_id+node_id+text_revision` 判断，只压缩表现；每个节点仍通过应用层提交事实/意图，owner 子收据防重。
- 首次关键剧情默认不可整段跳过；教学可在设置允许后跳过，并记录引导系统状态。

### 7.4 检查点和重进

- `checkpoint_policy=SAVE_BEFORE/SAVE_AFTER` 的节点形成恢复点；恢复记录写入槽2且必须对应已提交效果修订。
- 正常退出/崩溃后从 `last_checkpoint_node_id` 重建，不恢复逐字进度、音频时间或镜头插值。
- 若检查点后已经提交某 choice/effect，恢复时通过收据跳过重复提交并进入其原结果 next node。
- `NO_RESUME` 对话退出后安全终止；任何 required 奖励/任务后果意图必须在退出前已由 owner 确认或尚未创建。

### 7.5 取消和中断

- 只在安全节点且 dialogue policy 允许时取消。取消不回滚已提交选择/奖励/任务。
- 战斗/传送等高优先事件不能从外部强行销毁 session；应用层先提交/清除检查点，再明确挂起或结束。
- NPC 模型被卸载不终止对话；使用保存的 speaker 视图继续，表现镜头回退为 UI 肖像模式。

## 8. 应用用例契约

| 用例 | 输入 | 前置 | 事务/幂等 | 输出 | 主要错误 |
|---|---|---|---|---|---|
| `GetNpcInteraction` | npc、interactable、world context | 在范围/可见 | 只读 | 入口、提示、禁用原因 | `NPC_NOT_AVAILABLE` |
| `StartDialogue` | npc、entry、world sequence、`command_id` | 无活动会话、入口仍命中 | session 创建幂等，槽2可选检查点 | 首节点 VM、session/revision | `DIALOGUE_BUSY`、`DIALOGUE_ENTRY_STALE` |
| `AdvanceDialogue` | session、node、revision、`command_id` | 当前节点允许推进 | 本系统事实与后果意图按父收据提交；外部 owner 另由协调器处理 | 下一节点/OUTCOME_PENDING/END、revision | `DIALOGUE_STATE_MISMATCH`、`EFFECT_FAILED` |
| `ChooseDialogueOption` | session、node、choice、revision、确认 token、`command_id` | 选择仍可见可用、后果预校验通过 | 槽2一次提交 choice/memory/intent rows；不写外部 owner，幂等 | 已提交选择、intent IDs、OUTCOME_PENDING/下一节点 | `DIALOGUE_CHOICE_STALE`、`CONFIRMATION_REQUIRED` |
| `ProcessDialogueOutcomes` | session、parent receipt、intent IDs | choice 已提交 | 按 intent_order 调唯一 owner，记录子收据并按18 Saga恢复；全部 required 明确后推进 | owner 结果摘要、下一节点/失败分支 | `DIALOGUE_OUTCOME_REJECTED`、`DIALOGUE_OUTCOME_UNKNOWN` |
| `OpenDialogueFeature` | session、feature ID、`command_id` | 当前 FEATURE_GATE | 会话转 HANGING，功能不直接改会话 | feature request、resume token | `FEATURE_UNAVAILABLE` |
| `ResumeFromFeature` | session、resume token、result summary | 会话仍 HANGING | 恢复幂等 | resume node | `DIALOGUE_RESUME_STALE` |
| `CancelDialogue` | session、revision、`command_id` | 安全节点/策略允许 | 保存已提交事实、释放锁 | cancelled end | `DIALOGUE_INTERRUPT_DENIED` |
| `ResumeSavedDialogue` | checkpoint DTO、`command_id` | 配置版本兼容、NPC上下文可恢复 | 查询选择父收据与 owner 子收据后重建 | 当前节点或安全终止 | `DIALOGUE_VERSION_UNSUPPORTED` |
| `GetDialogueHistory` | session/最近会话 | 仅 loggable 节点 | 只读、本地视图 | 已展示文本和已选项 | `DIALOGUE_HISTORY_UNAVAILABLE` |
| `ResolveDialogueUnknown` | receipt/session ID | UNKNOWN | 查询槽2/3/4/5的父/子收据 | 明确节点/选择/后果结果 | `SAVE_UNAVAILABLE` |

选择确认 token 绑定会话、节点、choice、修订、显示文本 revision 和效果摘要；用于降低文本更新后玩家误确认风险，但权威服务仍从配置重算。

## 9. 领域事件

| 事件 | payload | 消费者 |
|---|---|---|
| `DialogueStarted` | `session_id,dialogue_id,npc_id,entry_id,graph_version` | 世界输入、UI、诊断 |
| `DialogueNodeEntered` | `session_id,node_id,node_type,sequence` | 表现、已读记录；任务通常不监听 |
| `DialogueChoiceCommitted` | `session_id,dialogue_id,node_id,choice_id,memory_key?,receipt_id` | 任务目标、世界条件、UI；只读选择事实，不触发伙伴/奖励/任务交付写入 |
| `DialogueOutcomeIntentQueued` | `intent_id,source_occurrence_id,owner_type,operation_type,child_receipt_id` | 应用 outcome coordinator、恢复日志 |
| `DialogueOutcomeResolved` | `intent_id,owner_type,state,result_hash` | 对话会话推进、UI、诊断 |
| `DialogueCheckpointSaved` | `session_id,node_id,session_revision` | 存档恢复 |
| `DialogueFeatureOpened` | `session_id,feature_id,resume_node_id` | 功能路由/UI |
| `DialogueCompleted` | `session_id,dialogue_id,npc_id,end_reason,completion_key?,receipt_id` | 任务、世界、UI |
| `DialogueCancelled` | `session_id,dialogue_id,node_id,reason` | 世界输入/UI |
| `DialogueTransactionUncertain` | `session_id,node_id,receipt_id` | 恢复 UI/日志 |

任务的 `CHOOSE_DIALOGUE` 目标可监听 `DialogueChoiceCommitted`；任务接取、分支、交付和奖励只能读取 14 owner 用例提交后的任务事件。不得把同一 choice 同时配置为 `REQUEST_QUEST_TURN_IN` 和另一个自动任务后果消费者，也不得以“玩家看到了某行文字”推进关键任务。

## 10. 存档 DTO、槽位与迁移

### 10.1 槽 2 对话事实

| 字段 | 形态 | 说明 |
|---|---|---|
| `dialogue_memories` | `memory_key -> 标量值` | 类型由配置注册 |
| `completed_dialogues` | `completion_key -> count/last_version` | 只为条件，不替代任务状态 |
| `active_dialogue_checkpoint` | 单一扁平记录或空 | session、dialogue/version、node、revision、npc、interactable |
| `dialogue_outcome_intents` | 有序扁平行 | intent、source occurrence、owner、child receipt、state；不复制 owner 结果字段 |
| `read_dialogue_nodes` | 可选压缩集合 | `dialogue/node/text_revision`；不影响进度 |

槽5保存选择父收据、跨槽恢复索引和未知事务。奖励/物品实际状态仍在槽4，伙伴状态在槽3，任务实际状态仍在槽2任务子表；对话 DTO 只保存 intent 与结果摘要，不复制其余额或状态。

### 10.2 本地非权威设置

逐字速度、自动播放、音量、历史滚动位置、是否跳过已读由 24 设置系统保存；不得作为剧情条件。对话历史可以只保留当前/最近会话于内存，除非产品另行要求云同步。

### 10.3 迁移

- 节点 ID 发布后不复用。文本更新只增加 `text_revision`；不因改字重置权威选择。
- 图结构变化时提供 `old_graph_version + checkpoint_node -> new_node/safe_end` 映射；无映射则安全终止对话并保留已提交事实，进入对应任务恢复路径。
- choice/memory key 变更必须显式迁移；不得清空玩家已做关键选择。
- 下线 NPC 可用肖像恢复对话或映射替代 interactable；不能因模型不存在删除选择父收据或 owner 子收据引用。
- 迁移幂等并在副本上验证可达 END 后再写入。

## 11. Y3 适配与 UI

### 11.1 Y3 表现适配

- NPC interactable 由 12 世界注册，`npc_id` 映射到当前单位句柄；同一身份可切剧情模型。
- 对话开始时可让玩家/NPC 朝向、停止移动、切镜头；失败回退肖像 UI，不影响权威节点。
- 表情、动作、语音、音效、镜头 cue 均按 `cue_id` 顺序执行，可标记 blocking presentation；阻塞只影响何时允许 UI 发送 advance，不决定效果提交。
- 资源映射缺失在开发构建显示占位并记录；发布生成必须阻断关键角色头像/文本/选择缺失。
- 关闭/重载 UI 后从当前 SessionViewModel 重建，不重新执行 ON_ENTER 权威效果。

### 11.2 对话 UI

支持 `LOADING/PRESENTING/WAIT_ADVANCE/WAIT_CHOICE/EXECUTING/HANGING/READ_ONLY/ERROR/COMMIT_UNKNOWN/ENDING`。

- 显示说话人、正文、头像/立绘、继续提示；安全区适配 1920×1080。
- 逐字中第一次推进显示全文，第二次才请求推进；不可跳过节点给明确提示。
- 选项按配置顺序，隐藏与禁用语义不同；禁用项显示原因，关键项确认后提交。
- 提交时冻结所有选择，避免双击；`DIALOGUE_CHOICE_STALE` 就地刷新并提示条件变化。
- 历史仅显示玩家已实际展示的 loggable 文本和已提交选择，不提前展开隐藏分支。
- 跳过已读/自动播放状态明显可见，遇选择自动停止。
- 只读恢复时允许看当前文本/历史和退出到恢复页，不允许执行新效果。

## 12. 边界、失败与恢复

| 场景 | 必须行为 |
|---|---|
| 对话图无可见选择 | 返回配置错误并提供安全取消，不自动选隐藏项 |
| BRANCH 多个条件命中 | 选第一配置项，同时生成歧义诊断；无 fallback 为构建错误 |
| 选择展示后资源被其他系统消耗 | 提交时返回 stale/不足，刷新，不推进 |
| 后果预校验失败 | 选择事实尚未提交时按 `ABORT_BEFORE_CHOICE` 拒绝；刷新选项/条件 |
| 选择已提交后某 owner 失败/未知 | 不回滚选择或已确认 owner 结果；停在后果恢复态，按同一子收据前向恢复或走显式失败分支 |
| 效果提交未知 | 停在核对状态，按收据恢复，不重放随机/奖励 |
| 表现 cue/语音失败 | 跳过或占位，权威节点不回滚 |
| NPC 在会话中卸载 | 回退肖像模式，按已绑定身份继续 |
| 存档时处于逐字中 | 保存最近已提交检查点，不存字符索引 |
| 配置热更 | 活动会话绑定旧版本至结束；无旧配置则走迁移/安全终止 |
| 循环超过 1000 节点 | 阻断、保存诊断、释放输入锁，禁止继续发效果 |

## 13. 数据生成与校验

必须校验：

- NPC、入口、对话、节点、choice、speaker、文本、资源和 action 引用完整；稳定 ID/前缀不重复。
- 从 start 可达至少一个 END；除显式循环外无不可退出强连通分量，显式循环必须有可满足退出边。
- 每个 BRANCH 恰有最后 fallback；每个 CHOICE 在条件模型中至少可能出现一个选项。
- next/branch/choice 目标属于同图；FEATURE_GATE 有 resume；检查点不能落在未提交效果中间。
- effect 类型、阶段、failure policy、目标 owner 和子收据策略合法；跨 owner 后果必须可按 18 Saga 恢复，禁止直写旧 effect 名称。
- 对全内容构建 `DialogueConsequenceRegistry`；同一 `source_occurrence_id + owner_type + semantic_target` 若同时出现在 intent、伙伴解析、任务动作或奖励配置中则生成失败，禁止同源双配置/双发奖。
- 条件类型/比较器/值匹配；引用任务、flag、物品、门派、伙伴均存在。
- 所有文本/选择/错误提示本地化 Key 存在；占位符集合与允许变量一致；关键文本有 `text_revision`。
- 单图节点数、最长无交互自动链、最大可能循环访问、单批效果数在硬上限内。

生成报告输出入口冲突、图可达/循环、所有关键选择及后果、节点效果阶段、缺失本地化/资源、未引用节点、会话最长路径和图版本差异。

## 14. 测试矩阵

| 层级 | 覆盖 | 断言 |
|---|---|---|
| 单元 | 入口优先级、条件 ALL/ANY/NONE、比较器 | 决策稳定 |
| 单元 | LINE/BRANCH/CHOICE/ACTION/FEATURE/END | 状态转移正确 |
| 单元 | 选择 stale、确认 token、节点循环守卫 | 无自动误选/无限循环 |
| 属性测试 | 随机合法对话图遍历 | 当前节点始终图内、终态可达或被守卫 |
| 契约 | 任务/奖励/世界/好感 owner 成功、拒绝、未知 | 子收据只应用一次，恢复与错误分支准确 |
| 故障注入 | 选择/效果/检查点各写入点崩溃 | 恢复不重复效果 |
| 存档 | 检查点往返、图迁移、NPC下线 | 安全恢复/终止且保留事实 |
| Y3 集成 | 镜头、朝向、模型卸载、语音缺失、UI重载 | 表现失败不改权威 |
| UI | 逐字双击、自动、跳过已读、禁用选择、只读 | 交互符合规则 |
| 内容 | 首章主线+6支线完整图走查和分支覆盖 | 所有分支可达且无断链 |

## 15. 验收标准

- 所有首章 NPC 在合法世界上下文选择正确交互入口，普通寒暄不会覆盖更高优先任务入口。
- 对话图在无引擎测试中从起点可到终点，选择、分支、检查点和效果结果可重复。
- 奖励、扣费、任务、世界 flag、好感等效果在重复点击/断线/写入未知时最多提交一次。
- 保存于任意允许节点后重进可从检查点恢复；不重复对白权威效果，不丢关键选择。
- 表现速度、跳过、语音或镜头失败不改变剧情结果；关键选择不会被自动模式越过。
- 图/条件/效果/本地化/资源生成校验阻断所有断链、无选项和不可退出错误。
- UI 全状态、键鼠路径、历史、确认、只读/核对流程可用。
- 单元、契约、迁移、故障注入、Y3 冒烟和首章内容走查通过，P0/P1 为零。

## 16. 实施任务拆分

1. 冻结 NPC/图/节点/条件/效果/检查点模型、错误码和跨系统端口。
2. 建立全部 Schema、图编译器、本地化/资源检查和可达性报告。
3. 实现纯领域入口策略、条件求值、DialogueSession 状态机和循环守卫。
4. 实现 effect plan 规范化、Fake 多系统事务和节点收据故障测试。
5. 实现查询、开始、推进、选择、功能挂起、取消、恢复、未知核对用例。
6. 完成槽2记忆/检查点/已读 DTO、槽5收据和图版本迁移。
7. 接入世界 NPC、任务、奖励、伙伴、门派、商店等端口和事件。
8. 实现 Y3 对话导演、相机/动作/声音回退与 UI ViewModel。
9. 完成逐字、自动、跳过已读、历史、选择确认、全状态和键鼠适配。
10. 导入首章全部对话，运行分支覆盖、故障恢复和无开发命令端到端验收。

## 17. 待决项

- 对话是否全量配音（默认仅关键句可配，voice ID 可空，文本永远完整可用）。
- 已读记录是否云同步以及容量策略（默认云同步关键节点，普通已读可本地保存；不影响进度）。
- 活动会话退出游戏是否强制恢复还是安全终止（默认有检查点则恢复，无恢复策略则安全终止）。
- 是否提供整段剧情跳过（默认首章首次不可整段跳，已完成对话可跳过已读表现但仍执行幂等节点流程）。
- 好感选择是否在选择前显示数值后果（默认只在确认后显示实际变化，关键不可逆阵营选择需文字说明）。
- 主角自定义姓名/代词占位符集合（角色系统冻结后列入本地化 Schema，禁止任意格式字符串）。
