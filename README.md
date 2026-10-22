# VCode

一个只专注于文件浏览和 Git diff 的 macOS 原生工具。Swift + AppKit 实现，交互参考 VS Code。

## 玻璃界面与模块化布局

macOS 26 在侧栏使用系统 Liquid Glass（`NSGlassEffectView`）。导航、仓库切换入口、标签和路径信息使用平面布局，减少重复的玻璃轮廓。代码阅读区采用有圆角的深色面板。macOS 13–15 的侧栏使用系统磨砂材质。

文件浏览、标签导航、路径栏、双栏内容和状态栏都是各自独立的视图。侧栏宽度与 diff 两栏比例可以拖动调整；缩放窗口时保持合理侧栏宽度和阅读区空间。界面以灰度为主，搭配暖黄色的选中态、操作反馈和语法重点，diff 保留红绿增删语义。辅助文字和语法注释也保持可读对比。

Files / Changes 位于侧栏顶部，点击文件分别进入源码或 diff。阅读区只保留标签、路径和增删数量，不再放置整排操作按钮。TypeScript 类型通过悬停查看，定义只通过 `⌘点击` 跳转；不提供 F12 或字号调整快捷键。引用查询从类型浮层或标识符右键菜单进入。文件树可直接在 Finder 中定位所选文件。按钮具有悬停、按下、选中与键盘焦点反馈。最后一个标签关闭时清空阅读区，提示从侧栏选择文件；尚未打开项目时显示打开目录入口，迟到的读取结果不会重新打开内容。

顶部 **Branch** 和 **Worktree** 按钮显示当前位置，点击打开可搜索的单层列表。支持切换已有本地分支、打开当前仓库的其他 worktree；如果分支已在另一个 worktree 使用，会打开该 worktree。分支切换遵循 Git 的默认保护：保留兼容的本地修改，遇到覆盖风险则失败并显示原因，不做强制切换、自动 stash 或清理。不会创建分支、创建 worktree 或获取远端分支。

全部文件树默认折叠，改动树的已暂存／未暂存两组及其目录默认全部展开。目录支持点击整行展开／折叠，包含文字和右侧空白；悬停、按下和选中使用不同的背景反馈。用户主动折叠的改动目录在刷新时保留。Git 一次读取文件路径清单，目录节点按展开层级创建；文件内容只在打开时读取。刷新时若路径和变更状态未变化，复用现有树节点。过滤输入有短暂防抖，只展开匹配结果的路径；定义跳转仅展开目标文件的父目录。

视觉层级使用底色、明度和留白表达，避免重复边框。标签选中态只作用于整个标签，标题不再绘制独立按钮底框。外侧面板圆角为 16 pt，内侧控件圆角为 8 pt；常用控件间距为 8 pt、模块间距为 12 pt、内容边距为 16 pt、区域间距为 24 pt。源码模式省去重复标题，代码采用 12 pt Monaco（回退 Menlo），行高为 20 pt；按字体度量居中文字基线，行号与源码对齐。

## 当前功能

- **Files**：项目文件树、路径过滤、标签页、完整源码预览。
- **Changes**：已暂存／未暂存各有一棵目录树；已暂存比较 HEAD 与暂存区，未暂存比较暂存区与磁盘。
- diff 显示完整文件上下文、对齐行号、同步纵向滚动、行级和字符级差异，支持跳转上一处 / 下一处改动。
- 同一文件可同时出现在两组中，并各自打开带 Staged / Unstaged 标记的独立标签；显示新增、删除、重命名和未跟踪文件。两个方向的修改即使互相抵消，也保留在各自分组。
- TypeScript / TSX 词法高亮；LSP 提供悬停类型和 ⌘点击定义跳转，在 diff 右栏也能使用。
- 点击标识符后高亮当前文件中的语义定义与引用；⌘悬停确认可跳转后加下划线，跳转目标闪烁提示 2 秒。类型提示支持格式化、语法颜色和移出后延迟关闭。
- Recent 按项目展示最近打开过的目录与 worktree；历史、上次目录和窗口布局遵循 XDG 规范持久化。
- 文件变化后自动刷新；普通文件夹也可浏览。

