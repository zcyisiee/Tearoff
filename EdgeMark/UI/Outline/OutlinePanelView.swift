import SwiftUI

// MARK: - OutlinePanelView

/// Right-hand markdown outline: indented heading tree with collapsible nodes,
/// current-heading highlight (driven by `OutlineState.visibleIndex`), and a
/// drag handle to resize the panel (width persisted via `AppSettings`).
struct OutlinePanelView: View {
    @Environment(L10n.self) var l10n
    let outline: OutlineState

    @State private var hoveredRow: Int?

    var body: some View {
        HStack(spacing: 0) {
            ResizeHandle()
            VStack(spacing: 0) {
                header
                Divider()
                if outline.entries.isEmpty {
                    emptyState
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }

    private var header: some View {
        Text(l10n["outline.title"])
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private var emptyState: some View {
        Text(l10n["outline.empty"])
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(outline.visibleRowIndices(), id: \.self) { index in
                        row(index)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: outline.visibleIndex) { _, newIndex in
                // Keep the current heading in view, like VSCode's outline.
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func row(_ index: Int) -> some View {
        let entry = outline.entries[index]
        let hasChildren = outline.hasChildren(index)
        let isCurrent = index == outline.visibleIndex
        let isHovered = hoveredRow == index

        return HStack(spacing: 2) {
            if hasChildren {
                Button {
                    outline.toggleCollapsed(entry.pathKey)
                } label: {
                    Image(systemName: outline.collapsedKeys.contains(entry.pathKey) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Text(entry.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(entry.level - 1) * 12 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.primary.opacity(isCurrent ? 0.1 : (isHovered ? 0.05 : 0))),
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            outline.scrollCoordinator.scrollToEntry(at: index)
        }
        .onHover { hovered in
            hoveredRow = hovered ? index : nil
        }
    }
}

// MARK: - ResizeHandle

/// Narrow draggable strip on the panel's left edge. Mutates
/// `AppSettings.shared.outlinePanelWidth`; the owning layout reads that value.
private struct ResizeHandle: View {
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        let start = dragStartWidth ?? AppSettings.shared.outlinePanelWidth
                        dragStartWidth = start
                        // Panel is on the right: dragging left grows it.
                        AppSettings.shared.outlinePanelWidth = max(180, min(420, start - value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    },
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}
