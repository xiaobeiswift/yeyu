# 开局 UI 与官方平台接入约定

## 当前状态

| 项 | 状态 |
|---|---|
| 预设画板 GameHUD / CommonTip / Loading / Logo / win / loss | 空壳，默认隐藏（不复用旧树） |
| **Loading 页（首个重建页面）** | `loading_shell`：单张静图 + 进度 |
| **选择角色页** | `save_slot_shell` + 画板 `save_slot`（五角色位） |
| **局内最小 HUD** | `game_hud_shell` 挂空 `GameHUD`（身份条 + 返回角色选择） |
| **本地进档会话** | `local_run_session`（进档快照；尚未接云档 CreateNewSave/Load） |
| 背景图 | `assets/ui/loading/loading_bg.jpg`（开场雾钟静帧，角色页复用） |
| CommonTip 对话框链路 | 已退役（`common_tip_panel` 为 no-op） |
| 正式入口 | `wzx.bootstrap.game_entry`（debug / release 同一条） |
| `dev_runtime` | 仅 debug 热重载：清模块后转调 `game_entry` |
| 屏上 print / profile 叠层 | `main.lua` 关闭 |

备份：`archive/ui_json_backup_before_cleanup/`。

### Loading 页用法

正式入口在 `main.lua` → `wzx.bootstrap.game_entry`（debug 经 `dev_runtime` 热重载转调同一入口）。

```lua
local LoadingShell = require 'wzx.presentation.y3.loading_shell'
LoadingShell.mount()
LoadingShell.set_progress(42, '整理行囊…')
LoadingShell.on_finished(function()
    -- 切到标题/主菜单
end)
LoadingShell.run_boot_progress({ duration = 3.0 })
```

Loading 结束后由 `game_entry` 自动：

```text
Loading → 选择角色(save_slot) → 进入 → local_run_session → GameHUD 最小壳
```

```lua
-- 进档后（game_entry 内）
local LocalRunSession = require 'wzx.application.boot.local_run_session'
local GameHudShell = require 'wzx.presentation.y3.game_hud_shell'
LocalRunSession.start(payload) -- backend_id, slot_index, run_id, display_name, chapter_hint
GameHudShell.mount({
    on_return_to_slots = function()
        -- 开发期：回角色选择
    end,
})
```

源文件：

| 路径 | 作用 |
|---|---|
| `assets/ui/loading/loading_bg.jpg` | Loading 静图 |
| `wzx/presentation/y3/loading_shell.lua` | Loading 运行时表现 |
| `maps/EntryMap/ui/save_slot.json` | 选择角色画板 |
| `maps/EntryMap/ui/prefab/save_slot_card.json` | 单卡预制体 |
| `wzx/presentation/y3/save_slot_shell.lua` | 角色页绑定 + 点击 |
| `maps/EntryMap/ui/GameHUD.json` | 局内 host（空壳，运行时挂子节点） |
| `wzx/presentation/y3/game_hud_shell.lua` | 最小局内 HUD |
| `wzx/application/boot/local_run_session.lua` | 本地进档会话 |
| `wzx/application/boot/boot_flow.lua` | 纯逻辑开局状态机 |
| `wzx/application/boot/local_run_slot_store.lua` | 本地五槽 |

## 以后怎么接 UI

1. 以空 **GameHUD** 为 host，用 `create_child` 或新 Prefab 搭正式界面（Loading 已按此做；角色页用编辑器画板）。  
2. 开局逻辑仍在 `wzx.application.boot.boot_flow`（纯逻辑，与表现解耦）。  
3. 对话内容/播放器仍在 `wzx.config.content.dialogue.*` 与 `presentation/greybox/dialogue_player`。  
4. **不要**再绑已清空的 CommonTip 树。

## 原则（平台）

**UI 按双后端设计；官方云档在未验证前只可展示为锁定态。**

| 后端 | 状态 | 玩家能做什么 |
|---|---|---|
| 本地开发档 | 可用 | 五槽新建 / 进入 / 删档（`save_slot` 画板） |
| 官方云档 | UNVERIFIED 锁定 | 验证通过前不可写入（角色页暂不展示后端 Tab） |

逻辑模块：

| 模块 | 作用 |
|---|---|
| `wzx/application/boot/boot_flow.lua` | 纯逻辑开局状态机（含 `open_local_slots`） |
| `wzx/application/boot/platform_backend_status.lua` | UI 用后端状态契约 |
| `wzx/application/boot/local_run_slot_store.lua` | 本地五槽 |
| `wzx/presentation/y3/save_slot_shell.lua` | 选择角色表现层 |
| `wzx/presentation/y3/game_hud_shell.lua` | 局内最小 HUD |
| `wzx/application/boot/local_run_session.lua` | 进档会话快照 |
| `wzx/adapters/y3/official_cloud_gate.lua` | 官方门闩 + SaveStore 探测 |

## 进档后现状与下一步

| 已有 | 未做 |
|---|---|
| 进档会话 + 最小 HUD | 云档 CreateNewSave / LoadGameSave / hydrate |
| 返回角色选择（开发按钮） | 任务 / 背包 / 对话 / 轻功等正式 HUD 模块 |
| 地图输入在角色页锁定、进档后恢复 | 持久化本地槽到磁盘 |
| **立档图 `CreateCharacter`** | 正式选人 UI / 单位出场动画 |

### 立档切图

| 项 | 值 |
|---|---|
| 关卡目录 | `maps/CreateCharacter` |
| 关卡 ID（**UUID，切图用**） | `790bd0ad-91e6-11f1-a87d-25a4c7a653a4` |
| header.map 十进制（勿直接 switch） | `160897935248241842341095906248275415972` |
| EntryMap UUID | `73763292-8f4c-11f1-9d30-93a4cd3b7dcd` |
| 入口 | save_slot「新建」→ `CreateCharacterIntent.begin_from_slot` → `switch_level` |
| 回程 | 立档图 SPACE 占位立档 / ESC 取消 → 写 intent → 回 EntryMap 直开 save_slot |
| 跨图状态 | `custom/wzx_boot_intent.lua`（`BootIntentStore`） |

立档图脚本：`maps/CreateCharacter/script/main.lua`（package.path 指向 EntryMap/script 以共用 wzx/y3）。

## 官方何时从锁定变为可进

1. 实现真实 `SaveStore`（槽 1–5 envelope）  
2. 按 `docs/service-validation/01-云存档.md` 跑满必测  
3. `platform_adapters_verified = true` 且状态 `AVAILABLE`  
4. `feature_flags.cloud_save = true`  
