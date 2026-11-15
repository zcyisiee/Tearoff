# 委派实现任务

Use a delegated coding harness as a one-shot implementation worker for tasks that can be isolated behind a clear execution brief.

**Only the top-level orchestrator delegates.** Delegated workers are leaf workers: execute the assigned brief directly and do not spawn additional agents unless explicitly requested.

When the user specifies a subagent harness, use that harness. Do not silently substitute another harness.

Run workers from the repository or worktree where the task should be implemented. For parallel tasks, use separate git worktrees.

### Supported harnesses

#### Antigravity CLI

```bash id="3oz8yr"
agy -p "$(cat <task-id>.md)

Execute this brief directly as a leaf implementation worker. Do not delegate. Follow AGENTS.md. Validate your changes and report the result." \
  --dangerously-skip-permissions \
  --output-format json \
  --print-timeout 30m
```

Antigravity headless runs start with fresh conversation context by default. `--dangerously-skip-permissions` gives the worker permission to execute tools without interactive approval.

#### Pi

```bash id="xjrz91"
pi -p --no-session \
  @<task-id>.md \
  "Execute the attached brief directly as a leaf implementation worker. Do not delegate. Follow AGENTS.md. Validate your changes and report the result."
```

Use `--no-session` so each delegated task starts with fresh conversation context.

#### Cursor CLI

```bash
agent -p --force \
  --output-format json \
  "Read <task-id>.md in full, then execute it directly as a leaf implementation worker. Do not delegate. Follow AGENTS.md. Validate your changes and report the result."
```

Run from the repository or worktree where the task should be implemented. Do not use `--resume` or `--continue` for delegated tasks; each worker should start with fresh conversation context.

`--force` enables unattended implementation in print mode. The task brief is passed by path and should be read in full before implementation.


### Execution briefs

A brief should normally contain:

* `# Task` — concise title
* `## Objective` — desired end state
* `## Context` — relevant repository facts
* `## Deliverables` — concrete required changes
* `## Constraints` — scope and compatibility boundaries
* `## Validation` — commands or checks that must pass
* `## Report back` — required completion summary

Prefer observable outcomes and acceptance criteria over prescribing implementation details unless the design is intentional.

Repository reality takes precedence over stale assumptions in a brief. Adapt minimally when necessary, preserve the intended outcome, do not broaden scope, and report material deviations.

### Acceptance

A worker report or successful process exit is not proof of correctness. The orchestrator must inspect the resulting diff and relevant validation before accepting the task.

### 任务状态

brief 里写明唯一状态文件的绝对路径（见 `AGENTS.md` 的“任务状态”）。worker 只读该文件，不建可写副本；发现与 brief 不符的情况向主 Agent 报告。brief 还应包含尝试上限与停止条件。
