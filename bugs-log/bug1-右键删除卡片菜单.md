# bug1：已有卡片无法删除（右键菜单路由错误）

**状态：已修复，构建通过，GUI 自动化验证通过（2026-09-05）**

## 现象

右键文件夹卡片标题右侧的空白区域，弹出的是底板的"新建笔记"菜单，而不是卡片自身菜单，导致没有任何入口能删除已有卡片。

正确行为：右键标题右侧空白区域应弹出卡片菜单（重命名 / 在 Finder 中显示 / 笔记颜色 / 置顶 / **删除卡片** 等）。

## 根因

`Tearoff/UI/Components/NSContextMenuModifier.swift` 的 `ContextMenuRouter` 用多个被动 `ContextMenuCatcher`（透明 NSView）覆盖各区域（底板背景、卡片 header 等）。进程级右键监听触发时，用 `isDeeper(_:_:)` 在候选 catcher 中选"最深"者弹菜单。

原 `isDeeper` 依赖 z-order（兄弟索引）→ 深度 → 面积 的启发式。底板背景 catcher 与卡片 header catcher 不在同一个直接父视图的兄弟序列里，z-order 比较给出错误答案，board 菜单抢走了右键。

## 修复

containment（包含关系）优先于 z-order：给 `ContextMenuCatcher` 增加 `frameInWindow`（`convert(bounds, to: nil)`），两候选中 frame 完全被对方包含者（更内层者）获胜；无法用包含关系分出时才回退原启发式：

```swift
private static func isDeeper(_ lhs: ContextMenuCatcher, _ rhs: ContextMenuCatcher) -> Bool {
    if let lhsFrame = lhs.frameInWindow, let rhsFrame = rhs.frameInWindow {
        let lhsNested = rhsFrame.contains(lhsFrame)
        let rhsNested = lhsFrame.contains(rhsFrame)
        if lhsNested != rhsNested {
            return lhsNested
        }
    }
    if isViewAbove(lhs, than: rhs) { return true }
    if isViewAbove(rhs, than: lhs) { return false }
    if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
    return lhs.bounds.width * lhs.bounds.height < rhs.bounds.width * rhs.bounds.height
}
```

## 验证

GUI 自动化（CGEvent 右键 + AX 读取菜单项）：

1. 右键卡片标题右侧空白 → 弹出菜单包含"删除卡片" ✅
2. 点击"删除卡片" → sidecar `finderCards` 中该卡片被移除、卡片从面板消失 ✅

## 遗留

- 文件中保留了一批 `[CMRouter]` 临时诊断日志（popMenu 胜负、监听器命中、SwiftUI region 候选数），待 bug2 结束后统一清理或并入 debug 模式。
