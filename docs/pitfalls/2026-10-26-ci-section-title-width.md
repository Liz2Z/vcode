# CI 分组标题宽度断言失败

## 问题与证据

用户反馈 CI/CD 再次失败。GitHub Actions #20（25e6569）在 Run automated tests 失败，236 个测试中的一个用例 testGroupCountsStayBesideTitlesAndOutsideScrollbarAfterResizeAndCollapse 产生 4 条同样的断言：标题实际宽 103.0 点，小于固有宽度减去容差后的 103.5 点。打包、签名和发布均未执行，不能描述成发布步骤失败。

日志：https://github.com/Liz2Z/vcode/actions/runs/40300403815/job/121496576394

## 原因与措施

已核实是旧长标题在受限行宽下少了 0.5 点空间；云端系统字体度量与本机的差异尚未独立测量，不能直接写成已证实的系统字体 bug。用户已明确要求标题去掉重复的 Changes，本次仅使用 Staged／Unstaged 释放宽度，保持现有约束与测试原断言，不放宽容差、不删除检查、不改 CI 跳过测试。

本地 FileTreeTests 与 IndexActionTests 的 18 项已通过，含失败用例原有的宽度、三位计数、展开／折叠及滚动条检查。新构建的实窗和云端结果待验证，不能因本地通过便宣称 CI 恢复。

## 检查点

- 区分失败用例数量与断言数量，4 failures 不等于 4 个独立用例。
- 按真实失败步骤排查，不把测试失败归因于签名密钥或 Release。
- 布局空间不足先看产品内容与约束，不能通过放宽断言掩盖裁切。
- 以新提交的实际 Actions 状态确认云端恢复，命令行 GitHub token 失效不等于工作流权限失效。
