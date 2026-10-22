# VCode 标志资源

V 本身由两条纸带形成，底部只有一处折叠：左侧浅色纸带完整覆盖在右侧灰色纸带之上，不额外添加三角折面、金色或阴影。

- `VCodeMark.svg`：透明背景矢量标志。
- `AppIcon.svg`：1024 × 1024 应用图标矢量源文件。
- `AppIcon.png`：1024 × 1024 透明画布图标。
- `AppIcon.icns`：包含常用尺寸及 Retina 版本的 macOS 图标。
- `Preview.png`：图标预览。

构建流程通过 `scripts/MakeIcon.swift` 将本目录的 `AppIcon.icns` 打包为应用的 `Contents/Resources/AppIcon.icns`，由 `CFBundleIconFile` 引用。构建不需要 SVG 渲染工具；修改矢量设计后需同步更新 PNG 与多尺寸 ICNS。
