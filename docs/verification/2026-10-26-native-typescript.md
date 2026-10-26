# TypeScript 原生服务验证（2026-10-26）

## 实现与范围

语言服务使用 TypeScript 7.0.2 原生可执行文件，版本精确锁定。修改仅涉及代码智能后端、对应依赖、打包 / CI、相关回归与文档，未覆盖并行进行的 diff 实现。没有修改用户维护的 docs/PRD.md；没有提交或推送。

## 自动化

35 项相关测试全部通过，零失败、零跳过，包括真实原生服务的类型悬停、标准库 Array.map 类型推断与 lib.es5.d.ts 定义、连续嵌套跳转、引用数量与遮蔽作用域、文件内高亮、文档更新、WorkspaceController 的定义处引用交互，以及启动等待、内存异常、恢复、停止和缺少二进制的错误反馈。首次切换后两个引用断言失败；确认原生服务对 import 别名的声明分类差异后修改适配器，原数量断言保持原样并重新通过。

日志：本地 .build/diagnostics/native-lsp/native-tests.log（首次差异）、native-tests-fixed.log、compatibility-tests.log（35 项）。没有用自动化结果冒充手动鼠标操作。

## 构建与打包

使用独立 SwiftPM 构建目录完成 release 构建，避免与其他任务的构建锁冲突。独立预览应用通过深层严格签名校验；原生服务为 arm64，实际 --version 为 7.0.2，标准库声明随包分发。运行现有打包脚本成功生成 ZIP 与 DMG；脚本明确检查不包含 Runtime/node 与旧 node_modules。日志为本地 .build/diagnostics/native-lsp/release-build.log、package.log。

## 实窗与未完成项

通过独立 bundle ID、隔离 XDG 路径启动 VCode Native Preview。实窗确认已打开 TS diff 并显示 TypeScript Ready；原生进程采样显示 VCode 的唯一语言服务子进程为包内 TypeScript/tsc --lsp --stdio，没有 Node。截图与进程证据为本地 .build/diagnostics/native-lsp/preview.png、preview-processes.txt。

期间窗口状态在动作之间被其他操作改变，工具也返回用户已改变应用的提示；为避免干扰其他任务，不继续重复输入。类型悬停、使用处 ⌘点击跳转、定义处 ⌘点击引用列表三项标记为“需要用户验证”，已向用户发出具体确认请求；当前没有用户验证结果。未将被打断的点击当作通过，也没有执行全量 UI 验收。

UI 阶段产品和测试没有继续修改，冻结清单中的 12 个本次相关文件 / 构建二进制 SHA256 核对一致。其他任务的源文件及 UI 文档不在这个冻结清单内，不声称整个共享工作区不变。

## 内存对照

项目：/Users/zan/Code/idev-agent.worktrees/idev-002；文件 src/agents/command-environment.ts。独立启动旧服务与原生服务，发送同一初始化、didOpen、hover、definition、references、documentHighlight 请求序列，查询完成后各等待 3 秒，统计服务进程及所有子进程 RSS。未修改此真实项目，探测结束后只停止本探测启动的进程组。

| 服务 | 进程 | RSS 合计 |
| --- | --- | --- |
| 旧 Node 桥接 + tsserver | 2 个 Node | 909.4 MB |
| TypeScript 7.0.2 原生服务 | 1 个 tsc | 415.8 MB |

这次采样减少 54.3%。RSS 与资源窗口使用的 phys_footprint 不同，不能把截图中的 873 MB 直接作为本表基线。仅完成一次顺序对照，文件缓存、工作负载与长时间阅读都可能影响结果，不据此承诺所有项目固定降低 54%。原始记录在本地 .build/diagnostics/native-lsp/old-probe.json、native-probe.json 与 probe.py。

## 用户反馈：未找到预览

用户表示没有找到菜单栏名称 VCode Native Preview，此反馈不等于三项语言交互通过。代理随后按独立 bundle ID 定位、Raise 窗口，并实际打开该菜单；辅助功能返回菜单名称 VCode Native Preview。窗口标题仍是 primary — VCode，已明确区分两者并提供应用路径。未修改产品或测试代码，语言交互仍待用户验证。


用户反馈三个同名实例无法区分后，将本次专用临时项目目录重命名为“Go 原生服务测试”，通过预览自己的 Open Folder 打开。实窗已确认标题为 Go 原生服务测试 — VCode，左上角项目名相同，main.ts 已打开且 TypeScript Ready。未关闭其他实例，未修改产品或测试代码；该辨认操作不计为三项语言交互验证通过。


