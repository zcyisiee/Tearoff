# bugs-log

主分支三个用户逻辑 bug 的调查与修复记录（2026-09-05 起整理）。

| # | 问题 | 状态 | 记录 |
|---|------|------|------|
| 1 | 已有卡片无法删除（右键标题右侧空白区域应弹出含"删除卡片"的菜单） | ✅ 已修复并 GUI 验证 | [bug1-右键删除卡片菜单.md](bug1-右键删除卡片菜单.md) |
| 2 | 从文件夹卡片拖文件到 Finder 后，卡片永久空白（"卡死"） | ✅ 修复已实现（构建通过），待人工验证 | [bug2-拖出文件后文件夹卡片空白.md](bug2-拖出文件后文件夹卡片空白.md) |
| 3 | 添加 debug 模式：用户开启后自动记录日志 | ✅ 已实现（FileLog 独立单测通过，构建通过） | 见下文「debug 模式实现记录」 |

## 环境与工具（bug2 调查所用）

- **沙盒复现实例**：`Tearoff.app --show-panel --storage-root /tmp/tearoff-fixture-vault`
  - fixture：`/tmp/tearoff-fixture/clash-for-linux-install/archives/{alpha.txt,beta.txt,gamma.md,subdir}`
  - vault sidecar 中卡片与收藏均需合法 UUID
- **探针工具**：`/tmp/hittest-probe/`（全部 swift 脚本 + shell 编排）
  - `geom.swift <pid>` — 自适应输出 `PANEL=minX,minY,w,h CELL=x,y SCREEN=w,h LISTS=n`（AX top-left 坐标系；LISTS 为遍历 app 所有窗口 AX 树的 AXList 计数，非命中测试）
  - `drag.swift <sx> <sy> <ex> <ey> [settle]` — CGEvent 合成拖拽；settle ≥ 0.25~0.3 才能让 AppKit 起拖拽会话
  - `click.swift / axprobe.swift / atsystem.swift / ping.swift / reshow.sh` — 点击、AX 树 dump、系统级定位、卡死探测、边缘唤回面板
  - `nopark-dump.sh` — **关键实验**：拖拽终点在面板内部，面板全程不隐藏，验证拖拽会话本身致空白
- **日志采集约束**（重要）：
  - debug 级 OSLog **不落盘**，只能 live 采集：`/usr/bin/log stream --process <pid> --level debug`
  - `log show` 加 `--debug --info` 也拿不到 debug 级历史（默认不持久化）
  - OSLog 单条消息约 1024 字符截断，截断处显示 `<…>` —— 长 dump 必须拆多条输出
- **权限红线**：
  - 终端有 AX 信任；**无屏幕录制权限**，不能截图，只能 AX 间接观测
  - 用户真实应用（同名进程）正在运行，**绝不能触碰**；一切实验只对 `/tmp` fixture 实例进行
  - 用户可能中途改显示配置（本调查期间从 1920 宽切到 1496×967）——坐标必须每次自适应探测，禁止硬编码
  - 机器上有外部编辑器（Cursor/Antigravity）可能回滚文件改动——每次编辑后立即 grep 验证

## debug 模式实现记录（bug3，已实现）

- **开关**：设置 → 关于 → 「诊断日志（调试模式）」，持久化 `debugLoggingEnabled`（UserDefaults）。
- **引擎**：`Tearoff/Shared/Utils/FileLog.swift` —— 单例，按天写 `~/Library/Logs/Tearoff/debug-yyyy-MM-dd.log`；4MB 单文件上限（轮转一份 `.1`）、7 天保留自动清理；全部文件 IO 走一条串行 utility 队列；开启时写版本号会话头、关闭时写会话尾。
- **为什么需要**：debug 级 OSLog 不落盘（只能 live `log stream` 看），用户报障时无法追溯；文件日志正好补位。
- **关闭时开销**：一次 UserDefaults bool 读取 + 分支跳过，`message` 为 `@autoclosure` 不会求值。
- **埋点**（`FileLog.shared.event(category, message)`）：面板 show/hide/suspend/resume（panel）、图标/列表两种文件列表的拖拽会话起止与 remount kick（finder）、卡片 navigate/reload 结果/目录 watcher 事件/操作失败（finder）、右键路由胜负与菜单弹出（contextmenu）、面板级 watcher 挂起恢复（finder）。
- **设置页**：开启后额外显示说明行 + 「打开日志文件夹」按钮（`NSWorkspace.open`）。
- **文案**：5 种语言 locale JSON 均已添加 `settings.about.debugLogging*` 三个 key。
- **验证**：FileLog 独立编译单测通过（会话头/中文/时间戳/会话尾均正确落盘）；`xcodebuild Debug` 构建通过。
- **已清理**的临时诊断：`[CMRouter]` 系列、`postDragDump`/`windowDump`、`updateNSView` 链路 dump —— 有价值的部分已转为 FileLog 埋点。
