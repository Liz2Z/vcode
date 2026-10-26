# Git 忽略文件名称置灰（2026-10-26）

## 实现与自动化

Files 使用 Git 已有 ignoredPaths 结果标记被忽略的文件和文件夹，沿路径祖先识别按需加载的后代；不递归补扫忽略目录，不逐行启动 Git。名称使用随浅色／深色外观解析的 Theme.muted，选中和展开能力保持。已跟踪例外、否定规则例外及仅被应用排除检索但未被 Git 忽略的目录保留正常文字。Changes 保持原有改动样式。

WorkspaceState 传递独立的忽略状态，FileTree 的刷新比较包含忽略路径，即使路径清单没变也更新配色。UI 需求已同步到 tests/ui/README.md。

最终 31 项文件树、忽略内容浏览及工作区读取相关测试通过，发布构建通过。本次没有重新执行完整自动化检查或全量 UI 验收，不将前一次关闭标签功能的 241 项结果作为本次完整检查。初轮新增测试误用会抑制选择回调的 tree.select，修正为真实列表选择入口后，7 项忽略浏览测试及最终 31 项相关测试均通过；保留首轮失败日志。

## 实窗结果

固定预览使用独立应用身份、临时 Git 项目及隔离 XDG 目录。

- 浅色与深色下，cache、deep、generated.ts、local.env 和 build.log 显示灰色；相邻的 cache-neighbor、main.ts、keep.log 及已跟踪 tracked.ts 使用正常颜色。
- 实际点击灰色文件夹行逐级展开，再点击 generated.ts 和 local.env，正文分别显示对应文本。选中背景与灰色名称清楚可辨，没有把置灰项禁用。
- 外部移除 local.env 的忽略规则后自动刷新，名称恢复正常颜色并显示未跟踪状态；恢复规则后又置灰。没有手动刷新或重新打开目录。
- Files 筛选 generated 显示零结果，清空后恢复已展开的忽略目录；Changes／Files 往返后列表与忽略样式保留。既有 Quick Open／全文搜索排除行为由本轮相关自动化覆盖，没有重新逐项实窗验收。

一次筛选操作遇到工具报告窗口状态改变；重新观察并取得当前控件后完成筛选，没有根据旧控件编号继续盲目操作。鼠标悬停的精确颜色未单独实测，不将选中截图充作悬停证据；该交互实现本次未变。

## 证据与边界

本地 `.build/diagnostics/ignored-style-20261026/` 保存独立预览、浅色／深色截图、最终状态及模式往返截图和指纹；测试日志为 `.build/ignored-style-tests.log`、`.build/ignored-style-tests-final.log`、`.build/ignored-style-related-tests.log`，构建日志为 `.build/ignored-style-build.log`。

UI 阶段没有修改产品或测试代码；源码、测试、UI 需求及预览可执行文件共 131 份指纹对照未变化。本次没有提交或推送，用户维护的 docs/PRD.md 未修改。
