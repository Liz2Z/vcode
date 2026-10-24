# 异步悬停测试不能依赖固定睡眠后直接索引

## 问题与纠正后的预期

用户报告白天主题提交 0f3422f 的 CI 失败，并提供日志。日志显示 Git 测试已通过，IdentifierFeedbackTests.testCommandHoverOnlyUnderlinesConfirmedTargetsAndReleaseClearsIt 开始后发生 Swift Array 的 Index out of range，测试进程以 signal 5 退出；不是打包或发布步骤失败。

## 原因与证据范围

原测试在发出 ⌘悬停事件后只运行 RunLoop 130 ms，随后读取 answers[0]／answers[1]。产品的定义探测本身有 90 ms 防抖，留下的时间余量不足以保证 CI 处理队列；首个 count 断言也不是终止断言，失败后仍可能索引空数组，第二次索引连计数断言都没有。相邻的旧请求测试也使用相同模式。

这些不安全的时序假设和数组访问已通过代码核实；用户提供的日志没有崩溃栈，具体是哪次索引、CI 当时是否有主线程负载尚未直接核实，不能把推断写成已重现的云端调度证据。本机为 Xcode 26.2，用户 CI 日志为 Xcode 26.6，也不能把本地通过当成同一工具链的证据。

## 修正措施

用 XCTestExpectation 等待实际的第一、第二次探测，各有明确超时；获取回调使用 XCTUnwrap，缺失时报告测试失败并安全退出用例，不继续访问越界数组。用 0 和 200 ms 的延迟交付覆盖正常和超过原等待窗口的情形。相邻旧请求测试同样按回调推进；同步引用测试也安全获取回调，避免掩盖后续失败信息。产品代码和 UI 行为不变，不向 tests/ui/README.md 添加 CI 流程条目。

## 防止再犯

- 正向异步测试以事件／条件完成为依据，不以固定 sleep 或短暂运行 RunLoop 作为完成证据。
- XCTAssertEqual 的失败不会终止测试；后续依赖项要用 XCTUnwrap 或 guard 安全获取。
- 覆盖迟到回调，同时保留旧请求失效、无定义不高亮、松开 ⌘ 清除下划线的行为断言。
- 区分产品缺陷、测试进程崩溃与云端环境故障；本地、云端和用户实窗结果分别记录。

本次回归结果待补录。GitHub CLI 当前凭据无效，云端日志来自用户粘贴，未取得修复后的云端运行结果。


## 提交前验证结果

修改后的 4 项 IdentifierFeedbackTests 先通过一轮，再连续运行 10 轮，全部通过；包含正常和 200 ms 延迟交付两种情况。随后使用与 CI 一致的独立 XDG state/config/data/cache 目录运行完整测试，198 项、0 失败。日志分别位于本地 .build/ci-hover-timing-tests.log、.build/ci-hover-repeat/ 和 .build/ci-hover-full-tests.log。

已通过登录的 Chrome 会话核对云端失败运行 40095560850，失败步骤为 Run automated tests，发布任务被跳过；命令行 GitHub 认证不可用不妨碍使用浏览器查看。产品 Sources、UI 需求与此前实窗／用户验证通过的 0f3422f 完全一致，本次只修改测试与说明；不以 CI 测试修复为由改产品或增加无关 UI 用例。推送前沿用同一产品版本已通过的主题 UI 验证与两类悬停卡片用户确认。没有修改 docs/PRD.md。

以上为修复提交前的本地验证记录，尚不是修复后的云端通过证据；后续以修复提交对应 Actions 结果为准。
