# Task: 新建卡片命名交互 —— 聚焦卡片标题、直接输入标题、回车进入正文

## Objective

当前新建卡片后，正文区域（临时编辑模式的 MarkdownEditorView）显示 `# 无标题` 大标题并选中"无标题"，但**卡片顶部标题行仍显示"无标题"且不更新**，用户输入的标题只进了正文 heading，体验割裂。

期望交互：
1. 新建卡片后，卡片顶部标题行变为一个聚焦的输入框（InlineRenameEditor），"无标题"被全选，用户直接输入标题；
2. 正文（临时编辑模式编辑器）**不显示 heading 行**（与既有卡片一致，不再是 `# 无标题` 大标题）；
3. 用户按**回车**：提交标题，光标自动移动到正文编辑器（继续写内容），卡片保持临时编辑模式；
4. 用户按 **Escape**：取消命名（标题保留为"无标题"，正文 heading 不变）；
5. 输入框失焦（点击别处）：若输入非空则提交标题；若为空则恢复原标题；
6. 与重命名冲突检测一致：若标题与同目录既有笔记重名，显示冲突提示并阻止提交。

## Context

- 仓库：Tearoff（macOS SwiftUI 应用），当前分支 `main`。**依赖 Task 1（bugs-log/task-1-inline-editor-wysiwyg.md）已合入**：临时编辑模式已 `forceWYSIWYG: true`。
- `Tearoff/UI/Board/NoteBoardView.swift` —— `createNote()`（约 1620 行）：`noteStore.createNote(in:)` → `newlyCreatedNoteID = note.id` → `noteStore.beginInlineEdit(note)` → `scrollToNoteID`。`newlyCreatedNoteID` 在 `onChange(of: noteStore.inlineEditingNoteID)`（约 294 行）中：切换到另一张卡编辑或退出编辑时清除。`noteRename` / `NoteRenameCoordinator`（`Tearoff/UI/Components/NoteRenameCoordinator.swift`）管理看板重命名卡片 `boardRenameCard(for:)`；`startRenamingNote(_:)` 已存在。
- `Tearoff/UI/Board/BoardNoteCard.swift` —— `isNewlyCreated: Bool` 目前驱动 `MarkdownEditorView(showsHeadingLineInBody: isNewlyCreated, focusTitleOnAppear: isNewlyCreated)`。`titleView` 是普通 Text。`onToggleTask`/`onContentChanged` 等回调已接好。
- `Tearoff/UI/Components/InlineRenameEditor.swift` —— 看板重命名用的输入框（冲突提示、聚焦、提交/取消语义）。读它，尽量复用。
- `Tearoff/UI/Board/ExpandedNoteEditor.swift` —— 编辑器模式的标题重命名交互（`isRenamingTitle` / `titleDraft` / `commitRename` / `cancelRename` / `commitOrCancelRename` / `isConflicting`），语义参考。
- `Tearoff/Core/Storage/NoteStore.swift` —— `renameNote(_:to:)`（更新 notes[].title、文件名、**同步正文 `# heading` 行**——请核实）；`updateContent(for:content:)`；`noteTitleExists(_:in:excluding:)`。
- `Tearoff/Core/Editor/MarkdownEditorView.swift` —— `focusTitleOnAppear` 现有实现 `focusAndSelectTitle()`（找 keyWindow 的 NSTextView 并选中首个 heading 的标题部分）。可扩展一个"聚焦正文开头/末尾"的 focus 请求参数，供提交标题后调用。
- 本地化：`L10n.shared["common.untitled"]`、`common.nameTaken` 等 key 已存在。

## Deliverables

1. **BoardNoteCard**：新增"新建命名态"标题输入框：
   - 当 `isNewlyCreated == true`（或新增更明确的 `isNamingNewCard`）时，`titleView` 位置渲染 InlineRenameEditor（复用现有组件，含冲突提示样式），初始值为当前标题（"无标题"或"无标题 2"），全选；
   - 提交 → 调 `noteStore.renameNote`（经 NoteBoardView 回调），成功后请求正文编辑器聚焦（见 3），命名态结束；
   - 取消（Escape）→ 不 rename，命名态结束（卡片保持临时编辑模式）；
   - 失焦 → commitOrCancel 语义（非空提交、为空恢复）。
2. **正文不再显示 heading**：`BoardNoteCard.inlineEditor` 不再传 `showsHeadingLineInBody: isNewlyCreated` / `focusTitleOnAppear: isNewlyCreated`（新建卡片与其他卡片一致：heading 拆出隐藏，只显示正文）。
3. **回车进入正文**：命名输入框 onSubmit 后，焦点切换到该卡片的 MarkdownEditorView 正文。实现建议：给 `MarkdownEditorView` 增加一个 focus 请求机制（例如 `focusBodyRequest: Binding<Int>` 或 closure 回调），NoteBoardView 在 rename 提交后触发；`MarkdownEditorView` 内用现有 `findEditorTextView(in:)` + `makeFirstResponder` + 将光标放到正文末尾。选最简单可靠的方案并说明。
4. **NoteBoardView 接线**：`createNote()` 流程保持（建卡→命名态→临时编辑），`newlyCreatedNoteID` 的清除时机扩展为"命名态结束"（提交/取消/失焦/切卡），而非仅依赖 inlineEditingNoteID 变化。注意 `boardRenameCard(for:)` 的既有重命名流程不受影响。
5. **命名态视觉**：输入框样式与 `boardRenameCard` 一致（选中态描边 accent、冲突红色提示）。

## Constraints

- 不影响既有卡片的单击标题选中 / 双击重命名交互（`onTitleTap` / `handleTitleTap` / `startRenamingNote`）。
- 不影响 Daily Note 流程（`focusTodayDaily` 不设 newlyCreatedNoteID，已核实——保持如此）。
- 不动 Packages/swift-markdown-engine。
- 遵循 AGENTS.md；仓库现实优先于本简报的假设，最小适配、不扩大范围，重大偏离要报告。

## Validation

```bash
cd <repo>
xcodebuild -project Tearoff.xcodeproj -scheme Tearoff -configuration Debug build
```
必须编译通过（允许既有 warning，不允许 error）。
手动验证点（在报告中逐项说明你是如何核实的，能跑则跑）：
- 新建卡片 → 标题输入框聚焦全选，正文无 `# 无标题` 大标题；
- 输入"测试"回车 → 卡片标题变为"测试"，文件名同步，正文获得焦点可继续输入；
- 输入空/取消 → 标题恢复"无标题"；
- 输入与既有笔记重名 → 冲突提示，阻止提交。

## Report back

- 修改的文件与关键 diff 摘要
- 构建验证结果
- 焦点切换的实现方式与取舍
- 手动验证点核实情况
- 遗留风险
