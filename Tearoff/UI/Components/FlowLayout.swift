import SwiftUI

/// Left-to-right wrapping flow. Each subview keeps its intrinsic size and
/// drops to the next line when the remaining width isn't enough. Items in a
/// row are vertically centered; `minRowHeight` keeps header tabs aligned with
/// the 28pt icon cluster so wrapped rows don't look like a ragged stack.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var minRowHeight: CGFloat

    init(
        spacing: CGFloat = DesignToken.Space.xs,
        lineSpacing: CGFloat = 6,
        minRowHeight: CGFloat = 0,
    ) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.minRowHeight = minRowHeight
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for item in result.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size),
            )
        }
    }

    private struct Item {
        var index: Int
        var origin: CGPoint
        var size: CGSize
    }

    private struct Arrangement {
        var items: [Item]
        var size: CGSize
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        guard !subviews.isEmpty else { return Arrangement(items: [], size: .zero) }
        let limit = proposal.width ?? .infinity

        var sizes: [CGSize] = []
        sizes.reserveCapacity(subviews.count)
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if limit.isFinite, size.width > limit {
                size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
            }
            sizes.append(size)
        }

        var items: [Item] = []
        var row: [(index: Int, x: CGFloat, size: CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0

        func commitRow() {
            guard !row.isEmpty else { return }
            let rowHeight = max(minRowHeight, row.map(\.size.height).max() ?? 0)
            for entry in row {
                let itemY = y + (rowHeight - entry.size.height) / 2
                items.append(Item(
                    index: entry.index,
                    origin: CGPoint(x: entry.x, y: itemY),
                    size: entry.size,
                ))
            }
            usedWidth = max(usedWidth, row.last.map { $0.x + $0.size.width } ?? 0)
            y += rowHeight + lineSpacing
            x = 0
            row.removeAll(keepingCapacity: true)
        }

        for (index, size) in sizes.enumerated() {
            if x > 0, x + size.width > limit {
                commitRow()
            }
            row.append((index, x, size))
            x += size.width + spacing
        }
        commitRow()

        let height = max(0, y - lineSpacing)
        return Arrangement(items: items, size: CGSize(width: usedWidth, height: height))
    }
}
