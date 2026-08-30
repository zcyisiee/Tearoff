import SwiftUI

// MARK: - OutlineBreadcrumbView

/// Top markdown outline: a breadcrumb of the heading chain leading to the
/// heading currently at the viewport top (follows editor scroll). Clicking a
/// segment opens a popover listing its direct child headings; clicking one
/// jumps to it.
struct OutlineBreadcrumbView: View {
    let outline: OutlineState

    @State private var openPopoverFor: BreadcrumbSegment?

    var body: some View {
        let path = outline.visiblePath()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(path, id: \.self) { index in
                    if index != path.first {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    segment(index)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private func segment(_ index: Int) -> some View {
        let entry = outline.entries[index]
        let isCurrent = index == outline.visibleIndex

        return Button {
            openPopoverFor = BreadcrumbSegment(index: index)
        } label: {
            Text(entry.title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.primary.opacity(isCurrent ? 0.07 : 0)),
                )
        }
        .buttonStyle(.plain)
        .popover(item: $openPopoverFor) { segment in
            childList(parentIndex: segment.index)
        }
    }

    /// Direct child headings of the clicked segment.
    private func childList(parentIndex: Int) -> some View {
        let children = outline.childIndices(of: parentIndex)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(children, id: \.self) { index in
                    Button {
                        openPopoverFor = nil
                        outline.scrollCoordinator.scrollToEntry(at: index)
                    } label: {
                        Text(outline.entries[index].title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 240, height: min(CGFloat(children.count) * 30 + 8, 320))
    }
}

// MARK: - BreadcrumbSegment

/// Popover anchor — which breadcrumb segment's child list is open.
private struct BreadcrumbSegment: Identifiable {
    let index: Int
    var id: Int { index }
}
