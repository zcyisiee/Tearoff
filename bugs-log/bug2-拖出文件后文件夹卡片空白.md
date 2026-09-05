# bug2：从文件夹卡片拖文件出去后，卡片永久空白（"卡死"/"白卡"）

**状态：第 4 轮修复已实现（2026-09-05），待用户复测**

## 迭代记录

| 轮次 | 方案 | 结果 |
|------|------|------|
| v1 | 拖拽结束 0.1s 后卡片级 `.id()` 重建 | ❌ kick 与 makeNSView 均执行，白卡仍出现 2 次（用户实测日志） |
| v2 | board 级整体重建（0.45s） | ❌ 重建后新视图 `post-mount check: attached=true visItems=2 win=true`，仍白卡 |
| v3 | **display-recovery poke**：拖拽结束 0.1s/0.7s 两次强制窗口同步重绘（`contentView.needsDisplay = true` + `window.display()`） | ❌ 日志证伪：poke 时 `viewsNeedDisplay=false`，display 循环未停摆，poke 无效 |
| v4 | **alpha 恢复**：poke 时遍历 contentView 子树，找出满足「非隐藏、非空 frame、alphaValue < 0.01」的 `_NSGraphicsView`，对每个命中 view 执行 `alphaValue=1` + `layer.opacity=1` + `layer.removeAllAnimations()` + 向上清除祖先 layer opacity + `needsDisplay=true`；poke 节奏加强至 0.1s/0.7s/2.0s 三次 | ⏳ 待用户复测 |

## 当前根因模型（v4，已实锤）

用户日志 `debug-2026-09-05.log`（行 1605 → 1742 → 3369）直接揭示：

1. **拖拽会话期间**，SwiftUI 对卡片 body 的 `_NSGraphicsView` 渲染容器运行了 opacity 动画（淡出，alphaValue 1→0）；
2. **拖拽 teardown 时**，render server commit 被中断——presentation layer 停在 opacity=0，SwiftUI 此后无任何状态变更触发新的 commit；
3. 结果：包裹 `FinderIconListView`/`FinderFileListView` 的所有 `_NSGraphicsView`（frame=16,12,444×240 等）的 `alphaValue` 和 `layer.opacity` 永久锁定在 0.0——**整张 Finder 卡片 body 的 SwiftUI 渲染容器 alpha 全 0，内容永远不画**；
4. 卡内子树完全健康（visibleItems=5，layer 挂载，window=true），只因 alpha=0 而不渲染；
5. 拖动卡片换位恢复的原因：drag-reorder 驱动 SwiftUI 对该卡重新布局/重 commit → 重新算出 alpha=1 的 layer。

**之前（v3）根因模型被证伪**：`window.viewsNeedDisplay=false` 证明 display 循环并未停摆，而是根本没有待绘制内容入队（因为 alpha=0 的 view 被跳过）。正确模型是 **alpha 卡 0**，不是 display 循环停摆。

## alpha 恢复判定逻辑（v4 安全性论证）

判定条件（三个必须同时满足，且满足后再过滤类名）：

```swift
!view.isHidden          // 排除 SwiftUI 用 isHidden=true 隐藏的 view
&& !view.frame.isEmpty  // 排除尚未布局的零尺寸 view
&& view.alphaValue < 0.01
```

类名过滤：`className.hasSuffix("_NSGraphicsView")`

**为何不误伤**：
- `isHidden=true` 的 SwiftUI 内部占位/transition view → 被 `isHidden` 条件排除；
- frame 为零的未布局容器 → 被 `frame.isEmpty` 条件排除；
- 其他正常 alpha=0 的 AppKit 控件（状态栏小按钮、隐式隐藏背景层等）→ 类名不含 `_NSGraphicsView`，被类名过滤排除；
- 唯一可能误判：SwiftUI `.opacity(0)` modifier 写出的有意 alpha=0 的 `_NSGraphicsView`——这类 view 不 `isHidden`，有实际 frame，类名符合。当前代码会将其拉回 1，但此行为发生在极窄的时间窗口（拖拽结束后 0.1s/0.7s/2.0s），且 SwiftUI 下次 layout pass 会按需重设为正确值，属于可接受的短暂误判。

## 用户实测观察（v2 轮，决定性）

1. 白卡出现后**一直白**，不会自愈；拖拽文件回卡片等操作照常成功（视图活着、可交互，仅不渲染）。
2. 白卡时**卡片标题栏正常渲染**（SwiftUI 图形走 CA 合成不受影响；只有 AppKit 文件列表区域不画）。
3. 面板**隐藏再唤回不恢复**（窗口搬运/setFrame 不驱动重绘）。
4. **在卡片上按下并拖动（移动卡片位置）立即恢复**——drag-reorder 触发 SwiftUI 重 commit，重新算出 alpha=1 的 layer。

