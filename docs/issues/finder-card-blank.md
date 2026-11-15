# 文件夹卡片：快速拖文件后整张卡片空白

- 影响：Swift 4.x（`legacy/swift/`）。v5 没有对应机制。
- 状态：根因已证实（代码 + 用户日志）。补丁在提交 `5586b3f`，Debug 构建通过，**尚未做 GUI 复测**。

## 现象

在文件夹卡片里把文件拖到父文件夹（或拖出面板），拖得快时卡片几乎必定变成空白：只剩一个带边框的空壳，文件操作其实仍然成功。收起再唤出面板不恢复；按住卡片拖动一下换位立即恢复。

## 根因

两套拖拽共用了同一串鼠标事件，其中一套永远收不到“结束”。

1. `FinderCardView` 在**整张卡片**上挂了一个 SwiftUI `DragGesture(minimumDistance: 8)`，用于卡片换位。卡片里内嵌的文件列表是 AppKit 的 `NSCollectionView`/`NSTableView`，但 SwiftUI 的手势识别器同样能看到落在它上面的鼠标事件（源码注释里承认了这一点，并为 tap 做了时间窗过滤，却没有为 drag 做）。
2. 慢拖时，AppKit 在移动 3–4pt 后就发起 `NSDraggingSession` 并接管事件流，SwiftUI 的手势永远够不到 8pt，相安无事。**快拖时，单个 `mouseDragged` 事件的位移就超过 8pt**：SwiftUI 的 `onChanged` 先触发 → `handleDragTick` → `dragSession.begin(卡片)`。于是原卡片被设为 `.opacity(isDragging ? 0 : 1)` 的 0，同时在面板上层挂出一个“拖拽替身”（`BoardDragReplica`）。
3. 紧接着 AppKit 的文件拖拽会话开始，在自己的事件循环里吃掉后续所有事件，包括 mouse-up。SwiftUI 手势的 `onEnded` **永远不会到达**，`dragSession.item` 一直不清空。
4. 本来有两道兜底，都失效：
   - mouse-up 本地监听器（`installDragMouseUpMonitor`）判断的是 `dragSession.noteID != nil`，而文件夹卡片的 `noteID` **恒为 nil**（只有笔记才有）；况且拖拽会话期间的 mouse-up 也不经过本地监听器。
   - 替身的 `onDisappear` 清理同样判断 `noteID`。

结果：换位会话永久泄漏。原卡片 opacity 恒为 0（空白），替身停在原地——替身对文件夹卡片只画标题栏和空的卡片面，这就是“标题正常、内容空白、底部有一圈边框”的那个壳。再拖一次卡片，手势正常结束、会话被清掉，所以“拖动换位即恢复”。

## 证据

- 代码：`legacy/swift/Tearoff/UI/Finder/FinderCardView.swift`（卡片级 `DragGesture`、`.opacity(isDragging ? 0 : 1)`）、`UI/Board/NoteBoardView.swift`（`handleDragTick`、兜底里的 `noteID`）、`UI/Board/BoardNoteCard.swift`（`BoardDragReplica`、`noteID` 定义）。
- 用户日志 `~/Library/Logs/Tearoff/debug-2026-11-13.log`（出问题）对比 `debug-2026-11-15.log`（正常），同一时点（文件拖拽结束 +0.1s）的视图树：
  - 出问题时多出 10 个 `_NSGraphicsView 454x353`（正是卡片外框尺寸）和一整套重复的标题栏按钮（`18x18` 6 个对 3 个、`54x20` 4 个对 2 个、`98x20` 2 个对 1 个）——替身被挂了出来，而用户拖的是文件。
  - 出问题时原卡片内 21 个容器 `alpha=0.0`，正常时全部 `1.0`；像素探针 `ink=0` 对 `ink=4352`。
- 这也解释了此前四轮修复为何无效：重建视图（`.id()`）没用，因为状态在 board 的 `dragSession` 里；强制重绘没用，因为 SwiftUI 的状态就是“应当透明”；把 alpha 硬拉回 1 没用，因为下一次布局又按状态设回 0。之前记录的“渲染提交被拖拽打断，alpha 卡在 0”是症状，不是原因。

## 修复（4.x，提交 `5586b3f`）

1. 源头：记录内嵌文件列表在 `BoardCardSpace` 里的矩形；按下点落在其中时，卡片级 `DragGesture` 不启动换位。
2. 文件拖拽会话开始和结束时都调用 `cancelCardDrag()`，并在会话期间忽略 `handleDragTick`。
3. 两处兜底由 `noteID` 改为 `itemID`。

未动之前加的 alpha 恢复逻辑（现在应当不再触发，日志里 `alpha-recovery restored` 若仍出现说明还有别的路径）。

## 复测方法（待做）

在文件夹卡片里快速把文件甩向父目录的面包屑或 Finder 窗口，重复 20 次；卡片不应变空白，日志不应再出现 `alpha-recovery restored`。偶发时日志会有 `card drag cancelled by file drag session`，表示第 2 道防线起了作用。

## v5 为什么不会重演

文件拖拽只有一套：按下移动后交给系统级拖拽，落点由带坐标的 drop 事件解析（`src/lib/drops.ts`）。卡片不持有“正在拖拽”的状态，没有可泄漏的东西。更一般的教训见 `docs/lessons/index.md`。
