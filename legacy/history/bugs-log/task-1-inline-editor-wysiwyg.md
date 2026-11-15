# Task: 卡片临时编辑模式强制 WYSIWYG 预览样式 + 右上角常驻临时编辑开关图标

## Objective

Tearoff 主界面文件卡片（BoardNoteCard）的"临时编辑模式"（in-place editor，即 `inlineEditor`）目前读取全局 `AppSettings.shared.editorRawSourceMode`，导致：
1. 若上次在编辑器模式（ExpandedNoteEditor）中切换到了代码（raw source）界面，回到主界面进入某卡片的临时编辑模式时也是代码界面，且用户在临时编辑界面无法切回预览 —— 样式严重偏移（任务项圆形变方形、缩进偏移、颜色变化）。
2. 临时编辑模式应**始终使用 WYSIWYG 渲染**（rawSourceMode = false），与卡片默认预览样式保持一致；对用户而言，进入临时编辑模式仅仅是预览框变长、内容可编辑。
3. 进入临时编辑模式后，卡片右上角（pin 图标所在位置）应显示一个与编辑器模式 header 风格一致的常驻 icon，用于退出临时编辑模式。

## Context

- 仓库：Tearoff（macOS SwiftUI 应用），当前分支 `main`。
- `Tearoff/UI/Board/BoardNoteCard.swift` —— 卡片视图。`cardFace` 组合 title 行 / preview 或 `inlineEditor` / meta 行；`inlineEditor` 属性（约 380 行附近）构造 `MarkdownEditorView`；`pinChrome`（overlay topTrailing）目前仅在 pin 或 hover 时显示；`titleEditToggleArea` 是标题行右侧空白区，单击切换临时编辑。
- `Tearoff/Core/Editor/MarkdownEditorView.swift` —— SwiftUI 包装器。`body` 中 `let isRawSource = appSettings.editorRawSourceMode` 直接决定 `config.rawSourceMode` 和 init 中 heading 拆分逻辑。init 参数 `showsHeadingLineInBody`、`focusTitleOnAppear`、`useBoardTypography` 已存在。
- `Tearoff/Core/Editor/EditorConfigFactory.swift` —— `makeTearoffConfig(noteFolder:bus:rawSourceMode:accentColor:useBoardTypography:)`，已接受 rawSourceMode 参数。
- `Tearoff/Core/Settings/AppSettings.swift` —— `editorRawSourceMode: Bool`（全局持久化，UserDefaults key "editorRawSourceMode"）。**不能改它的值**——编辑器模式（ExpandedNoteEditor 的 RawSourceToggleButton）仍读写它。
- `Tearoff/UI/Board/ExpandedNoteEditor.swift` —— 编辑器模式 header 的 icon 按钮风格参考：`HeaderIconButton`、`iconHoverChrome(isHovered:isActive:)`（28x28、圆角 hover 背景、`DesignToken.Radius.sm`）。
- `Tearoff/Core/Storage/NoteStore.swift` —— `beginInlineEdit(_:)` / `endInlineEdit()`（带动画并 flush 保存）、`inlineEditingNoteID`。
- 本地化：`L10n.shared["..."]` / `l10n["..."]`。如需新 key，查清 L10n 实现位置并中英文都补上。

## Deliverables

1. **`MarkdownEditorView` 新增 `forceWYSIWYG: Bool = false` 参数**：
   - 为 true 时：渲染配置恒为 `rawSourceMode: false`（不受 `AppSettings.shared.editorRawSourceMode` 影响）；
   - init 中 heading 拆分走非 raw 分支；`.onChange(of: isRawSource)` 的 raw 切换重组逻辑在 forceWYSIWYG 下不得触发（raw 值变化应被忽略，视图 id 也不应因 rawSourceMode 变化而重建——目前 `.id(appSettings.taskCheckboxPreset)`，注意别把 editorRawSourceMode 加进 id）；
   - 其他 `.onChange(of:)`（noteTitle、pendingReload）中按 rawSourceMode 分支的逻辑同样在 forceWYSIWYG 下恒走 WYSIWYG 分支。
2. **`BoardNoteCard.inlineEditor` 传 `forceWYSIWYG: true`**。
3. **卡片右上角临时编辑开关 icon**：
   - 当 `isEditing == true` 时，在 pin chrome 位置显示一个常驻按钮（复用 pinChrome 的布局位置：overlay topTrailing，padding 一致），点击调用与 `titleEditToggleArea` 相同的退出路径（新增 `onEditToggle: (() -> Void)?` 回调，由 NoteBoardView 接到 `noteStore.endInlineEdit()`，或直接复用现有 `onTitleAreaTap` 传空 flags——由你判断哪个更干净，保持单一事实来源）；
   - 图标建议 `pencil` 或 `square.and.pencil`（活跃态可用 accent 着色，与编辑器模式 icon 语言一致）；与 pin 按钮共存时排成一排（pin 在更右上角或并排，参照现有 `.padding(2)` + 9-10pt 字号的风格）；
   - 样式与编辑器模式 header icon 一致：hover 出现 `DesignToken.ink.opacity(DesignToken.Alpha.hover)` 圆角背景；
   - `.help(...)` tooltip 使用 L10n 本地化 key（查现有 key，如没有合适的则新增，中英文都补）。
4. **BoardDragReplica** 构造的 `BoardNoteCard` 按需补传新回调（replica `isEditing: false`，icon 不会出现，但编译要过）。

## Constraints

- 不改 `AppSettings.editorRawSourceMode` 的读写语义；编辑器模式（ExpandedNoteEditor）行为完全不变。
- 不改卡片非编辑态的 preview 渲染。
- 不动 Packages/swift-markdown-engine。
- 提交信息用中文或英文均可，遵循仓库现有 commit 风格（先 `git log --oneline -8` 看一眼）。

## Validation

```bash
cd <repo>
xcodebuild -project Tearoff.xcodeproj -scheme Tearoff -configuration Debug build
```
必须编译通过（允许既有 warning，不允许 error）。
如仓库有更轻量的构建方式（build_local 目录/脚本），先查看后使用。

## Report back

- 修改的文件与关键 diff 摘要
- 构建验证结果（命令 + 结果）
- 设计取舍说明（icon 选择、回调接线方式、forceWYSIWYG 在各 onChange 分支的处理）
- 遗留风险

---

## Addendum（执行中经 supervisor 决策追加的交付物）

代码核实发现 raw 模式下任务标记仅为纯文本（引擎 styler early-return），截图中的「方形 checkbox」实为 WYSIWYG + 全局 `taskCheckboxPreset`（默认 `.square`）；且 `makeTearoffConfig` 的 `textInsets(horizontal: 16)` 使临时编辑正文较预览右移约 16pt。经决策追加：

5. **`makeTearoffConfig` 新增 `matchCardPreview: Bool = false` 参数**：为 true 时 (a) `textInsets` 收紧为 `TextInsets(horizontal: 0, vertical: 4)`（引擎已置 `lineFragmentPadding = 0`，水平 0 即与预览左缘严格对齐；垂直 4 匹配预览紧凑节奏）；(b) `taskCheckbox` 强制使用 `.circle` preset 的符号（不读全局 preset）。
6. **`MarkdownEditorView` 透传 `matchCardPreview`**，`BoardNoteCard.inlineEditor` 传 `true`；`ExpandedNoteEditor` / `ReadOnlyMarkdownView` 保持现状（默认 false，仍读全局 preset 与标准 insets）。
7. `.id(appSettings.taskCheckboxPreset)` 重建逻辑保持不变（对 matchCardPreview 路径无实际影响）。
