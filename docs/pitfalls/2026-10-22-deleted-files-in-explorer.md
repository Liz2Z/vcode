# 已删除文件残留在 Files

## 问题与预期

用户截图指出 Files 中仍列出多个 D 状态的已删除文件。Files 应表示当前磁盘上的项目文件；删除记录留在 Changes 中对照旧内容，不能作为可阅读源码再次混入 Files。

## 原因与修正

GitCLI 将 `git ls-files --cached --others --exclude-standard` 的路径和所有 Git 改动路径合并。前者含暂存区中尚未暂存删除的路径，后者又加入已暂存删除和重命名相关路径。文件树直接使用这份合集，即使刷新也仍包含不存在的文件。

最初提出在 Git 路径合集上按实际存在性过滤，用户指出这种来源本身不合理。该方案撤回：Files 改由 FileBrowser / SourceFileStore 枚举磁盘上的文件，WorkspaceReader 组合实际文件与 Git 状态；GitStatus 移除 files 字段，避免界面再次误用 Git 状态充当磁盘目录。Git 通过原生命令 check-ignore 执行忽略规则过滤，保留已跟踪文件的例外，不手写 .gitignore 解析。不能只按 D 状态排除：暂存删除后同路径重新创建时，新文件实际存在，Files 应允许阅读，而 Changes 仍保留暂存删除记录。

## 检查点与验证

- 覆盖未暂存删除、已暂存删除、重命名后删除目标、删除后重新创建、未跟踪文件、忽略文件，以及只含已删除文件的目录。
- 同一个 WorkspaceReader 刷新后应得到更新列表，Changes 的删除 diff 仍有旧内容且右侧为空。
- 固定构建后再进行真实窗口验证，验收时不修改产品或测试代码；验证结果如下。

## 本次验证结果

修复前新增回归复现了旧列表残留；最终实现的 WorkspaceReader、GitService、FileTree 和架构测试共 27 项全部通过。覆盖中文、制表符和换行路径，以及忽略目录中强制跟踪的文件例外。发布构建成功并签名。

独立实窗初始 Files 只含 5 个实际文件，删除路径与忽略文件不在其中；应用打开期间删除 remove-live.ts 后，不点击 Refresh，列表自动更新到 4 项，Changes 从 5 条更新到 6 条。分别点击未暂存和已暂存删除记录，左侧显示 INDEX／HEAD 的旧源码，右侧工作区／INDEX 为空；返回 Files 后点击 recreated.ts，展示重新创建后的源码。Sources 与 tests 的指纹在实窗验收前后完全一致，未修改产品或测试代码。证据与日志位于本地 `.build/diagnostics/deleted-files/`。

后续性能优化保留上述职责边界，将逐文件 check-ignore 改为 Git 原生 ls-files --others --ignored --directory 提前提供可剪枝的忽略路径，再由磁盘枚举实际文件。不是重新使用 Git 跟踪／改动路径作为 Files 的来源。
