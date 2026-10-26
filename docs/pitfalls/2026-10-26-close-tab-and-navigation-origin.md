# 关闭标签与返回跳转起点

## 问题

用户要求 ⌘W 优先按照跳转历史返回，代理将其解释为“最近访问且仍打开的标签”。用户纠正为“跳过来的哪个位置”，并要求核对 VS Code 行为。两者不能混用。

## 纠正后的预期

用户关注的是本次跳转的来源位置，包括来源文件、光标和阅读视口；仅激活一个最近访问标签不足以表达这个要求。不能未经核实宣称 VS Code 的关闭标签就是返回跳转起点。

## 已核实的原因

本项目 ReaderSession 目前关闭活跃标签后按标签排列选择右侧、再左侧，并不查询阅读历史。代理在尚未区分标签选择和位置恢复时，过早提出了 MRU 方案。

2026-10-26 核对 VS Code 官方 main 分支源码：focusRecentEditorAfterClose 默认为 true；editorGroupModel 关闭活跃标签后选择当前组 mru[1]。TextFileEditor 另行加载并恢复文件视图状态。HistoryService 的跳转历史则记录来源与目标选区，服务于导航操作；不能将其概括为关闭标签时直接弹出跳转历史。

## 修正措施与验证边界

先说明查到的默认行为与用户要求的区别。后续实现若按用户要求返回来源，应明确保存具体来源位置，并与普通标签切换、文件自己的最后阅读位置区分。

本次仅检查本项目和 VS Code 源码、记录纠正，尚未修改产品或测试代码，也未进行 VS Code 实窗验证。上述 VS Code 结论属于源码核对，不冒充实窗测试结果。

## 防止再犯的检查点

- 区分标签排列顺序、最近激活顺序、文件保存的视图状态和跳转来源。
- 用 A → B → C、同文件内跳转、跳转后手动切换其他标签等情形说明语义，不能仅用一次 A → B 的结果判断。
- 报告参考应用行为时给出官方源码依据；用户要求与参考应用不同时，保留用户明确表达的预期。

## 参考源码

- https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/editor.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/workbench/common/editor/editorGroupModel.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/editors/textFileEditor.ts
- https://github.com/microsoft/vscode/blob/main/src/vs/workbench/services/history/browser/historyService.ts

## 用户最终选择：沿用 VS Code 默认逻辑

用户核对说明后明确要求“参考 vscode 逻辑来做”。本次实现采用当前分栏内的最近激活顺序，独立于标签排列；关闭时移除相应记录并选择仍打开的最近项，复用原有文件视图状态恢复，不调用导航后退。目录重命名同步更新记录，重置清空，旧会话恢复以活动标签和已恢复标签初始化顺序，不额外持久化此前未保存的激活顺序。

补充模型测试覆盖标签重排、批量关闭、版本及草稿身份、重命名与重置；集成回归覆盖 ⌘W 路径的选区和纵横位置恢复及分栏隔离。新增 UI 需求区分关闭和后退。这是实现记录，实际测试结果另记，不提前宣称验证通过。
