# CI 与本地工具链对齐验证

## 范围

共同基线 `.ci/toolchain.env`、Xcode 选择与校验、完整检查入口、构建入口和 CI 报告上传。产品 Sources、正式 XCTest 用例及 UI 需求均未修改；沿用 6366e66 相同产品版本已通过的实窗验收，不增加无关 UI 用例。此前冻结的产品、测试和 UI 需求散列核对无变化。

## 本机结果

- 基线匹配：Xcode 26.2（17C52）、Swift 6.2.3、macOS SDK 26.2、arm64 Node.js 22.22.2、npm 10.9.7；系统实际为 macOS 26.3。未改全局 xcode-select。
- 通过新检查入口完成 236 项 XCTest，0 失败，result.txt 为 exit_code=0；环境信息和完整日志真实存在。SwiftPM 串行 XCTest 不支持所尝试的 XML 输出，已移除无效 XML 参数及上传声明，串行执行方式不变。没有将零用例 Swift Testing XML 计作 XCTest 报告。
- 缺少指定 Xcode 与错误 Node 版本的独立进程探测均明确返回 1；错误 Node 的 result.txt 同样为 exit_code=1，没有执行依赖安装或测试。
- 更新后的 build.sh 选择同一 Xcode／Swift／SDK，发行构建通过。Shell 语法、工作流 YAML 解析和补丁空白检查通过。

本地证据保存在 `.build/diagnostics/toolchain-alignment-20261026/`，构建日志为本地 `/tmp/vcode-toolchain-alignment-build.log`。

## 云端边界

官方 macos-26 arm64 清单已确认 Xcode 26.2（17C52）可选。工作流会显式选择它，未安装时失败而不回退。实际云端版本和通过结论仍需以本次提交的 Select project Xcode、environment.txt 及 Actions 最终状态为准，不以旧流水线成功替代。

宿主 macOS／AppKit／字体、显示缩放和速度不随 SDK 固定，环境报告保留真实系统版本。此次没有声称已经修复上一轮排查中的布局断言和异步等待契约。
