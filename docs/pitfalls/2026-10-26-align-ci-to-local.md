# CI 应选择项目工具链，不跟随 runner 默认 Xcode

## 问题与用户要求

此前给出环境对齐建议后，用户明确要求让 CI 对齐本地。不能要求用户追随云端默认 Xcode，也不能只打印版本就宣称已经对齐。

## 已核实原因

本机 Xcode 26.2（17C52）、Swift 6.2.3、macOS SDK 26.2、arm64 Node.js 22.22.2、npm 10.9.7。CI 之前使用 macos-26 镜像默认 Xcode 26.6／Swift 6.3.3。工作流虽有 Verify toolchain，但没有选择或校验 Xcode 版本。

已查阅官方 runner 软件清单，当前 macos-26 arm64 同时提供 `/Applications/Xcode_26.2.app`，构建号为 17C52：https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md 。该清单可能更新，实际缺少匹配版本时应明确失败，不能自动换到其他版本。

## 修正措施

`.ci/toolchain.env` 作为共同基线。CI 选择匹配的 Xcode 并通过 DEVELOPER_DIR 传给后续步骤；Node 版本同样从基线提供给 setup-node。本地和 CI 使用 scripts/check.sh 执行锁定依赖准备、隔离 XDG 状态、串行完整自动化测试和报告；scripts/build.sh 也选择并校验相同 Xcode／Swift／SDK，不改系统 xcode-select。版本不符立即报错。报告记录实际系统、工具链、SDK、Node、npm、Git 和提交，失败保留退出码与日志。

这里只对齐编译器、SDK、依赖与检查入口。GitHub 托管 macOS 版本、系统 AppKit、字体、显示缩放和执行速度不会随 DEVELOPER_DIR 固定，不能声称与本机完全相同。没有改产品 UI、布局测试或异步测试；这些问题按前一轮排查单独处理，不混入环境改造。

## 检查点

- 工具链版本来自同一基线文件，工作流和脚本不各写一份版本号。
- 不依赖全局 xcode-select，也不修改用户系统默认 Xcode。
- 本地和 CI 走同一完整自动化入口；正式 UI 用例仍只描述界面需求，不写构建命令。
- 已有报告目录不复用，避免失败时混入旧测试结果；每轮应用存储独立。
- 先验证本机完整检查和失败分支，再以真实 CI 环境报告确认云端选择结果。

实现后的完整检查、构建及云端结果待验证，不能用旧 CI #21 的成功代替本轮验证。

## 报告能力核实

本机通过共享入口运行 236 项测试、0 失败，构建通过。首次尝试使用 SwiftPM --xunit-output，但串行 XCTest 不输出指定 XML，仅生成了零用例的 Swift Testing XML。不能将这个空报告冒充 236 项测试报告。移除该参数和 XML 产物声明，继续保存真实 XCTest 完整日志与退出状态，保持原有串行执行方式，不为生成 XML 改成多进程执行。SwiftPM 官方说明：https://github.com/swiftlang/swift-package-manager/issues/8000 。
