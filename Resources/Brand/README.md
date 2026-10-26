# VCode 标志资源

V 本身由两条纸带形成，底部只有一处折叠：左侧浅色纸带完整覆盖在右侧灰色纸带之上，不额外添加三角折面、金色或阴影。

- `VCodeMark.svg`：透明背景矢量标志。
- `AppIcon.svg`：1024 × 1024 应用图标矢量源文件。
- `AppIcon.png`：1024 × 1024 透明画布图标。
- `AppIcon.icns`：包含常用尺寸及 Retina 版本的 macOS 图标。
- `Preview.png`：图标预览。

构建流程通过 `scripts/MakeIcon.swift` 打包图标，由 `CFBundleIconFile` 引用 `Contents/Resources/AppIcon.icns`。默认测试／预览构建使用 `Lightsaber/AppIcon-preview-padded.icns` 的红蓝光剑 V；`VCODE_BUILD_FLAVOR=release` 使用本目录的灰白折纸 `AppIcon.icns`。GitHub 预览发行明确选择 preview。构建不需要 SVG 渲染工具；修改矢量设计后需同步更新 PNG 与多尺寸 ICNS。
