# 标识符定义与引用的概览标记

## 范围

普通只读源码和 diff 都使用 30 点右侧概览。中央亮黄色列对应当前正文中的语义定义／引用，Git 删除与新增分别使用左红、右绿列。草稿、Markdown 预览及其他滚动条不随之改造。颜色按用户纠正由蓝色改为亮黄色。

预览窗口项目名为“黄色引用预览”，应用位于 `.build/diagnostics/symbol-yellow-20261028/VCode Yellow References.app`，使用独立 XDG 目录。

## 自动化验证

- 最终亮黄色版本 39 项相关测试通过，无失败，包含概览、标识符反馈、视口、展示及真实原生 TypeScript 语义查询。日志 `.build/symbol-yellow-tests.log`。
- 覆盖 UTF-16 中文／emoji、diff 占位行映射、同一行去重、迟到结果、空白清除、切换内容、源码导航、编辑器隔离、浅深两种外观中三种标记同一行的绘制。
- release 构建成功，日志 `.build/symbol-yellow-build.log`。
- 未执行推送前完整 `scripts/check.sh`，不以这些局部回归替代。

## 代理实窗结果

- 真实 TypeScript Ready 后普通点击外层标识符：正文高亮与概览同时出现，三个黄色标记包含定义与屏幕外两处引用；局部同名变量及注释没有混入。浅色、深色都可辨。证据 `source-light.jpeg`、`source-dark.jpeg`。
- 切换至 diff：原引用清除，红绿 Git 标记保留。重新点击右栏标识符后黄色三个标记出现，第一行黄／红／绿分列，不遮挡正文或标题。证据 `diff-clear-on-switch.jpeg`、`diff-light.jpeg`、`diff-dark.jpeg`。
- 概览辅助功能值设为 0.32：左栏原行 100 与右栏行 103 的同一引用按插入空白对齐，黄色标记保留。此为辅助功能定位，并非真实拖动。证据 `diff-position.jpeg`。
- 切回源码：没有旧引用或 Git 标记。点击另一个标识符后只剩其单个黄色标记；再点空白，正文和概览高亮同时清空。证据 `source-clear-on-switch.jpeg`、`replace-symbol.jpeg`、`clear-on-blank.jpeg`。
- 所有截图位于 `.build/diagnostics/symbol-yellow-20261028/`。`frozen.json` 在最终签名后记录源文件、测试、UI 需求及预览二进制哈希，实窗结束后全部复核一致。

## 验证边界

本次只执行相关 UI 操作，不宣称完整 UI 用例通过。连续拖到首尾有既定工具限制，沿用此前用户实际确认的基线，未重复尝试。本轮尚未实窗执行分栏往返、切换工作区、外部刷新和真实拖动全过程；已有相应自动化或生命周期回归不能冒充实窗结果。未提交或推送。用户维护的 PRD 变更保留，代理未修改。
