# 开局 UI 与官方平台接入约定

## 启动链路

1. **开场动画**（15s 文案节拍 / 可选视频）  
2. **定格最后一帧** → 点 **进入游戏**（可先点 **跳过动画** 直接定格）  
3. **开局菜单**（本地档 / 官方锁定）  
4. 进入后 **对话**

| 模块 | 作用 |
|---|---|
| `wzx/application/boot/opening_cinematic.lua` | 纯逻辑：PLAYING → HOLDING → ENTERED |
| `wzx/config/content/opening/opening_cinematic_v1.lua` | 时长、节拍、跳过/进入文案、视频开关 |
| `wzx/presentation/y3/opening_cinematic_shell.lua` | CommonTip 展示 + 跳过/进入按钮 |

### 接入开场视频（以编辑器实际能力为准）

**已确认事实：**

1. **资源管理器没有「导入视频」**——没有 video 分类，这是对的。  
2. **视频控件属性里也没有 URL 字段**——路径不在属性面板配。  
3. 你已建好画板：`OpeningCinematic` / 控件：`video`（UI type **51**）。  
4. 播放只能靠运行时 API 把路径塞给控件：  
   `GameAPI.play_ui_video_comp(player, video.handle, path, ...)`  
5. 不要用 `type(GameAPI.xxx)=='function'` 判断 API 是否存在（Y3 C 绑定会误判成 missing）。

**文件位置（任选，代码会试）：**

- `custom/Video/kaichang.mp4`  
- `assets/video/kaichang.mp4`  

**配置：** `opening_cinematic_v1.lua` → `comp_path = 'OpeningCinematic.video'`

**日志成功标志：**

- `视频控件已找到: OpeningCinematic.video`  
- `play_ui_video_comp OK` 或 `play_ui_video OK`  

播完 / 跳过 → 定格 → 进入游戏。  
若控件在、API 也 OK 仍无画面，再查路径格式（绝对路径 / webm / 平台限制）。

## 原则

**UI 现在就按双后端设计；官方云档在未验证前只可展示为锁定态。**

| 后端 | 状态 | 玩家能做什么 |
|---|---|---|
| 本地开发档 | 可用 | 三槽新建 / 进入 / 删档（内存槽，开发用） |
| 官方云档 | UNVERIFIED 锁定 | 看到原因与下一步；不可写入 |

同一套 `BootFlow` 屏幕：标题 → 选后端 → 槽位 → 进入。  
官方验证通过后：改 `OfficialCloudGate.platform_options` + 实现 `SaveStore` Y3 adapter，**不必重做开局流程**。

## 代码位置

| 模块 | 作用 |
|---|---|
| `wzx/application/boot/boot_flow.lua` | 纯逻辑开局状态机 |
| `wzx/application/boot/platform_backend_status.lua` | UI 用后端状态契约 |
| `wzx/application/boot/local_run_slot_store.lua` | 本地三槽 |
| `wzx/adapters/y3/official_cloud_gate.lua` | 官方门闩 + SaveStore 探测 |
| `wzx/presentation/y3/common_tip_panel.lua` | 绑定地图自带 **CommonTip** 对话框（有按钮贴图，能看见） |
| `wzx/presentation/y3/boot_menu_shell.lua` | 开局流程 → CommonTip 三按钮 |
| `wzx/presentation/y3/greybox_dialogue_shell.lua` | 对话流程 → CommonTip |

> 注意：空 `create_child` 控件没有皮肤时常常**完全看不见**；本项目改用编辑器里已有的 `CommonTip`。

## Y3 里你怎么点（主路径）

1. 调试运行 EntryMap  
2. 屏幕中间应出现 **系统对话框**（半透明底 + 标题 + 正文 + 按钮）  
3. 点 **开始**  
4. 点 **本地档**  
5. **切换** 选槽 → **新建** → **进入**  
6. 对话：点 **开始** / **继续**；选项时点 **选项1/2/3**  

键盘仍可用作兜底。

日志顺序（冷启动）：

1. `等待游戏初始化后再绑 UI`  
2. 可能有几次 `boot 第N次失败`（初始化前 get_ui 必失败，正常）  
3. `bound OK` / `Boot UI ready`  
4. **屏幕正中出现 CommonTip 对话框**

## 官方何时从锁定变为可进

1. 实现 `wzx.adapters.y3` 下真实 `SaveStore`（槽 1–5 envelope，非随意表字段）  
2. 按 `docs/service-validation/01-云存档.md` 跑满必测并写证据  
3. `platform_adapters_verified = true` 且验证状态 `AVAILABLE`  
4. `feature_flags.cloud_save = true`  

在此之前打开官方入口写档 = 违规宣称完成。

## 说明

- 当前面板是 **运行时动态创建** 的控件（挂在 `GameHUD` 等已有画板下），还不是编辑器里精修的美术 UI。  
- 以后可在 UI 编辑器做正式 Prefab，再换成绑定路径；`BootFlow` / 对话 ViewModel **不用重写**。  