当前为**只读查看器**。Python 暂时只提供纯文本预览，后续可增加对应高亮与语言服务。

Markdown 默认展示原生排版预览，支持标题、列表、链接和语法高亮代码块；可直接切换 Source / Preview，改动仍使用双栏 diff。

## 打开应用

```sh
open dist/VCode.app
```

按 `⌘O` 选择文件夹。打开仓库内的子目录时，会定位到 Git 仓库根目录。

也可以指定仓库：

```sh
open dist/VCode.app --args /path/to/repository
```

应用已经运行时，使用窗口里的 Open Folder 或 `⌘O` 切换项目。

## 快捷键

| 操作 | 快捷键 |
| --- | --- |
| 打开文件夹 | `⌘O` |
| 全部文件 / 改动文件 | `⌘1` / `⌘2` |
| 刷新 | `⌘R` |
| 关闭当前标签 | `⌘W` |
| 上一处 / 下一处改动 | `⌥↑` / `⌥↓` |
| 跳转定义 | `⌘点击` |
| 类型信息 | 悬停 |

分支和 worktree 切换通过窗口顶部的对应按钮进入。

## 本地开发

需要 macOS 13+、Xcode Command Line Tools 或 Xcode，以及 Node.js 22.22.2+ / npm。当前构建使用本机架构。

```sh
npm ci --prefix Tools/TypeScript --ignore-scripts --registry=https://registry.npmjs.org --no-audit --no-fund
swift test
bash scripts/build.sh
```

打包脚本生成 `dist/VCode.app`，包含 Node 和 TypeScript 语言服务，可直接从 Finder 打开。Node 仅用于语言服务，界面与文本绘制使用 AppKit。语言服务首次打开 TS 文件时启动，每个工作区使用一个 TS server，关闭最后一个标签、关闭应用或切换项目后停止。

测试包含真实 Git 仓库、增删行对齐、UTF-16 位置映射、原生文本排版，以及真实 TS LSP 的类型信息、定义和文档更新，以及真实分支／worktree 切换、5 万文件的延迟建树、目录整行点击、暂存／未暂存版本隔离和独立标签。

UI 需求与预期见 [tests/ui/README.md](tests/ui/README.md)。每次推送前按文档完成 UI 测试，每次更新功能同步维护对应用例。

## GitHub 自动打包

推送任意分支或标签后，GitHub Actions 的 **Build macOS arm64** 自动运行测试，再构建 Apple Silicon（M 系列芯片）版本。也可以在 Actions 页面选择 **Run workflow** 手动运行。

