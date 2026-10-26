# 忽略文件浏览验证（2026-10-26）

## 自动化与构建

204 项完整测试通过，无失败、无跳过；包含忽略文件浏览、浅层加载、刷新与恢复、路径边界、符号链接，以及依赖目录和已打开忽略文件的外部变化监听。发布构建通过。完整日志位于本地 .build/diagnostics/ignored-browsing/full-tests.log。

## 代理实窗

固定构建使用独立应用身份、临时 Git 项目和隔离 XDG 目录；实窗期间产品源码与测试指纹未变。

- 初始 Files 显示 ignored、node_modules、dist、空目录和 local.env，目录默认折叠，数量用加号表示尚有按需加载内容。
- 实际点击 ignored、nested 后看到 ignored-only.ts，点击后读取完整源码，TypeScript Ready；node_modules 和 pkg 也能逐级展开。
- 在 Files 打开忽略文件后，⌘P 搜索其名称显示 No matching files；侧栏筛选同名文件也无结果。
- 全文搜索 shared_needle 仅返回 main.ts 与强制跟踪的 ignored/keep.ts，共 2 个文件、2 个命中；忽略文件、local.env、依赖与生成内容不进入结果。
- 外部新增 node_modules/pkg/added.ts 后，无手动刷新即出现；同时修改正在阅读的忽略源码后，源码由 ignoredValue 自动更新为 ignoredUpdated。
- 未通过：普通目录展开后多出空白行。已定位 FileTreeIndex 把目录占位路径（例如 ignored/）作为该目录自己的空名称子项。截图保存为 .build/diagnostics/ignored-browsing/blank-row-before.png。尚未修改产品或测试，已请求用户明确授权修复并重新验收。

## 首轮结论（修复前）

不能记为 UI 全部通过。目录空白行待用户授权修复；尚未完成修复后的空目录、会话重开等最终验收。本次未提交或推送。用户维护的 docs/PRD.md 未修改。

## 修复后验证

用户明确授权修复并重新验收。新增目录占位回归先在旧实现中失败（5 项断言），修正后通过。完整测试为 205 项，零失败、零跳过，发布构建通过。日志分别为本地 .build/diagnostics/ignored-browsing/blank-row-before-fix.log、blank-row-after-fix.log、repaired-full-tests.log 和 repaired-release-build.log。

使用修复后的独立预览与新临时项目重新操作：

- 实际展开普通目录、嵌套忽略目录与空目录，未再出现空名称或目录自身子项；点击忽略文件正常阅读源码。
- 侧栏筛选与 ⌘P 均不匹配忽略文件；全文搜索仍仅返回正常文件与已跟踪例外，共 2 个文件、2 个命中。
- 清空筛选、Changes / Files 切换后目录子项正确，没有空白行。
- 外部增加忽略目录内文件后点击刷新，新文件出现且没有空白行。
- 正常退出并重开应用，项目、忽略文件标签、ignored / nested 展开层级恢复，新文件仍在，源码正常显示且 TypeScript Ready，没有空白行。未将空目录的展开状态或非零滚动位置恢复纳入本次通过结论。

截图保存于本地 .build/diagnostics/ignored-browsing/blank-row-fixed.png、before-reopen-fixed.png、reopened-fixed.png；重开后的原生控件状态为 reopened-fixed-ax.txt。

修复后实窗复验通过。复验阶段未修改产品或测试代码，冻结清单内 149 个文件的 SHA256 均未变。本次未提交或推送，用户维护的 docs/PRD.md 未修改。