## 用户实测确认

用户在已明确辨认的“Go 原生服务测试”窗口中回复“没毛病，推送”。类型悬停、使用处 ⌘点击跳转、定义处 ⌘点击引用列表三项记录为用户实测通过，区别于代理实窗和自动化。随后用户新增测试版光剑图标需求，该项单独实现和验证，不倒推为此前已验收。


## 测试版光剑图标与独立提交快照

用户要求测试版用光剑图标。复用 Resources/Brand/Lightsaber/AppIcon-photoreal-v2.icns，未新增生成图像；MakeIcon 默认 preview、正式构建显式 release，GitHub 预览发行也显式选择 preview。分别运行两种图标打包配置，输出与对应批准的 ICNS 逐字节一致，AppKit 解码检查通过。已正常退出本次测试实例，替换预览图标、重新签名并重开；项目与标签恢复、TypeScript Ready。尝试观察 Dock 时系统报告锁屏，未重复尝试，已请求用户解锁；Dock / 应用切换器的实际图标仍待确认。

推送准备使用从 HEAD 加本任务 18 个文件构成的独立索引与检出副本；共享 tests/ui/README.md 仅选入原生服务与测试版图标条目。未选入另一路文件浏览、minimap 或用户维护的 PRD 改动。独立副本复制锁定的原生运行时并重跑完整测试和构建，避免依赖共享 dist 或变化中的语言服务文件；结果待完成后补录。


独立提交副本完整测试最终为 202 项，零失败、零跳过，发行构建通过；该数量对应仅包含本任务变更的 HEAD 快照，不包含另一路新增的忽略文件与 minimap 测试。日志为本地 .build/diagnostics/native-lsp/push-full-tests.log（退出码 0）与 push-build.log。该副本的原生 TypeScript 来自自己的固定资源目录，不再读取共享运行时。


## 图标占位纠正后的验证

用户随后提供实际 Dock 截图，指出圆角图标占位过满，授权修正。使用内置 imagegen 对原写实 v2 调整整体取景与透明边距，输出 AppIcon-preview-padded.png，生成多尺寸 ICNS 并更新 preview 打包引用；原素材保留，编辑提示词随资源保存。按 alpha > 0.05 测量，可见宽度从画布的 85.49% 降到 71.37%，不是只缩小内部光剑。该指标只证明透明占位，不能代替用户审美反馈。

新图标打包入口的 AppKit 解码与输出一致性通过，独立发行应用重新打包 ZIP / DMG 并通过签名检查；原生服务代码未变，未因纯图标素材修正重复跑整套 202 项后端回归。日志为 padded-alpha-bounds.log、padded-package.log。

预览正常退出、替换图标后重新签名并启动，项目、标签及 TypeScript Ready 恢复。Finder 图标视图中光剑图标正常显示，截图保存为 padded-finder.png。原生 Dock 工具请求超时，不重复尝试；Dock / ⌘Tab 中的最终留白效果已明确请求用户验证，目前待反馈。UI 阶段没有修改产品或测试代码。


## 最终用户确认与推送准备

用户回复“现在合适”，Dock / ⌘Tab 的光剑图标大小与透明留白记录为用户实测通过；不冒称为代理捕获 Dock 或应用切换器截图。此前悬停、使用处 ⌘点击及定义处引用列表也已有用户实测确认。本任务要求的受限 UI 项目现已完成用户验证。

推送前主线新增另一任务的 6c260db 提交，已独立推送到 origin/main。保留该提交，基于其重新构造仅包含原生服务和图标变更的提交快照；不回退另一路功能，也不选入 docs/PRD.md。合并后的回归结果另行补录。


## 本轮停止补跑与提交范围

用户明确要求“你不用跑测试了”。已停止正在执行的合并后完整回归，只结束本任务独立检出副本的 XCTest / SwiftPM 进程，未停止其他实例；这轮未完成，不记为全绿，也不继续补跑。此前独立本任务快照的 202 项完整测试、35 项相关测试、发行构建、打包和签名检查通过结果保留，不冒充合并后完整测试结果。

语言交互与最终图标均已有用户实测确认，Finder 及原生服务 Ready / 进程证据也已记录。遵循用户本轮明确停止测试并继续推送的指令，只提交原生服务、测试版图标、对应依赖 / 构建 / 回归和文档；保留已在主线的 6c260db，用户维护的 PRD 不纳入提交。后续只执行 Git 提交与推送，不再启动本地测试。
