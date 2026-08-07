# 立档画板契约 · `create_character`

你在 **Y3 编辑器 · EntryMap** 里新建画板，我只做运行时绑定（同 `save_slot`）。

## 画板

| 项 | 值 |
|---|---|
| 画板名 | **`create_character`**（必须完全一致） |
| 设计分辨率 | 1920×1080 |
| 默认可见 | **关**（`visible=false`，运行时打开） |
| 建议 zorder | 高于 `save_slot`（例如 500） |

## 必做节点树（名称必须一字不差）

```text
create_character                          ← 画板根
├── image_bg                              ← 图片：全屏背景（雾钟/山径）
├── layout_title                          ← 空节点/图片容器
│   ├── label_title                       ← 文本：山径立档
│   └── label_subtitle                    ← 文本：副标题（脚本会改）
├── layout_roster                         ← 左侧名单容器
│   ├── roster_btn_1 … roster_btn_6       ← 按钮（至少 4 个，建议 6）
│   └── roster_label_1 … roster_label_6   ← 文本：叠在按钮上的名（可选；无则用按钮字）
├── layout_stage                          ← 中央展示
│   ├── image_stage_frame                 ← 图片：相框/台座（可选）
│   ├── model_preview                     ← 【模型】控件（核心）
│   ├── label_glyph                       ← 文本：大字风骨（可选）
│   └── label_model_caption               ← 文本：预览说明（可选）
├── layout_detail                         ← 右侧铭文
│   ├── image_detail_panel                ← 图片：侧板底（可选）
│   ├── label_name                        ← 文本：角色名
│   ├── label_role                        ← 文本：身份·标签
│   ├── label_intro                       ← 文本：介绍（多行）
│   ├── label_stat_1 … label_stat_4       ← 文本：力/骨/身/息 标签（可选）
│   ├── bar_stat_1 … bar_stat_4           ← 图片：属性条（可选，脚本改宽度）
│   └── label_stat_val_1 … label_stat_val_4 ← 文本：数值（可选）
├── layout_button
│   ├── button_返回                       ← 按钮
│   └── button_确认立档                   ← 按钮
└── layout_tip
    └── label_tip                         ← 文本：底栏提示
```

## 控件类型对照

| 节点 | 类型 |
|------|------|
| `image_*` | 图片 |
| `label_*` | 文本 |
| `button_*` / `roster_btn_*` | 按钮 |
| **`model_preview`** | **模型**（UI 模型控件 / showroom） |

## 最少可用版（赶工）

若时间紧，只做这些也能绑：

1. 画板 `create_character`（默认隐藏）  
2. `image_bg` 全屏  
3. `label_title`  
4. `roster_btn_1`～`roster_btn_4`  
5. **`model_preview`**（模型）  
6. `label_name` / `label_intro`  
7. `button_返回` / `button_确认立档`  
8. `label_tip`  

其余节点缺失时脚本会跳过，不崩。

## 视觉建议

- 背景：可复用雾钟图 `134230791`（与 Loading / save_slot 同）  
- 名单按钮：可复用 `panel_slot` / `panel_slot_selected` 图  
- 主按钮：与 save_slot「进入」同套 primary  
- 中央模型区：约 480×560，偏中；右侧铭文宽约 360  

## 做好之后

1. 保存 EntryMap  
2. 告诉我「画板好了」  
3. 我改 `create_character_shell`：**只 `get_ui` + 绑事件/改字/换 model_id**，不再 `create_child` 叠层  

## 不要做

- 不要手改 `maps/EntryMap/ui/*.json` 仓库文件（工程规则：走编辑器）  
- 画板名不要叫 `CreateCharacter` / `createCharacter`（大小写与下划线按上表）  
