# 开局 UI 与官方平台接入约定

## 当前状态（干净起点）

**地图 UI 已清成空壳；开发入口不再自动挂开局/对话界面。**

| 项 | 状态 |
|---|---|
| 预设画板 GameHUD / CommonTip / Loading / Logo / win / loss | 空 `children`，默认隐藏 |
| 自定义 panel_1 / hero 元件 | 已删除 |
| CommonTip 对话框链路 | 已退役（`common_tip_panel` 为 no-op） |
| `dev_runtime` | 只启 Foundation host + `sanitize_startup_ui` |
| 屏上 print / profile 叠层 | `main.lua` 关闭 |

备份：`archive/ui_json_backup_before_cleanup/`（含清理前 CommonTip 与原 2.4MB GameHUD）。

## 以后怎么接 UI（重头做）

1. 以空 **GameHUD** 为 host，用 `create_child` 或新 Prefab 搭正式界面。  
2. 开局逻辑仍在 `wzx.application.boot.boot_flow`（纯逻辑，与表现解耦）。  
3. 对话内容/播放器仍在 `wzx.config.content.dialogue.*` 与 `presentation/greybox/dialogue_player`。  
4. 新 shell 挂载时再写 `presentation/y3/*`，**不要**再绑已清空的 CommonTip 树。

## 原则（平台）

**UI 按双后端设计；官方云档在未验证前只可展示为锁定态。**

| 后端 | 状态 | 玩家能做什么 |
|---|---|---|
| 本地开发档 | 可用（逻辑层） | 三槽新建 / 进入 / 删档（需重新做表现） |
| 官方云档 | UNVERIFIED 锁定 | 验证通过前不可写入 |

逻辑模块：

| 模块 | 作用 |
|---|---|
| `wzx/application/boot/boot_flow.lua` | 纯逻辑开局状态机 |
| `wzx/application/boot/platform_backend_status.lua` | UI 用后端状态契约 |
| `wzx/application/boot/local_run_slot_store.lua` | 本地三槽 |
| `wzx/adapters/y3/official_cloud_gate.lua` | 官方门闩 + SaveStore 探测 |

## 官方何时从锁定变为可进

1. 实现真实 `SaveStore`（槽 1–5 envelope）  
2. 按 `docs/service-validation/01-云存档.md` 跑满必测  
3. `platform_adapters_verified = true` 且状态 `AVAILABLE`  
4. `feature_flags.cloud_save = true`  
