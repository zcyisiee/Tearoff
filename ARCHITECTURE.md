# 当前架构

## 文档范围与核对时间

描述 `v5-tauri` 分支上的 Tauri 版本（5.0.0-alpha.1），2026-11-15 对照源码与实测核对。冻结的 Swift 版本在 `legacy/swift/`，其说明见 `legacy/swift/CONTRIBUTING.md`，本文不覆盖。

## 系统目的与范围

屏幕边缘的一块面板：鼠标碰到屏幕边缘（或按全局快捷键）滑出，离开后收起。里面是今天的一张纸、少量固定的卡片（笔记或磁盘文件夹）、其余笔记的紧凑列表。笔记是用户指定文件夹里的 `.md` 文件。目标平台 macOS 与 Windows，一套代码。

## 对外入口

- 托盘图标（左键切换面板，菜单：显示 / 退出）。
- 全局快捷键（默认 `CmdOrCtrl+Shift+Space`，可改可清空）。
- 屏幕边缘悬停（可关）。
- 环境变量（仅开发）：`TEAROFF_VAULT`、`TEAROFF_CONFIG_DIR`、`TEAROFF_SHOW`、`TEAROFF_SELFTEST`，含义见开发指南。

## 模块职责与代码地图

```text
┌──────────────────── WebView（React + Tiptap）────────────────────┐
│ App ─ TopBar / Home / SettingsView                               │
│   Home ─ Sheet(today) · Sheet(card)… · FolderCardView… · 行列表   │
│   Sheet ─ NoteEditor ─ RichEditor(Tiptap) | SourceEditor         │
│            └ NoteSaver（防抖写盘、冲突处理）                       │
│ lib/api ── tauriApi（invoke/事件）│ mockApi（浏览器与测试）        │
└───────────────────────────┬──────────────────────────────────────┘
                            │ IPC：命令 + 事件（contracts.md）
┌───────────────────────────┴──── Rust（src-tauri）────────────────┐
│ lib.rs   命令、AppState、文件监听(notify)、托盘、全局快捷键        │
│ vault.rs 笔记读写、v5.json、搜索、图片      legacy.rs 只读导入    │
│ finder.rs 列目录/移动/重命名/废纸篓         settings.rs           │
│ panel.rs 轮询光标 → 显示/隐藏/定位窗口                            │
└──────────────────────────────────────────────────────────────────┘
```

前端组件只通过 `src/lib/api.ts` 访问后端；`Api` 接口（`src/lib/types.ts`）是两端共同遵守的契约，mock 实现同一个接口。

## 关键执行路径与数据流

**打字到落盘。** Tiptap `onUpdate` → 序列化为 Markdown → 与“加载时的序列化基线”比较，相同则不保存 → `NoteSaver.schedule`（450ms 防抖，失焦/面板收起立即 flush）→ `write_note(path, content, baseModified)` → Rust 比较磁盘 mtime，不一致返回 `conflict` → 一致则写临时文件再 rename。

**外部修改。** notify 监听库目录 → 250ms 聚合 → `vault-changed` 事件 → 前端 `get_state` → 某笔记 mtime 与保存器记录的不同且没有未保存输入 → 重新读盘并重建编辑器。有未保存输入时走冲突路径：磁盘版本保留在原文件，用户版本另存为“冲突副本”。

**富文本还是原文。** 加载时把正文在无界面的编辑器里往返一次，比较“内容骨架”（去掉空白与纯语法字符后的字符序列）。一致 → 富文本；不一致（行内 HTML、脚注等）→ 同样字体的纯文本编辑框。YAML front matter 在进入编辑器前剥离、保存时原样接回。

**展开与收起。** `Sheet` 元素本身被设为 `position: fixed` 并用 Web Animations 从原位置插值到面板大小，原位置留一个等高占位。没有第二个编辑器实例，也没有第二套样式。

**面板显示与隐藏。** `panel.rs` 的一个线程每 40ms 读真实光标位置：未显示时判断是否贴边够久；已显示时判断是否离开面板矩形够久。固定、忙（菜单/对话框/拖拽）、鼠标键按下、光标尚未进入过面板时不收起。隐藏先发 `panel-hidden` 让界面滑出，210ms 后隐藏窗口；期间若再次显示，凭代数计数取消这次隐藏。

**文件拖拽。** 文件夹卡片里按下并移动 5px → `tauri-plugin-drag` 发起系统级拖拽（期间面板置忙）。落点统一由 WebView 的 drag-drop 事件给出坐标，`elementFromPoint` 找带 `data-drop-dir` 的元素决定目标目录。卡片本身不保存任何“正在拖拽”的状态。

## 数据与存储责任

| 数据 | 位置 | 所有者 |
|---|---|---|
| 笔记正文 | `<库>/**/*.md` | 用户；应用只在用户编辑后写 |
| 今天的纸 | `<库>/Daily/YYYY-MM-DD.md` | 首次输入内容时才创建 |
| 粘贴的图片 | 笔记所在目录的 `assets/` | 应用创建，不清理 |
| 固定、顺序、创建时间、文件夹卡片 | `<库>/.tearoff/v5.json` | 本版本独占 |
| 旧版元数据 | `<库>/.tearoff/meta.json` | 旧 Swift 版；本版本只读一次 |
| 设置 | 系统应用配置目录下 `settings.json` | 本版本 |

## 不可破坏的边界与检查出口

| 约束 | 实现位置 | 验证方式 |
|---|---|---|
| 受支持的 Markdown 往返后逐字节相同 | `src/editor/extensions.ts` | `src/editor/markdown.test.ts`「round trip keeps…」 |
| 会丢内容的笔记不进富文本 | `src/editor/markdown.ts` `isLossless` | 同上「lossless guard」 |
| `$5 和 $10` 不被当成公式 | `PandocInlineMath` | 同上「math is not confused with prices」 |
| 打开笔记不写盘 | `NoteEditor.tsx` 基线比较 | 应用内自检「today sheet types…」检查原有文本未变；浏览器手测打开含表格的笔记顺序不变 |
| 磁盘被外部改过时拒写 | `vault.rs` `write_note` | `tests/vault.rs` `write_refuses_when_file_changed_underneath` |
| 笔记路径不能逃出库 | `vault.rs` `resolve` | `paths_cannot_escape_the_vault` |
| 不写旧版 `meta.json` | `legacy.rs` 只读 | `legacy_meta_is_imported_once_and_left_untouched` |
| 移动文件不覆盖、不自我嵌套 | `finder.rs` `move_into` | `finder_moves_refuse_clashes_and_self_nesting` |
| 卡片与今天的纸排版一致 | 共用 `NoteEditor` + `prose.css` | 应用内自检「pinned note renders as a card with the same editor」 |
| IPC 参数与返回两端一致 | `tauriApi.ts` / `lib.rs` | 应用内自检全部项 |

## 已知限制与未完成能力

见 [docs/design/v5-product.md](docs/design/v5-product.md) 的“尚未实现 / 尚未验证”。最重要的三条：Windows 从未构建和运行过；边缘悬停唤出与自动收起只通过了编译和代码审阅，没有实测；面板无法显示在全屏应用之上尚未确认。
