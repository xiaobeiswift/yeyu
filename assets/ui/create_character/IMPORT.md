# 立档页 · 资源导入与搭板（给你操作）

## 1. 先看预览

浏览器打开：

```text
assets/ui/create_character/preview/board.html
```

- 左侧：名单  
- 中间：模型区（引擎里换成**模型控件**）  
- 右侧：铭文 + 属性  
- 底栏：返回 / 确认立档  

线框总览图：

```text
assets/ui/create_character/generated/layout_wireframe_1920.png
```

## 2. 资源目录（全部导入 Y3 图标）

```text
assets/ui/create_character/generated/
```

| 文件 | 建议用途 | 尺寸 |
|------|----------|------|
| `bg_fog_clock.jpg` | `image_bg` 全屏底（也可复用已有 `134230791`） | 全屏 |
| `panel_stage_frame.png` | `image_stage_frame` 中央台 | 560×640 |
| `panel_detail.png` | `image_detail_panel` 右侧板 | 380×620 |
| `panel_roster_item.png` | `roster_btn_*` 常态 | 280×72 |
| `panel_roster_item_selected.png` | 名单选中态 | 280×72 |
| `panel_roster.png` | 备用大卡片框 | — |
| `panel_roster_selected.png` | 备用选中大框 | — |
| `btn_back.png` / `btn_back_hover.png` | `button_返回` | 按钮 |
| `btn_confirm.png` / `btn_confirm_hover.png` | `button_确认立档` | 按钮 |
| `btn_ghost.png` | 返回悬停备用 | — |
| `bar_stat_track.png` | 属性条底 | 220×14 |
| `bar_stat_fill.png` | 属性条填充（脚本改宽） | 220×14 |
| `deco_title_left/right.png` | 标题金线（可选） | 300×28 |
| `model_placeholder.png` | **仅 HTML 预览**；引擎用模型控件 | 480×560 |

> 按钮/名单也可直接复用 save_slot 已导入图标（见 `assets/ui/save_slot/icon_ids.json`）。

## 3. 编辑器操作步骤

1. 打开 **EntryMap** → UI 编辑器  
2. **新建画板**，名称严格：`create_character`  
3. 画板属性：  
   - 设计 1920×1080  
   - **默认可见 = 关**  
   - zorder 建议 ≥ 500  
4. **导入图标**：把 `generated/` 里需要的 PNG 拖进资源 / 图标库  
5. 按 `BOARD_CONTRACT.md` 建节点（名称一字不差）  
6. 中央放 **模型** 控件，命名 **`model_preview`**  
7. 保存地图  

### 推荐布局（像素）

| 区域 | 大致位置 |
|------|----------|
| `layout_title` | 顶居中 y≈30–100 |
| `layout_roster` | 左 x≈48，y≈140，宽 300 |
| `layout_stage` | 中 x≈420，y≈120，560×640 |
| `model_preview` | 舞台内约 480×520 |
| `layout_detail` | 右 x≈1500 或 right 对齐，380×620 |
| `layout_button` | 底 y≈1000 居中两按钮 |
| `layout_tip` | 最底提示行 |

## 4. 最少可跑（赶工）

只做这些也能绑 shell：

- `create_character`（隐藏）  
- `image_bg`  
- `roster_btn_1`…`roster_btn_4`  
- **`model_preview`**（模型）  
- `label_name` / `label_intro`  
- `button_返回` / `button_确认立档`  
- `label_tip`  

## 5. 做完后

回一句：**「画板好了」**  

我会：

1. 用工具读画板树核对节点名  
2. 确认 `create_character_shell` 绑定  
3. 接好「新建 → 切页 → 确认写槽」

## 6. 重新生成切图

```text
python assets/ui/create_character/_gen_assets.py
```