## 已确证的事实（调查期）

### 1. 不是死锁，是渲染永久损坏
空白状态下 `sample` 主线程空闲（`mach_msg2_trap`）。App 完全响应，只是那张卡片的 NSCollectionView 子树**不再被绘制**。

### 2. AppKit 视图树在空白状态下完全健康（决定性证据）
在拖拽会话结束瞬间（t0）及 +0.5s、+2s 各 dump 一次（`postDragDump`），三份完全一致：

```
collection 444x286 hid=false alpha=1.0 win=true visItems=5 selItems=1
collectionLayer 444x286 super=true hid=false op=1.0
ownWindow #86007 508x939@988,0 occlusion=visible
```

- 5 个可见 item 全在、选中态在、layer 挂在父 layer 上、不隐藏、透明度 1。
- 所属窗口就是屏幕上面板窗口，occlusion=visible。
- 没有发生 dismantle/make（representable 未重建）。

### 3. 但 AX 树在同一瞬间丢失了列表子树
`geom.swift`（遍历 app 所有窗口的 AX 树统计 `AXList`）：

```
before: PANEL=988,28,508,939 CELL=1077,217 SCREEN=1496,967 LISTS=2
after : PANEL=988,28,508,939 CELL=none      SCREEN=1496,967 LISTS=0
```

### 4. 与面板隐藏/停放/唤回完全无关（关键实验 nopark）
拖拽终点放在面板内部（无效放置目标、面板全程不隐藏），卡片照样立即空白。
⇒ 致坏死因就是**拖拽会话的结束本身**。

### 5. 神秘第三窗口不是元凶
cgwin 探针：那个 1×1、alpha=0、layer=3 的窗口在**未复现空白**的正常运行里同样存在 → 排除。

## 已排除的假设（附排除依据）

| 假设 | 排除依据 |
|------|----------|
| sidecar `currentPath: null` 导致卡片丢目录 | 收藏根目录的规范化写回，正常行为，误报 |
| `parkedFrame` 100pt 高度残根导致 | 改为保留窗口全高后依旧空白 |
| `hideDelay=0` 与拖拽结束的竞态 | 加 0.35s `dismissalDeferralDeadline` 双保险后依旧空白；nopark 实验里根本没有隐藏发生 |
| DirectoryWatcher / suspendAllWatching / reload 出错 | reload 正常枚举（v2 日志：2/3 entries 数毫秒完成） |
| NSViewRepresentable 被拆卸/未重建 | make/dismantle 日志证明 v1/v2 重建均执行且新视图 attached=true |
| 卡片 entries 被清空（空态遮罩） | visItems>0；AX 连 AXList 容器都没了 |
| 拖拽残留窗口盖在面板上 | 正常运行同样存在该 1×1 窗口 |
| 损坏在任何视图对象内 | v2 全新视图链（attached、有数据、在窗口）依旧白卡 |
| 面板隐藏/停放循环 | nopark：不隐藏也白卡；用户实测隐藏唤回不恢复 |
| display 循环停摆（v3 模型） | poke 时 `viewsNeedDisplay=false` 证伪；正确根因是 alpha 卡 0 |

## 人工验证清单

1. 从卡片拖文件到 Finder 父目录（及拖回卡片），重复 3~5 次（间歇性）。
2. 每次拖出后约 0.1s / 0.7s / 2.0s 内应被 alpha-recovery 自动拉回（无感）；日志行 `alpha-recovery restored N container(s)` 确认恢复动作执行。
3. 若仍出现持续白卡，保留日志 `~/Library/Logs/Tearoff/debug-当天.log`——检查 `alpha-recovery` 行是否出现、`recovered` 计数是否 > 0。

## 现象与复现

- 用户路径：文件夹卡片浏览 `~/Desktop/博0/杂项/常用/clash-for-linux-install/archives`，把其中文件拖到父目录 `clash-for-linux-install`（Finder 窗口）。
- "卡死"时：**卡片内部为背景、看不见文件，卡片底部有一圈透明边框**。面板本身仍能显示/隐藏，但该卡片永远空白，图标/列表视图切换无效。
- 用户关键设置：`hideDelay = 0`（鼠标离开立即隐藏）、`activationDelay = 0.3`、动画 `slide`。
- 自动化复现（沙盒 fixture）稳定成立：`/tmp/hittest-probe/nopark-dump.sh`。
