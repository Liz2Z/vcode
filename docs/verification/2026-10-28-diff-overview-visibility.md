# Diff 概览宽度与可见性

## 范围与构建

用户要求 diff 滚动条更宽、更明显，并明确 20 点仍窄，最终采用 30 点。修改仅覆盖 diff 概览宽度、滑块灰色反馈及对应回归／UI 需求。

最终预览：`.build/diagnostics/overview30-20261028/VCode Overview 30.app`。实窗检查后核对源文件、测试、UI 需求哈希一致。可执行文件哈希在签名后补记于 `frozen.json`，签名前的记录保留于 `pre-signing-hashes.json`，不把签名造成的二进制变化说成源码变更。

## 自动化验证

- DiffOverviewTests、PresentationTests、CodeViewportTests 合计 27 项通过，无失败。日志：`.build/overview30-tests.log`。
- release 构建成功。日志：`.build/overview30-build.log`。
- 这些为本次相关回归，不替代推送前 `scripts/check.sh` 的完整检查。本次未提交、未推送。

## 代理实窗验证

- 浅色、深色：静止滑块清楚可辨，红绿标记可见，左右正文、行号及固定标题完整。截图：`light-static.jpeg`、`dark-static.jpeg`。
- 概览辅助功能值设为 0.5：两栏同步定位，左侧原行 237 与右侧现行 243 的同一内容对齐。此为辅助功能定位，不标为真实鼠标拖动。截图：`light-middle.jpeg`。
- 切回普通源码：概览消失，原生细滚动条恢复，正文收回占位。截图：`source.jpeg`。
- 截图位于 `.build/diagnostics/overview30-20261028/`。

## 验证边界

连续拖动至首尾已有工具限制，沿用此前用户明确确认的行为基线，本次未修改拖动计算，未重复尝试该受限操作。真实悬停及拖动反馈的主观体验需要用户验证；不据此宣称全部 UI 用例通过。
