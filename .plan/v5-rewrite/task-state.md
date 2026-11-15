# 任务状态：v5 重写

更新：2026-11-15 · 状态：进行中（第二轮试用反馈已处理，等待用户再试）· 分支 `v5-tauri` · 目录 `/Users/zhengcaiyi/Developer/Tearoff`

## 用户意图与偏好

- 用户把项目开发交给主 Agent，可以不背历史包袱、允许从头重写（2026-11-15）。
- 五点要求：① 按 harness engineering 模板管理项目；② 产品改造——主页不要杂、不手打 Markdown 标记（快捷键/工具栏，底层仍是 md）、卡片展开前后风格完全一致且动画流畅；③ 深入分析“快速拖文件致文件夹卡片白屏”的原因；④ 可重构 UI 与后端；⑤ 兼容 Windows 和 Mac。
- 用户已选定：统一 Tauri 2 重写；主页“今天优先 + 紧凑历史”；文件夹卡片保留在主页。
- 用户用中文交流。
- 第二轮反馈（2026-11-15）：界面里不许有说明性文字（“交互逻辑应该内蕴于产品中”）；卡片用圆角矩形、岛屿式设计（参照新版 VS Code）；开发阶段要有日志；要求把旧版数据同步进新版。

## 专项知识与边界

- 旧库 `~/Documents/EdgeMark`，旧版 Tearoff 常驻运行——都不许改。测试用 `/tmp` 下的一次性目录。
- 新版装在 `/Applications/Tearoff 5.app`，库是 `~/Documents/Tearoff`——**现在里面是用户的真实数据副本**（2026-11-15 从旧库复制，旧库未动；同步前的新库备份在 `/tmp/tearoff-sync-backup-123326`）。重装新版用 `ditto`，先只结束路径含 `Tearoff 5.app` 的进程。
- 用户的 Chrome 是日常浏览器，只开后台标签、用完关。
- `~/pnpm-workspace.yaml` 的坑见 `AGENTS.md`。本任务初期误把依赖装进了 home 工作区：已从 `~/pnpm-lock.yaml` 移除本项目的 importer 段（备份在 `/tmp/home-pnpm-lock.backup.yaml`），但 `~/node_modules/.pnpm` 里残留了无主的包，锁文件 `packages:` 段里也残留了条目——**待用户决定是否在 home 跑一次 `pnpm install` 清理**。

## 进度与验收

| 项 | 状态 | 证据 |
|---|---|---|
| ③ 白屏 bug 根因 | 已证实 | `docs/issues/finder-card-blank.md` |
| ③ 4.x 补丁 | 已实现，已编译，未 GUI 复测 | 提交 `5586b3f` |
| ① harness 文档体系 | 已建立 | `AGENTS.md`、`ARCHITECTURE.md`、`docs/` |
| ④⑤ Tauri 工程 | macOS 可运行、可打包 | 调试包自检 13/13 |
| ② 今天优先主页 | 已实现，浏览器与原生窗口截图核对 | — |
| ② 格式栏/浮条/斜杠菜单/快捷键 | 已实现；格式栏、待办切换实测，其余按钮未逐个点 | — |
| ② 同一元素展开动画 | 已实现，实测同一 DOM 节点、排版一致 | — |
| Markdown 保真 | 已实现 | vitest 20 项 |
| 笔记库/文件操作 | 已实现 | cargo test 10 项 |
| 边缘唤出/自动收起/快捷键/托盘 | 已实现，**未实测** | — |
| ⑤ Windows | **未构建未运行** | — |
| 去掉说明性文字、岛屿式圆角布局 | 已实现，浏览器明暗两态截图核对；展开前后盒子与正文位置逐像素相同 | — |
| 日志 | 已实现，安装版已在写 | `contracts.md`“日志” |
| “点加号卡住” | 根因证实并修复；选择框待用户点一次 | `docs/issues/folder-card-freeze.md` |
| 旧数据同步 | 已完成：20 篇笔记、1 张文件夹卡片（3 个收藏夹） | 启动日志 `notes=20 folder_cards=1` |

## 当前问题与下一步

1. 等用户再试安装版：岛屿式外观是否对味、添加文件夹是否还卡、旧数据是否齐全；边缘唤出/收起的手感；被砍掉的功能（标签、颜色、文件夹页签、回收站、大纲）是否接受。
2. 用户复测 4.x 白屏补丁（方法见问题文档）。
3. 之后按 `docs/design/v5-product.md` 的“尚未实现”排序推进：卡片拖拽排序 → Windows 构建与 CI → 文件夹卡片细节。
4. 分支未推送、未合并；README 仍是 4.x 的内容，只加了一段说明。

## 计划与证据

- 产品决定与未完成清单：`docs/design/v5-product.md`
- 契约：`docs/reference/contracts.md`
- 自检脚本：`src/selftest.ts`；fixture：`/tmp/tearoff-v5/`（可再生成）