`main` 构建成功后，自动在仓库的 [Releases](https://github.com/Liz2Z/vcode/releases) 创建 **Pre-release**，附带 ZIP、DMG 和 `SHA256SUMS.txt`。每次使用独立标签 `preview-<运行编号>-<重跑次数>`，指向本次构建的完整提交 SHA，保留已有预览版；重跑也不会覆盖旧包。手动运行 main 的工作流同样发布预览版。

其他分支或标签只生成 Actions 产物：进入对应运行记录的 **Artifacts**，下载 `VCode-macos-arm64-<提交 SHA>`。DMG 打开后将 VCode 拖到 Applications，ZIP 解压后同样得到 `VCode.app`。应用内已包含 arm64 Node 和 TypeScript 语言服务，目标电脑无需另装 Node。

工作流采用 macOS 26 arm64 runner，依赖按 lockfile 安装；测试、打包或产物校验失败不会发布 Release，失败日志单独保留。Actions 安装包保留 14 天，测试日志保留 7 天；Release 附件不受这两个保留期限制。仅发布任务获得仓库写权限，使用 GitHub 自动提供的工作流 token，不需要个人 token。CI 自动化不代替推送前的真实窗口 UI 验收。

当前产物仍是 ad-hoc 签名，未做 Apple Developer ID 签名或公证；下载到其他 Mac 后可能需要在系统“隐私与安全性”中确认打开。

本地也可以在构建后生成相同的 arm64 安装包：

```sh
bash scripts/package-macos.sh
```

## 边界

- 单文件预览上限 4 MB；超过约 80 万个 UTF-16 单元的内容暂停语法高亮。
- 二进制文件和符号链接提供说明，不渲染为代码。
- 当前定义跳转限于打开的仓库内；仓库内的依赖文件即使未显示在文件树里，也可打开。
- TS 服务占用取决于项目规模，使用 LSP 时仍有独立后台进程的成本。
- 应用使用本地 ad-hoc 签名，尚未做 Developer ID 签名和公证。

## DDD 代码组织

代码按限界上下文组织，各层只在有实际职责时建立：

```text
Sources/VCode/
├── Application/                 # 进程启动、窗口和菜单装配
├── Shared/DesignSystem/         # 玻璃材质、颜色和通用原生控件
└── Contexts/
    ├── Git/
    │   ├── Domain/             # Git 状态、变更、分支、worktree 和统一仓库端口
    │   ├── Application/        # 统一 GitService：状态、比较、目标查询和切换规则
    │   ├── Infrastructure/     # Git CLI 适配器，实现领域端口
    │   └── Presentation/       # 分支和 worktree 选择界面
    ├── FileBrowsing/
    │   ├── Domain/             # 源文件内容、路径树索引和文件访问错误
    │   ├── Application/        # 独立的文件枚举与读取能力
    │   └── Infrastructure/     # 文件系统和目录监听
    ├── Reading/
    │   ├── Domain/             # 阅读会话、标签、源码快照和 diff 行模型
    │   └── Presentation/       # 标签、路径、源码与 diff 绘制
    ├── CodeIntelligence/
    │   ├── Domain/             # 语言信息、源码位置、检查结果和语言服务错误
    │   ├── Application/        # 文档同步、悬停和定义用例
    │   ├── Infrastructure/     # TS 子进程、JSON-RPC 连接、分帧和结果转换
    │   └── Presentation/       # 类型浮层和定义候选
    └── Workspace/
        ├── Domain/             # 组合文件清单与 Git 状态的只读模型
        ├── Application/        # 组合 Git 与文件能力、管理异步读取和切换生命周期
        └── Presentation/       # 工作区装配、文件/改动树、模块布局和用户操作衔接
```

领域层只依赖 Foundation。**changes、分支、worktree 都属于同一个 Git 上下文**，通过同一个 `GitService` 和 `GitRepository` 端口使用；界面位置不决定领域边界。Git CLI 参数、输出解析和进程通信由 `GitCLI` 适配器负责。Git 上下文不依赖文件浏览、工作区组合模型或代码绘制。

`FileBrowsing` 独立负责文件枚举、安全路径和内容读取，不依赖 Git；普通目录可以单独使用。`WorkspaceReader` 组合这两个应用服务，生成工作区状态和阅读快照，不拥有 Git 的分支占用、worktree 可用性或切换规则。`WorkspaceSession` 管理异步任务、刷新、失效和生命周期，UI 通过它调用统一的 Git 能力。

LSP 的原始 JSON 在基础设施层转换成类型化的检查结果，界面直接展示领域结果。代码阅读和语言智能的领域模型彼此独立。`ArchitectureTests` 检查分层依赖、Git 与文件浏览的独立性，以及工作区和表示层不直接使用 Git CLI 或文件系统适配器。

- `Tools/TypeScript`：由 lockfile 固定的语言服务依赖。
- `tests/VCodeTests/Contexts`：按所属上下文放置流程与领域测试。
- `tests/VCodeTests/ArchitectureTests.swift`：分层依赖检查。
