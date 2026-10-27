# 文件树复制路径菜单

## 实现范围

Files 与 Changes 中的文件、目录右键菜单增加 Copy Relative Path、Copy Absolute Path，保留 Reveal in Finder。复制目标固定为右键行，不依赖原有选中行，不改变阅读文件或目录展开状态；Changes 中已删除文件同样适用。相对路径以当前项目／worktree 根目录为基准，绝对路径包含当前根目录，中文和空格原样保留。分类标题、空白及禁用列表不提供路径菜单。

需求与预期已同步 tests/ui/README.md；PRD 未修改。

## 自动化与构建

13 项 FileTreeTests 通过，覆盖复制中文及空格路径、文件和目录、Files／Changes、删除文件、新根目录、保留选择和展开状态、无效目标，以及原有 Reveal in Finder 的目标一致性。测试使用独立剪贴板，不覆盖用户剪贴板。发行构建通过。

日志：本地 .build/path-menu-tests.log、.build/path-menu-build.log。

## 实窗验证

固定独立预览：.build/diagnostics/path-menu-20261027/VCode Path Menu Preview.app；源码、测试、UI 需求及预览二进制共 132 个文件已固定。

打开预览时系统报告 Mac 锁屏，未能完成右键菜单实窗验证，已请求用户解锁。待验证操作：Files 和 Changes 中对未选中的文件、目录右键，选择两种复制方式并粘贴核对；确认不打开文件、不切换阅读或展开目录。不能将自动化通过记为实窗通过。尚未提交或推送。


## 2026-10-28 解锁后续验

代理实窗验证通过的相关操作：

- Files 中先打开 .gitignore，再右键未选中的折叠 src 目录，菜单正常出现；当前阅读文件及选中行保持不变，src 未展开。复制相对路径后，在预览草稿粘贴得到 src。
- 展开 src，右键中文 file.ts，分别复制并粘贴得到 src/中文 file.ts 和当前根目录加 /src/中文 file.ts；空格与中文保持原样，没有引号。右键及复制没有打开目标文件，草稿仍是当前标签，目录仍保持展开。
- Changes 中右键 deleted.ts，复制后粘贴得到 src/deleted.ts；已删除条目可正常复制，不要求磁盘文件存在，没有打开删除 diff。
- Changes 中右键 src 目录，绝对路径粘贴结果是当前根目录加 /src，未折叠目录或切换当前草稿。
- 右键 Unstaged 分类不出现路径菜单；普通文件菜单包含 Copy Relative Path、Copy Absolute Path 和保留的 Reveal in Finder，Escape 可关闭菜单。

实际复制通过菜单点击、在预览草稿执行粘贴后核对文本完成，不只检查菜单存在。截图及 AX 证据：本地 .build/diagnostics/path-menu-20261027/menu.png、menu-ax.txt。固定的 132 个文件前后指纹一致，UI 阶段未修改产品代码或测试代码。

跨根目录、禁用列表及 Reveal in Finder 目标由前述自动化回归覆盖，本次未另外进行跨 worktree 和 Finder 外部窗口实测；不将这些自动化结果称为实窗结果。本次仅验收新增菜单相关操作，未重新执行全部 UI 用例或推送前完整检查。尚未提交或推送。
