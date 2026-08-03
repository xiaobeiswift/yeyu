# 《雾州侠行》工程协作规则

本文件适用于整个工程。系统设计权威来源为 `docs/systems` 与 `docs/architecture`。

## 代码和依赖边界

- 项目 Lua 仅写入 `maps/EntryMap/script/wzx`，入口整合仅修改 `maps/EntryMap/script/main.lua` 与 `可重载的代码.lua`。
- `domain` 必须兼容 Lua 5.1 与 Y3 Lua 5.4 公共子集，不得引用 `y3.*`、平台句柄、UI、系统时间或 `math.random`。
- `.y3maker` 是本机外部工具链，版本记录在 `toolchain.lock`，禁止将其内容纳入顶层仓库。
- `maps/EntryMap/script/y3` 是只读子模块；升级必须单独提交并同步更新 `toolchain.lock`。
- 禁止手改 Y3 物编、地图、UI 和工程 JSON。必须使用 Y3 开发助手对应工具；普通项目配置、测试 fixture 不得伪装成 Y3 JSON。
- `config/generated` 和 Y3 mappings 只允许生成器写入，人工修改必须在生成源完成。

## 并行所有权

- `domain/common`、`application/ports`、`bootstrap`、聚合注册表、入口文件由集成负责人单写。
- 各系统只能写自己的领域/应用/测试目录，通过 registrar、schema declaration、SaveCodec 或 ScreenDescriptor 接入共享层。
- 共享存档槽由 SaveCoordinator 合并；系统不得直接写整槽或调用 SaveStore。
- 主地图、主 SceneUI 与生成产物保持单写；并行开发使用独立测试地图、Prefab 或 fixture。
- 跨系统契约发生破坏性变化时，先更新 ADR、版本与迁移，再修改消费者。

## 质量门禁

- 所有跨系统 ID、事件、section owner 和配置 schema 必须通过注册表校验。
- 每次提交至少通过与改动相关的离线测试；改变确定性规则时必须更新并审阅黄金向量，禁止顺手接受新黄金。
- Y3 API 必须先在 `maps/EntryMap/script/y3` 源码或项目参考文档中验证。
- 平台能力未形成验证报告前，只能使用 Fake 端口；不得宣称云档、擂台或真实付费链路完成。

