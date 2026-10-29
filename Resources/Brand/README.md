# VCode 标志资源

V 本身由两条纸带形成，底部只有一处折叠：左侧浅色纸带完整覆盖在右侧灰色纸带之上，不额外添加三角折面、金色或阴影。

- `VCodeMark.svg`：透明背景矢量标志。
- `AppIcon.svg`：1024 × 1024 应用图标矢量源文件。
- `AppIcon.png`：1024 × 1024 透明画布图标。
- `AppIcon.icns`：包含常用尺寸及 Retina 版本的 macOS 图标。
- `Preview.png`：图标预览。

构建流程通过 `scripts/MakeIcon.swift` 打包图标，由 `CFBundleIconFile` 引用 `Contents/Resources/AppIcon.icns`。默认测试／预览构建使用 `Lightsaber/AppIcon-preview-padded.icns` 的红蓝光剑 V；`VCODE_BUILD_FLAVOR=release` 使用本目录的灰白折纸 `AppIcon.icns`。GitHub 预览发行明确选择 preview。构建不需要 SVG 渲染工具；修改矢量设计后需同步更新 PNG 与多尺寸 ICNS。

## 内置图标库

View → App Icon 可选择六款图标：

- Origami：本目录的灰白折纸 V。
- Lightsaber：`Lightsaber/AppIcon-preview-padded.icns`，红蓝光剑 V。
- Gummy：`Gummy/AppIcon.icns`，紫底荧光绿软糖 V。
- Spectrum：`Spectrum/AppIcon.icns`，镜面反射与色散构成的光谱 V。
- Clock Colorful：`ClockColorful/AppIcon.icns`，浅杏色一体表盘，紫色／青色 11:04 指针与彩色内圈刻度。
- Clock Bauhaus：`ClockBauhaus/AppIcon.icns`，暖白色一体表盘，红蓝 11:04 指针、黄色轴心与黑色内圈刻度。

新增素材目录中的 `Source.png` 保留用户选定的原始图像；`AppIcon.png` 为去除底板外背景、增加透明留白的应用图标，`AppIcon.icns` 包含常用及 Retina 尺寸。软糖和光谱目录的 `PreparationPrompt.txt` 保存内置 imagegen 的素材准备提示词，不将写实图伪称为矢量源文件。两款钟表均保留用户明确选中的内圈刻度原稿，不采用后续沿边刻度方案；原始像素通过 AppKit 裁切、缩放及标准圆角轮廓导出，未重新生成或重绘指针、刻度。钟表导出参数见 [ClockIcons.md](ClockIcons.md)。

打包时六款均复制到 `Contents/Resources/AppIcons`。`VCodeDefaultAppIcon` 标识该安装包的缺省图标；应用偏好保存在 XDG CONFIG_HOME/vcode/app-icon.json，Use Build Default 恢复跟随当前构建。运行时使用 AppKit 更新 Dock 图标，打开关于面板时传入当前图标，不改写已签名的应用包；Finder 继续使用安装包的默认图标。
