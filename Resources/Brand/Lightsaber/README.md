# 光剑 V 备选标志

左侧蓝色光剑、右侧红色光剑在底部交叉形成 V，蓝剑位于上层。剑刃保留白色亮芯与红蓝光晕，短金属剑柄位于交点下方，使整体以 V 形为主。

- `AppIcon.svg`：矢量应用图标源文件。
- `VCodeMark.svg`：透明背景的独立标志。
- `AppIcon.png`：1024 像素图标。
- `AppIcon.icns`：常用尺寸及 Retina 版本的 macOS 图标。
- `Preview.png`：深色背景预览。

早期平面构图保留为设计参考。测试／预览构建现采用下方写实 v2 光剑图标，正式构建仍采用上级目录的灰白折纸 V。

## 写实渲染备选

- `AppIcon-photoreal-v2.png`：当前写实备选，收短并收细剑柄，保留自然辉光、金属加工细节与红蓝反光。
- `AppIcon-photoreal-v2.icns`：对应的多尺寸 macOS 图标。
- `PhotorealPrompt-v2.txt`：内置 imagegen 使用的完整生成与比例修正提示词。
- `AppIcon-photoreal.png` 与 `PhotorealPrompt.txt`：第一版写实渲染，作为迭代参考保留。

原 SVG 只对应早期平面构图版，不是写实渲染的等价矢量文件。写实 v2 已用于测试／预览版应用图标，早期平面版不作为默认测试版图标。


## 测试版留白修正

- `AppIcon-preview-padded.png`：基于写实 v2 的测试版图标，整体缩小、四周保留透明边距。
- `AppIcon-preview-padded.icns`：对应的多尺寸 macOS 图标，供 preview 构建使用。
- `PreviewPaddingPrompt.txt`：内置 imagegen 的编辑提示词。

用户指出 Dock 中原版占位过满；此版保留红蓝光剑 V 样式，将完整图案和圆角底板作为整体收小。写实 v2 源素材保留，测试版打包改用留白版。
