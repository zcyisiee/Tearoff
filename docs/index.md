# 文档索引

采用 harness engineering 最小文档规范：短入口定位知识，唯一任务状态支持恢复，代码与实测校正事实，任务完成后沉淀经验。

| 位置 | 只回答的问题 |
|---|---|
| `AGENTS.md` | 从哪里开始、守什么边界、当前任务在哪 |
| `ARCHITECTURE.md` | 系统现在怎样组成、数据怎样流动、边界怎样验证 |
| `docs/guide/development.md` | 怎样运行、验证、排查、交付 |
| `docs/guide/delegation.md` | 怎样委派并独立验收 |
| `docs/reference/contracts.md` | 当前的命令、事件、存储格式与失败语义 |
| `docs/design/` | 已定但未实现、或待决定的方案 |
| `docs/issues/` | 已核实的重要缺陷：现象、证据、根因、状态 |
| `docs/lessons/` | 已验证、可复用的经验与适用边界 |
| `.plan/<任务>/task-state.md` | 某个任务的意图、进度、下一步（每任务唯一） |

## 维护规则

- 改架构同步改 `ARCHITECTURE.md`；改行为同步改 `contracts.md` 和对应测试；改运行或验收方式同步改开发指南。
- “待核实 / 已复现 / 已实现 / 已验收”分开写。没跑过的不写成能力。
- 字段全集以源码为准（`src/lib/types.ts`、`src-tauri/src/*.rs`）；文档只补责任和语义。
- 新内容先并入已有文档，有独立读者和持续维护责任才拆篇。历史用 Git 回溯。
- 旧版开发期间的任务记录在 `legacy/history/`（`bugs-log` 已入库；`tasks` 仅本地保留）。
