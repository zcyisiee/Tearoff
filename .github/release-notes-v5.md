Tearoff 5 是用 Tauri 重写的版本，macOS 和 Windows 共用一套代码。这是预览版，用独立的笔记库和设置，不读写 4.x 的数据。

## 下载

| 系统 | 文件 |
|---|---|
| macOS（Apple 芯片） | `Tearoff-…-macos-arm64.dmg` |
| macOS（Intel） | `Tearoff-…-macos-x64.dmg` |
| Windows 10 / 11（64 位） | `Tearoff-…-windows-x64-setup.exe` |

安装包没有开发者签名：

- **macOS**：把 Tearoff 拖进“应用程序”后，在终端执行 `xattr -cr /Applications/Tearoff.app`，再打开。
  如果已经装了 4.x：两个版本的应用同名，直接拖入会替换 4.x。想两个都留，先把 4.x 改名（例如 `Tearoff 4.app`）。
- **Windows**：SmartScreen 拦截时点“更多信息 → 仍要运行”。

## 有什么不同

- 主页先是今天的纸，打开就能写；固定的笔记是卡片，其余笔记一行一条。
- 不用手打 Markdown 标记：格式栏、选中浮条、`/` 菜单、快捷键（⌘/Ctrl+T 待办、⌘/Ctrl+B 加粗……）。文件仍是普通的 `.md`。
- 卡片就是编辑器，展开只是同一张纸变大。
- 文件夹卡片保留。
- 删除进系统废纸篓 / 回收站。

## 已知情况

- Windows 版通过了自动编译和单元测试，尚未在真机上完整试用。
- 默认笔记库是 `文稿/Tearoff`（Windows：`文档\Tearoff`），可在设置里更换。不会改动 4.x 的笔记库。
- 4.x 里的标签、卡片颜色、大纲、应用内回收站在这一版没有。
