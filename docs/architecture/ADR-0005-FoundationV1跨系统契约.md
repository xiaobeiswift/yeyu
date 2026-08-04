# ADR-0005：Foundation V1 跨系统契约

> 状态：已采纳
>
> 生效版本：`foundation_contract_version = 1`

## 背景

工程进入并行实现前，必须消除事件信封、运行时 ID、确定性收据、内容清单和槽 1 section 结构中的解释空间。本 ADR 补足 ADR-0001～0004 的字节级与运行时约束；冲突时以本文为准。

## 1. 运行时 ID

- 外部创建的 `command_id`、`transaction_id`、`combat_id`、`correlation_id` 和 `source_occurrence_id` 都是一个原子组件。
- 原子组件长度为 `1..64` 个 ASCII 字节，字符集为 `[A-Za-z0-9_.-]`，首字符必须是字母或数字，禁止 `:`。
- 组合 ID 只能由权威 owner 使用 `:` 连接已经校验的原子组件或无前导零的正整数，最长 192 字节。调用方不得传入已经拼接好的 owner 派生 ID。
- `event_id`、子收据和战斗事件 ID 可以是组合 ID；`command_id` 不得是组合 ID。
- 稳定内容 ID 继续使用小写 `[a-z][a-z0-9_]*`，最长 96 字节，并遵循 00 的类型前缀。
- canonical `StatContribution.source_id` 是来源引用键，可由 `:` 连接稳定内容/实例组件：每段最长 96 字节、总长最长 320 字节。`stable_order_key` 使用同一 ASCII 组件规则，但总长最长 512 字节。两者都不是外部命令 ID，不能传给要求原子 ID 的端口。

## 2. DomainEventEnvelopeV1

唯一通用信封字段为：

```text
event_id, event_type, schema_version, aggregate_id, revision, payload,
occurred_at?, causation_id?, correlation_id?, source_system?, source_occurrence_id?
```

- 前六项必填；`revision` 为非负整数。
- 后五项是可选信封字段，不得在某个系统中另造第二套信封。
- 某事件 Schema 可以把可选字段提升为该事件必填约束。
- 应用层已经发生的事实仍使用 `envelope_kind=DOMAIN_EVENT`；纯 UI/表现信号进入 `PresentationSignalRegistry`，不增加 `APPLICATION_EVENT`。
- `CombatEvent` 是专化：`event_id=combat_id:sequence`、`aggregate_id=combat_id`、`revision=sequence`、`occurred_at=nil`，且 `sequence` 从 1 严格递增。命令批不共享 revision。

## 3. CanonicalReceiptHashV1

摘要输入使用以下确定字节序列：

```text
ASCII "WZX-RECEIPT-V1\0"
+ u32be(namespace_utf8_byte_length)
+ namespace_utf8
+ u32be(field_count)
+ each field in declared order:
     u32be(field_name_utf8_byte_length)
   + field_name_utf8
   + one_byte_type_tag
   + u32be(canonical_value_utf8_byte_length)
   + canonical_value_utf8
```

- namespace 和字段名使用 `[a-z][a-z0-9_]*`，namespace 最长 48 字节，字段名最长 64 字节。
- 类型标签固定为 ASCII `S`（字符串）、`I`（整数）、`B`（布尔）。
- 整数使用无前导零十进制；零为 `0`，负数只允许一个前导 `-`。禁止浮点、NaN、nil、表和隐式字符串转换。
- 布尔值编码为 `1` 或 `0`；字符串按原始 UTF-8 字节编码，不做区域化或 Unicode 归一化。
- namespace 进入摘要以提供领域隔离。摘要为 SHA-256 小写十六进制，最终 ID 为 `receipt_<namespace>_v1_<digest>`。
- 长度均为无符号 32 位大端整数；编码器必须拒绝超界长度。

## 4. ContentManifest 与版本

`ContentManifest` 必须同时包含 `content_version`、`rules_version`、`foundation_contract_version`、各 Schema 版本和生成器版本。三类业务版本不得互换；任何注册表哈希变化都必须进入 manifest 差异报告。

## 5. 槽 1 payload

槽 1 的 `SaveEnvelope.payload` 固定为 section 容器：

```text
payload = {
  manifest = {...},
  player_profile = {...},
  settings_profile = {...}
}
```

`SaveManifest` 指 `payload.manifest`，不是整个槽 1 payload。SectionOwnerRegistry 的路径均相对 `payload`；SaveCoordinator 负责合并，任何 section owner 不得覆盖同槽其他 section。

槽 1 的 owner 固定为：`manifest` 与 `player_profile` 归 18，`settings_profile` 归 24。`player_profile` 只保存建档时生成的内部存档作用域与创建元数据，不保存角色成长、任务进度、平台原始 AID 或任何可由其他 owner 推进的业务状态。

Y3 表存档的槽根表不计入“三层嵌套”：`payload` 是第 1 层、section 是第 2 层、section 内的行表或标量集合是第 3 层；第 3 层之下只能是标量。为此 `SaveManifest.slot_revision_entries` 不是“数组中再套行表”，而是固定扁平键表：每个槽 2–5 使用 `slot_<id>_schema_version/revision/checkpoint_id/payload_checksum` 四个标量键。任何整槽 Codec 必须在写平台前执行相同深度校验。

若 section 使用“行对象数组”，该数组本身必须是 `payload` 的直属 section，例如 `payload.character_rows[index].character_id`；禁止再包成 `payload.characters.character_rows[index]`，后者会把行对象推到第 4 层。一个逻辑 DTO 需要元数据和多组行时，必须拆成同一 owner 的多个直属 section，并由同一槽 change set 一次提交；不得把逻辑 DTO 根误当成额外的持久化层。

