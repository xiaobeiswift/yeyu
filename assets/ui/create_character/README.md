# 新建角色 · 立档（编辑器画板）

## 你现在该做的

1. **打开预览**（对照搭板）  
   ```text
   assets/ui/create_character/preview/board.html
   ```
2. **导入资源**  
   ```text
   assets/ui/create_character/generated/
   ```
3. **按说明在 Y3 建画板**  
   - `IMPORT.md` — 操作步骤  
   - `BOARD_CONTRACT.md` — 节点命名  
4. 保存后告诉我「画板好了」→ 我接 shell

## 流程

```text
save_slot「新建」→ 显示 create_character 画板 → 确认写槽 → 回 save_slot
```

逻辑：`wzx/presentation/y3/create_character_shell.lua`（**只绑定，不 create_child**）  
名录：`wzx/config/content/create_character_roster.lua`

## 目录

| 路径 | 内容 |
|------|------|
| `preview/board.html` | **1:1 契约预览**（主） |
| `preview/create_character.html` | 旧山径风格草稿 |
| `generated/` | 可导入 PNG/JPG |
| `IMPORT.md` | 导入与搭板步骤 |
| `BOARD_CONTRACT.md` | 节点树契约 |
| `_gen_assets.py` | 重跑切图 |

## 非目标

- 运行时拼 UI（已弃）  
- 云档 CreateNewSave  
- 捏脸  
