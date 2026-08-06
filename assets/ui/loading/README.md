# Loading 背景

开场视频截取的**单张静图**，作 Loading 全屏底图。

## 现行方案

| 项 | 值 |
| --- | --- |
| 静图文件 | `assets/ui/loading/loading_bg.jpg`（视频 ~23.5s 雾钟） |
| 编辑器图标 | `loading_bg` → id **`134230791`** |
| 运行时 | `loading_shell.lua`：只用图标 ID / CDN，不用本地路径 |
| 入口 | `wzx.bootstrap.game_entry` |

序列帧方案已放弃。`frames/`、`runtime/`、`import/` 仅作素材备份，运行时不再切帧。

## 源

| 项 | 值 |
| --- | --- |
| 源文件 | `assets/video/kaichang.mp4` |
| 画面 | 雾钟 + 「雾州侠行」标题 |

## 换图

替换 `loading_bg.jpg`，或改 `loading_shell.lua` 里的 `PREFERRED_ICON_ID`。
