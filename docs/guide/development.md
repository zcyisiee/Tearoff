# 开发指南

## 准备

- Node 24+、pnpm 11+、Rust stable（1.93 验证过）、Xcode 命令行工具（macOS）或 WebView2 + MSVC（Windows，未验证）。
- `pnpm install`。仓库根的 `pnpm-workspace.yaml` 让本项目自成工作区，勿删。

## 运行

| 目的 | 命令 |
|---|---|
| 只看界面（内存假数据，浏览器 http://localhost:1420） | `pnpm dev` |
| 真实应用，一次性笔记库 | `TEAROFF_VAULT=/tmp/t/vault TEAROFF_CONFIG_DIR=/tmp/t/config pnpm app:dev` |
| 启动即显示并固定面板（不抢焦点） | 再加 `TEAROFF_SHOW=1` |
| 打包 | `pnpm app:build`（调试包：`pnpm tauri build --debug --bundles app`） |

`TEAROFF_CONFIG_DIR` 下的 `settings.json` 可预置设置。测试时建议 `"edgeActivation": false, "toggleShortcut": ""`，避免和正在运行的旧版 Tearoff 抢屏幕边缘与快捷键。

**不要**把开发版指向真实笔记库 `~/Documents/EdgeMark`，除非用户明确要求。

## 验证

```bash
pnpm typecheck
pnpm test                       # Markdown 往返与守卫（vitest）
(cd src-tauri && cargo test)    # 笔记库、旧版导入、文件操作
```

**应用内自检**（界面或 IPC 有改动时必跑）：在真实应用里走一遍全部命令、文件监听事件、打字落盘、卡片渲染。

```bash
mkdir -p /tmp/t/vault /tmp/t/config /tmp/t/files/archives
echo a > /tmp/t/files/archives/alpha.txt; echo b > /tmp/t/files/archives/beta.txt
echo '{"edgeActivation":false,"toggleShortcut":""}' > /tmp/t/config/settings.json
pnpm dev &   # 调试构建从 devUrl 加载界面
(cd src-tauri && TEAROFF_VAULT=/tmp/t/vault TEAROFF_CONFIG_DIR=/tmp/t/config \
  TEAROFF_SELFTEST=/tmp/t/report.json cargo run)
# 约 10 秒后 /tmp/t/report.json 出现：{"failed":0,"passed":13,...}
```

自检需要库目录的同级有 `files/archives/{alpha,beta}.txt`（文件夹卡片用）。它会在库里留下“自检…”笔记，所以只对一次性库运行。脚本在 `src/selftest.ts`。

**看界面。** 浏览器：`pnpm dev` 后用 Chrome DevTools MCP 截图（视口用 `emulate`，约 470×900）。原生窗口：`TEAROFF_SHOW=1` 启动后 `screencapture -x -o -l <窗口号>`，窗口号可用 CoreGraphics 的窗口列表按 pid 查。

## 排查

- 先看日志：`~/Library/Logs/io.github.zcyisiee.Tearoff5/tearoff.log`（开发运行与安装版写同一个文件）。找 `WARN`/`ERROR`：命令慢、命令失败、界面线程停顿都在里面。

- 原生窗口一片空白：先看自检的「panel layout」项——它报告面板元素的位置。常见原因是 CSP 拦了脚本（开发用 `devCsp`）或面板还停在滑出位置。
- 监听事件不来：检查路径是否经过符号链接（`/tmp` → `/private/tmp`），比较前要规范化。
- macOS 多显示器定位错：只用 `panel.rs` 里的逻辑坐标路径，不要用 tao 的物理坐标。

## 交付

- 在 `v5-tauri` 分支提交；提交信息沿用仓库的 `类型: 中文说明` 风格。
- 完成前更新任务状态文件；行为变了更新 `contracts.md`；有可复用结论写进 `docs/lessons/`。
- 旧版发布流程（`.github/workflows/build.yml`）仍指向仓库根的 Xcode 工程路径，工程已移到 `legacy/swift/`，**再发旧版前需要先改路径**（未改、未验证）。
