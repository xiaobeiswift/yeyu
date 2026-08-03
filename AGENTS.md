# 《雾州侠行》工程协作规则

本文件适用于整个工程。系统设计权威来源为 `docs/systems` 与 `docs/architecture`。

## 代码和依赖边界

- 项目 Lua 仅写入 `maps/EntryMap/script/wzx`，入口整合仅修改 `maps/EntryMap/script/main.lua` 与 `可重载的代码.lua`。
- `domain` 必须兼容 Lua 5.1 与 Y3 Lua 5.4 公共子集，不得引用 `y3.*`、平台句柄、UI、系统时间或 `math.random`。
- `.y3maker` 是本机外部工具链，版本记录在 `toolchain.lock`，禁止将其内容纳入顶层仓库。
- `maps/EntryMap/script/y3` 是只读子模块；升级必须单独提交并同步更新 `toolchain.lock`。
- 禁止手改 Y3 物编、地图、UI 和工程 JSON。必须使用 Y3 开发助手对应工具；普通项目配置、测试 fixture 不得伪装成 Y3 JSON。
- `config/generated` 和 Y3 mappings 只允许生成器写入，人工修改必须在生成源完成。
- 玩法与应用系统只能使用 `App.services` 暴露的受保护端口；原始 Y3/Fake adapter 只允许在 bootstrap 依赖注入边界出现，不得被业务模块保存或旁路调用。
- 端口调用先同步准入：返回 `ok=false` 表示未接受且不得再回调；只有返回 `{ ok=true, value={ accepted=true } }` 后才能在后续时点完成一次回调，禁止 inline callback。
- 所有已接受写操作的完成结果必须绑定 `context.idempotency_key`；畸形、超预算、串请求、内部错误、服务不可用或频控等无法证明未执行的结果统一按 `PLATFORM_RESULT_UNKNOWN` 进入查询/对账，禁止盲重试。

## 并行所有权

- `domain/common`、`application/ports`、`bootstrap`、聚合注册表、入口文件由集成负责人单写。
- 各系统只能写自己的领域/应用/测试目录，通过 registrar、schema declaration、SaveCodec 或 ScreenDescriptor 接入共享层。
- 共享存档槽由 SaveCoordinator 合并；系统不得直接写整槽或调用 SaveStore。
- 主地图、主 SceneUI 与生成产物保持单写；并行开发使用独立测试地图、Prefab 或 fixture。
- 跨系统契约发生破坏性变化时，先更新 ADR、版本与迁移，再修改消费者。

## 质量门禁

- 所有跨系统 ID、事件、section owner 和配置 schema 必须通过注册表校验。
- Port spec、App、service facade、runtime host 和 sealed registry 都是只读 authority；不得 shadow 方法、替换 operation 或把 defensive copy 当作可修改注册源。
- 每次提交至少通过与改动相关的离线测试；改变确定性规则时必须更新并审阅黄金向量，禁止顺手接受新黄金。
- Y3 API 必须先在 `maps/EntryMap/script/y3` 源码或项目参考文档中验证。
- 平台能力未形成验证报告前，只能使用 Fake 端口；不得宣称云档、擂台或真实付费链路完成。
