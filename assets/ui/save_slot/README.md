# 选择角色画板（save_slot）

对应 Y3 画板：`maps/EntryMap/ui/save_slot.json`  
界面语义：**五角色位**（有档进入 / 空位新建 / 删除）  
设计基准：1920×1080

## 预览

浏览器打开：

```text
assets/ui/save_slot/preview/save_slot.html
```

交互：点选角色位、新建、进入、删除、返回。无无本地/云档 Tab，无快捷键条。

## 预制体 `save_slot_card`（已落盘）

路径：`maps/EntryMap/ui/prefab/save_slot_card.json`  
根尺寸：**300×520** · key `651de8bd-801a-4a7d-9af9-94fe816d3f3a`

| 子节点 | 类型 | 默认 | 说明 |
|--------|------|------|------|
| `frame` | 图 134266962 | 显示 | 卡片框 |
| `index` | 文本 | 显示 | 位号，如「位 一」 |
| portrait | 图 **134262480** | **隐** | 有档头像占位（斗笠侠客剪影） |
| `empty_icon` | 图 134244552 | 显示 | 空位 + |
| `portrait_ring` | 图 134259647 | **隐** | 选中光环 |
| `name` | 文本 | 显示 | 角色名 /「空 位」 |
| `chapter` | 文本 | 显示 | 章节或「尚未立档」 |
| `time` | 文本 | 显示 | 时长/更新，空位时提示文案 |
| `selected_mark` | 图 134248131 | **隐** | 底部选中条 |

重跑补丁：`python assets/ui/save_slot/_patch_prefab.py` 后热更 UI 编辑器。

## 布局节点（画板 save_slot）

| 逻辑名 | 类型 | 说明 |
|--------|------|------|
| `bg` | 全屏图 | 复用 loading 雾钟 `134230791` |
| `header_title` | 文本 | 「选择角色」 |
| `slot_1` … `slot_5` | 元件实例 | 挂 5 份 `save_slot_card` |
| `btn_back` / `btn_delete` / `btn_create` / `btn_enter` | 按钮 | 底栏 |
| `message` | 文本 | 状态提示 |

## 编辑器图标 ID（已导入）

对照表：`assets/ui/save_slot/icon_ids.json`  
包目录：`custom/OriginalRes/icon/*.package`  
表项：`editor_table/resicon.json`

| 逻辑名 | icon_id | 用途 |
|--------|---------|------|
| `panel_slot` | **134266962** | 角色位卡片框 |
| `panel_slot_selected` | **134226841** | 选中位框 |
| `btn_primary_normal` | **134248131** | 进入 |
| `btn_primary_hover` | **134218584** | 进入悬停 |
| `btn_primary_pressed` | **134231186** | 进入按下 |
| `btn_secondary_normal` | **134242431** | 新建 |
| `btn_secondary_hover` | **134246465** | 新建悬停 |
| `btn_danger_normal` | **134244576** | 删除 |
| `btn_danger_hover` | **134272161** | 删除悬停 |
| `btn_ghost_normal` | **134269797** | 返回 |
| `icon_empty_slot` | **134244552** | 空位 + |
| `portrait_ring` | **134259647** | 选中头像环 |
| `portrait_placeholder` | **134262480** | 有档头像占位 |
| `loading_bg`（复用） | **134230791** | 全屏底 |

备用（当前界面不用）：`panel_modal` 134228414 · `icon_cloud_lock` 134250496 · `icon_backend_local` 134270479 · `icon_backend_cloud` 134231311

## 资源清单

路径：`assets/ui/save_slot/generated/`

| 文件 | 用途 | 建议尺寸 | 九宫格 |
|------|------|----------|--------|
| `panel_slot.png` | 槽卡片框（无字） | 512×768 | 角 48 / 边均匀 |
| `panel_slot_selected.png` | 选中槽外框光 | 512×768 | 同几何 |
| `panel_modal.png` | 锁定弹窗框 | 768×512 | 角 48 |
| `btn_primary_normal.png` | 主按钮（进入） | 512×128 | 左右 64 |
| `btn_primary_hover.png` | 主按钮悬停 | 同左 | 同几何 |
| `btn_primary_pressed.png` | 主按钮按下 | 同左 | 同几何 |
| `btn_secondary_normal.png` | 次按钮（新建） | 512×128 | 左右 64 |
| `btn_secondary_hover.png` | | | |
| `btn_secondary_pressed.png` | | | |
| `btn_danger_normal.png` | 危险（删档） | 512×128 | |
| `btn_danger_hover.png` | | | |
| `btn_danger_pressed.png` | | | |
| `btn_ghost_normal.png` | 幽灵（返回） | 512×128 | |
| `btn_ghost_hover.png` | | | |
| `btn_ghost_pressed.png` | | | |
| `icon_empty_slot.png` | 空槽「+」占位 | 256×256 | — |
| `icon_cloud_lock.png` | 云档锁定 | 256×256 | — |
| `icon_backend_local.png` | 本地档 Tab 图标 | 128×128 | — |
| `icon_backend_cloud.png` | 云档 Tab 图标 | 128×128 | — |
| `portrait_ring.png` | 选中头像光环 | 256×256 | — |

### 已生成（2026-08-07）

| 文件 | 状态 |
|------|------|
| `panel_slot.png` / `panel_slot_selected.png` | ✅ |
| `panel_modal.png` | ✅ |
| `btn_primary_{normal,hover,pressed}.png` | ✅ |
| `btn_secondary_{normal,hover}.png` | ✅（pressed 可后续补） |
| `btn_danger_{normal,hover}.png` | ✅ |
| `btn_ghost_normal.png` | ✅ |
| `icon_empty_slot.png` / `icon_cloud_lock.png` | ✅ |
| `icon_backend_local.png` / `icon_backend_cloud.png` | ✅ |
| `portrait_ring.png` | ✅ |
| `deco_corner.png` | ⏸ 暂缓（角花已烘焙进 panel） |
| secondary/danger/ghost pressed | ⏸ 引擎侧可用 CSS/亮度替代 |

预览：

- 界面：`preview/save_slot.html`
- 资源墙：`preview/gallery.html`

**硬规则**：除标题字体外，位图资源**不写任何文字**（引擎本地化）。  
**背景**：首版直接复用 `assets/ui/loading/loading_bg.jpg`（运行时暗化），不必再导一张全屏底。

## 色板

| 名 | 色值 | 用途 |
|----|------|------|
| ink | `#0b1214` | 深底 |
| fog | `#6a7c7e` | 次要字 |
| gold | `#c9a45c` | 强调 / 选中 |
| gold-bright | `#e8d09a` | 标题 |
| patina | `#3d6b62` | 铜绿点缀 |
| danger | `#8b3a3a` | 删档 |

## 与逻辑字段映射

| UI | ViewModel 字段（建议） |
|----|------------------------|
| 角色位 1–5 | `slots[1..5]`（`local_run_slot_store.SLOT_COUNT = 5`） |
| 空态 | `empty == true` |
| 角色名 | `display_name` |
| 章节 | `chapter_hint` |
| 时长 | `play_time_label` |
| 更新 | `updated_label` |
| 选中 | `selected_slot_index` |