## 6. Lua 运行时交集

领域层采用 Lua 5.1 与 Y3 定制 Lua 5.4 的公共语法子集，不使用位运算符、`//`、`<close>`、`string.pack`、`table.unpack` 或引擎定点数隐式行为。确定性算法必须在离线 Lua 5.1 与 Y3 运行时执行同一黄金向量。

确定性 `root_seed/save_seed` 固定为整数 `1..2147483646`，不得在存档层改成字符串或从本地时间生成；`DeriveSeedV1` 与 Park–Miller 的乘数均以 06 冻结的 `48271` 为准。

`DeriveSeedV1` 的 namespace 是闭集，只允许 `combat` 与 `reward`。战斗 context 使用 run/challenge 身份；奖励 context 使用 10 定义的 `reward_seed` 规范收据 ID。任何新随机领域必须新增算法/契约版本，不得临时扩展 namespace 字符串。

`SaveEnvelope.owner_fingerprint` 固定为 `owner_v1_` 加 64 位 SHA-256 小写十六进制。哈希输入只能来自认证后的内部存档作用域；原始平台 AID 不得进入信封、业务日志或测试夹具。

## 7. 平台端口准入与完成边界

- 六个端口统一采用两段式调用：方法先同步返回 admission `Result`；请求、回调或 adapter 不合法时返回错误且永不回调。只有精确返回 `{ ok=true, value={ accepted=true } }` 后，adapter 才能在调用栈退出后的时点完成回调。
- AppFactory 在依赖注入边界为每个原始 adapter 创建只读 guard；业务只获得 guard，不获得 raw adapter。guard 捕获 adapter 抛错、非法 admission、inline callback、重复 callback、未知字段和非法成功 DTO。
- 请求在校验前生成无 metatable 私有快照；传给 adapter 的是第二份副本，完成门禁只绑定第一份副本。结果同样先生成无 metatable 快照再校验和交付，禁止调用方与 adapter 通过事后改表改变已经验证的事实。
- 请求和结果负载预算固定为：最多 8 层表、4096 个节点、262144 个字符串总字节；单个键最多 256 字节、单个字符串值最多 65536 字节。循环、共享表引用、稀疏/混合数组、非有限数和超预算负载全部 fail-closed。平台实测只能收紧 adapter 限制；扩大公共上限必须升级契约版本。
- 所有 `mutating=true` 操作必须同时 `requires_idempotency=true`。已接受写操作的成功 DTO 顶层必须包含 `request_key=context.idempotency_key`；错误完成必须在 `error.details.request_key` 回显同一键。
- 已接受写操作遇到畸形/超预算/错 request_key 的结果、内部 `PORT_*`/`FAKE_*` 错误、`PLATFORM_UNAVAILABLE` 或 `PLATFORM_RATE_LIMITED` 时，一律向上转换为不可盲重试的 `PLATFORM_RESULT_UNKNOWN`，并给出 `QUERY_OR_RECONCILE`。同步 admission 错误表示请求未被接受，不适用此转换。
- Port spec、operation 描述、App/service/schema facade、runtime host 和 registry 实例均使用私有 backing 与空壳只读 view。公开 operation 列表只是 defensive copy，修改它不得改变真实 validator 或 guard。

## 8. 角色等级曲线与升级奖励计划

- `LevelCurve.experience_cap` 是必填安全整数，范围为 `cumulative_exp_by_level[level_cap]..2^53-1`。角色满级后仍可累计阅历到该硬上限；任何会越界的增加必须整笔拒绝，不得钳制、部分应用或生成奖励计划。
- `LevelCurve.level_reward_refs` 只允许省略、空数组，或最多 64 行的精确 `{ reached_level, reward_ref }` 数组。`reached_level` 必须在 `2..level_cap` 严格递增，因此每个等级最多对应一个奖励包；`reward_ref` 必须是 `reward_` 内容 ID。省略与空数组统一规范化为空数组；旧版非空扁平字符串数组没有无歧义的等级含义，禁止猜测迁移并失败关闭。
- 等级变化只收集 `(old_level, new_level]` 内的奖励行。纯计划结构必须携带 `character_id`、`definition_version`、`curve_id`、`expected_revision`、`old_level`、`new_level` 和有序奖励行，输出 `reward_ref_count` 与 `reward_plan_digest`；非空计划摘要必须绑定这些字段。
- 空计划固定使用 64 个 `0` 的摘要哨兵；该哨兵只表达“没有奖励引用”，不证明角色、定义、曲线、修订或等级区间。当前外层 `command_digest` 也没有冻结全部计划上下文，因此受信用例必须把零计划与已验证的状态转换原子处理，且在完整端到端证明落地前生产阅历发奖保持关闭。非空计划先在 namespace `character_level_reward_plan_step` 中按序把 `ordinal/reached_level/reward_ref/previous_digest` 组成 SHA-256 哈希链，再在 namespace `character_level_reward_plan` 中把角色/定义/曲线/修订/等级区间、计数与最终链摘要封口；结果必须为非哨兵的小写 SHA-256。对非空计划改变上下文、顺序、等级或奖励引用必须改变摘要。
- 该摘要只证明纯 Lua 层准备提交的奖励意图，不构成奖励权益或平台提交证明。系统 10 的密封奖励目录 authority 负责验证引用并展开实际奖励；在该 authority 与完整 XP 加载、发奖、保存、查询/对账恢复循环通过门禁前，生产阅历发奖必须保持关闭。离线 Fake 或摘要黄金向量不得被表述为真实 Y3 平台能力已经验证。
