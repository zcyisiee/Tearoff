# Agent 入口

## 开发原则

- Tearoff 是“撕张纸就能记”的边缘面板笔记。任何改动先问：它让“想到 → 写下”更快了吗？不能就不加。
- Markdown 文件是唯一的事实来源。编辑器只是它的一个视图：**打开不改写，无损才富文本，删除只进系统废纸篓**。
- 一种内容只有一个渲染实现。卡片、今天的纸、展开的编辑器是同一个组件、同一份 `.prose` 样式。
- 状态由可观测事实推导（真实光标位置、磁盘 mtime），不依赖“事件一定成对到达”。旧版白屏 bug 就是反例，见 [docs/issues/finder-card-blank.md](docs/issues/finder-card-blank.md)。
- 修 bug 先找根因和类别，再补回归测试；不靠延时、重试、强制重绘掩盖症状。

## 任务状态（开始与恢复时必读）

当前任务：[.plan/v5-rewrite/task-state.md](.plan/v5-rewrite/task-state.md)

开始、压缩后恢复、接管、委派前先读它，再核对实际工作区（`git status`、分支、进程）。每个任务只有这一份状态文件，只有用户和主 Agent 可改。

## 文档导航

| 要回答的问题 | 文档 | 什么时候读 |
|---|---|---|
| 系统怎样组成、数据怎样流动 | [ARCHITECTURE.md](ARCHITECTURE.md) | 非小改动前 |
| 怎样安装、运行、验证、交付 | [docs/guide/development.md](docs/guide/development.md) | 首次运行与完成前 |
| 前后端命令、存储格式、失败语义 | [docs/reference/contracts.md](docs/reference/contracts.md) | 改对应行为前 |
| 产品决定与尚未实现的部分 | [docs/design/v5-product.md](docs/design/v5-product.md) | 讨论功能取舍时 |
| 已核实的重要缺陷 | [docs/issues/index.md](docs/issues/index.md) | 诊断与评估风险时 |
| 可复用的经验 | [docs/lessons/index.md](docs/lessons/index.md) | 选方案与收尾时 |
| 怎样委派给外部 harness | [docs/guide/delegation.md](docs/guide/delegation.md) | 有委派时 |
| 文档怎样维护 | [docs/index.md](docs/index.md) | 写文档前 |

## 代码地图

| 位置 | 内容 |
|---|---|
| `src/editor/` | 唯一的编辑器：schema、Markdown 往返守卫、保存器、格式栏、斜杠菜单 |
| `src/components/` | 纸张（`Sheet`，含展开动画）、主页、文件夹卡片、设置 |
| `src/lib/` | 后端契约类型、Tauri 绑定、内存 mock、状态 |
| `src/selftest.ts` | 在真实应用里跑的端到端自检 |
| `src-tauri/src/vault.rs` | 笔记库：读写、sidecar、搜索 |
| `src-tauri/src/finder.rs` | 文件夹卡片的文件操作 |
| `src-tauri/src/panel.rs` | 边缘唤出、自动收起、窗口定位 |
| `src-tauri/src/lib.rs` | 命令注册、文件监听、托盘、快捷键 |
| `legacy/swift/` | 冻结的 Swift 4.x 版本（仍可用 Xcode 构建），只修严重 bug |

## 必守边界与验收

- **不碰用户的真实笔记库和正在运行的旧版 Tearoff。** 运行、自检一律用 `TEAROFF_VAULT` / `TEAROFF_CONFIG_DIR` 指到 `/tmp` 下的一次性目录。真实库在 `~/Documents/EdgeMark`。
- 不写旧版的 `.tearoff/meta.json`；新版只写 `.tearoff/v5.json`。
- 完成的定义：`pnpm typecheck && pnpm test && (cd src-tauri && cargo test)` 全过，涉及界面或 IPC 的改动再跑一次应用内自检（见开发指南）。跳过的项要写明原因，不能算通过。
- worker 的成功报告不是验收；主 Agent 看完整 diff 并独立验证。

## 环境与共享资源

- 用户 home 下有 `~/pnpm-workspace.yaml`。本仓库靠根目录的 `pnpm-workspace.yaml` 自成工作区，**不要删**，否则 `pnpm install` 会写进 `~/pnpm-lock.yaml`。
- Chrome DevTools MCP 连的是用户日常使用的浏览器：只开后台标签页、用完关闭、不要调用 `resize_page`（用 `emulate` 设视口）。
- 日志、截图、fixture 放 `/tmp` 或仓库忽略的 `tmp/`，不进 Git。
