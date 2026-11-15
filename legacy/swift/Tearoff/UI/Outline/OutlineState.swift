import SwiftUI

// MARK: - OutlineState

/// Shared outline state for the editor screen: parsed headings, the heading at
/// the top of the viewport (scroll sync), and collapse state. Owned by
/// EditorScreen, fed by MarkdownEditorView, read by the panel/breadcrumb views.
@Observable
final class OutlineState {
    private(set) var entries: [OutlineEntry] = []
    /// Index into `entries` of the heading at the viewport top.
    private(set) var visibleIndex: Int = 0
    /// Collapsed subtree keys — session-only, resets on app restart (same policy
    /// as the editor's per-note scroll offsets). Keyed by `OutlineEntry.pathKey`.
    private(set) var collapsedKeys: Set<String> = []

    let scrollCoordinator = OutlineScrollCoordinator()

    init() {
        scrollCoordinator.onVisibleIndexChanged = { [weak self] index in
            self?.visibleIndex = index
        }
    }

    func update(body: String, hiddenHeading: String?) {
        entries = MarkdownOutline.parse(body: body, hiddenHeading: hiddenHeading)
        scrollCoordinator.setEntries(entries)
    }

    func toggleCollapsed(_ key: String) {
        if collapsedKeys.contains(key) {
            collapsedKeys.remove(key)
        } else {
            collapsedKeys.insert(key)
        }
    }

    // MARK: - Tree queries

    /// Whether any entry directly follows `index` nested under it.
    func hasChildren(_ index: Int) -> Bool {
        childIndices(of: index).isEmpty == false
    }

    /// Indices of entries directly nested under `index`.
    func childIndices(of index: Int) -> [Int] {
        guard index < entries.count else { return [] }
        let level = entries[index].level
        var children: [Int] = []
        for i in (index + 1) ..< entries.count {
            if entries[i].level <= level {
                break
            }
            if entries[i].level == level + 1 {
                children.append(i)
            }
        }
        return children
    }

    /// Panel rows: entries whose ancestors are all expanded.
    func visibleRowIndices() -> [Int] {
        // Hidden if any ancestor (strictly higher level, earlier entry) is collapsed.
        var hiddenUntilLevel: Int?
        var rows: [Int] = []
        for (i, entry) in entries.enumerated() {
            if let limit = hiddenUntilLevel, entry.level > limit {
                continue
            }
            hiddenUntilLevel = collapsedKeys.contains(entry.pathKey) ? entry.level : nil
            rows.append(i)
        }
        return rows
    }

    /// Breadcrumb chain: ancestors of the visible heading, ending at it.
    func visiblePath() -> [Int] {
        guard visibleIndex < entries.count else { return [] }
        var path: [Int] = [visibleIndex]
        var level = entries[visibleIndex].level
        for i in stride(from: visibleIndex - 1, through: 0, by: -1) {
            if entries[i].level < level {
                path.append(i)
                level = entries[i].level
            }
        }
        return path.reversed()
    }
}
