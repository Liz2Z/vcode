# 右键菜单分组与移除访达入口

## 用户调整与实现

用户明确要求右键菜单分类并删掉在访达中打开。Files 保留相邻的相对／绝对路径复制；Changes 以原生分隔线将这两个复制操作与 Reveal in Files 定位操作分组。移除 Finder 菜单项、FileTree 回调与控制器绑定，不保留首尾分隔线或空分组。原有删除项禁用定位、路径复制和跨工作区目标校验继续生效。

## 自动化

16 项 FileTreeTests／FileTreeRevealTests 回归通过，日志 `.build/context-menu-groups-tests.log`；覆盖菜单分组与分隔线、文件和目录的路径复制、删除及重建同路径可用性、跨工作区旧菜单、Files 筛选清理、按需父目录，以及定位后保留编辑器和未保存内容。编译通过，产品及相关测试中没有残留 Finder 菜单入口或绑定。

本次用户未要求推送，未以局部回归宣称推送前完整自动化已经通过；未来推送前仍需按约定执行统一完整检查。本轮 UI 需求已同步，不能沿用此前包含 Finder 入口的旧版实窗通过结论。

## 预览边界

发布构建通过，日志 `.build/context-menu-groups-release.log`。独立预览 `.build/diagnostics/context-menu-groups-20261028/VCode Menu Groups.app` 已打开，使用临时 Git 仓库、独立 XDG 与唯一进程名，严格签名校验通过。源码、测试、UI 需求与预览二进制冻结于同目录 frozen.json。

实际菜单外观及操作尚未记为通过，不把测试中读取菜单结构当作真实右键验证。当前仅实现本次调整，不自行提交、推送；推送前仍需补齐完整自动化及本轮 UI 验收。

## 本地提交验证

用户随后明确要求“菜单分组也提交”。在编辑开关提交后的当前代码上，16 项 FileTreeTests／FileTreeRevealTests 再次通过（`.build/context-menu-commit-tests.log`），未再修改产品或测试逻辑。此次将菜单分组、移除访达入口及对应 UI 需求、测试和踩坑记录单独提交；不从本地提交授权推定推送，也不把本轮回归冒充完整 UI 验收。
