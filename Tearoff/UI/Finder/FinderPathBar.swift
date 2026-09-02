import AppKit
import SwiftUI

/// Finder-style path bar for a Finder card: the absolute path from the volume
/// root (Macintosh HD, or the mounted-volume name) down to the current
/// directory, rendered as an icon + name segment per component, joined by ">".
///
/// Interaction mirrors Finder's own path bar:
/// - Left-click a segment navigates the browser to that directory.
/// - Right-click opens a menu: Copy Path / Show in Finder / Copy Name.
/// - Each segment is a drop destination — dropped files move (or copy,
///   cross-volume / ⌥) into that directory.
///
/// Long paths collapse the middle to "…" like Finder, keeping the volume root
/// and the trailing segments around the current location. The bar is a fixed
/// height so it never steals vertical space from the file list.
struct FinderPathBar: View {
    @Environment(L10n.self) private var l10n

    let browser: FinderCardBrowser
    /// Surfaces failed file operations (drop moves/copies) to the card.
    var onError: ((Error) -> Void)?

    // MARK: - Appearance

    private static let barHeight: CGFloat = 28
    private static let iconSize: CGFloat = 16
    private static let iconGap: CGFloat = 5
    private static let chevronWidth: CGFloat = 6
    private static let chevronGap: CGFloat = 2
    private static let segGap: CGFloat = 5
    private static let edgePad: CGFloat = 2
    /// Slack subtracted from the available width while deciding what fits, so
    /// the estimated segment widths never overflow the bar.
    private static let fitSlack: CGFloat = 4
    /// AppKit font used to estimate text widths (matches `Typography.caption`).
    private static let font = NSFont.systemFont(ofSize: 11)

    var body: some View {
        GeometryReader { geo in
            let segments = resolvedSegments
            let visible = visibleSegments(in: segments, availableWidth: geo.size.width)
            HStack(spacing: Self.segGap) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, item in
                    segmentView(item, showSeparator: index > 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, Self.edgePad)
        }
        .frame(height: Self.barHeight)
    }

    // MARK: - Segments

    /// One rendered path component (the volume root, or a directory on the way
    /// down to the current location).
    private struct PathSegment: Identifiable, Hashable {
        let label: String
        let url: URL
        let isCurrent: Bool

        var id: String {
            url.path
        }
    }

    /// A segment to render — either a real path component or the "…" marker.
    private enum VisibleSegment: Hashable {
        case segment(PathSegment)
        case truncation
    }

    /// The ordered path from the volume root to the current directory, each
    /// component labelled with its display name. Empty when there's no URL.
    private var resolvedSegments: [PathSegment] {
        guard let current = browser.currentURL?.standardizedFileURL else { return [] }

        // Volume root hosting the current path — "/" on the boot volume (the
        // API reports it as "/", not the APFS data volume), or "/Volumes/<Name>"
        // for an external drive. `volumeName` gives the Finder display name.
        if let values = try? current.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey]),
           let volumeURL = values.volume?.standardizedFileURL
        {
            let volumeComponents = volumeURL.pathComponents
            let currentComponents = current.pathComponents
            if currentComponents.count >= volumeComponents.count,
               Array(currentComponents.prefix(volumeComponents.count)) == volumeComponents
            {
                let relative = Array(currentComponents[volumeComponents.count...])
                let volumeName = values.volumeName ?? volumeURL.lastPathComponent

                var segments: [PathSegment] = []
                var running = volumeURL
                segments.append(
                    PathSegment(
                        label: volumeName,
                        url: running,
                        isCurrent: relative.isEmpty,
                    ),
                )
                for (index, name) in relative.enumerated() {
                    running = running.appendingPathComponent(name)
                    segments.append(
                        PathSegment(
                            label: name,
                            url: running,
                            isCurrent: index == relative.count - 1,
                        ),
                    )
                }
                return segments
            }
        }

        // Fallback — live on "/" and walk the components directly.
        let components = Array(current.pathComponents[1...])
        if components.isEmpty {
            return [PathSegment(label: volumeRootName, url: URL(fileURLWithPath: "/"), isCurrent: true)]
        }

        var segments: [PathSegment] = []
        var running = URL(fileURLWithPath: "/", isDirectory: true)
        segments.append(PathSegment(label: volumeRootName, url: running, isCurrent: false))
        for (index, name) in components.enumerated() {
            running = running.appendingPathComponent(name)
            segments.append(
                PathSegment(label: name, url: running, isCurrent: index == components.count - 1),
            )
        }
        return segments
    }

    /// Display name for the boot volume ("/") when `volumeURL` can't be read.
    private var volumeRootName: String {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let name = (try? root.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        return name ?? root.lastPathComponent
    }

    // MARK: - Collapse

    /// Chooses which segments to render so the total width fits the bar.
    /// If the full path doesn't fit, keep the volume root and the trailing
    /// segments around the current location and collapse the hidden middle to
    /// "…", Finder-style. Worst case shows "…" + the current segment.
    private func visibleSegments(in segments: [PathSegment], availableWidth: CGFloat) -> [VisibleSegment] {
        guard !segments.isEmpty else { return [] }

        let full = segments.map(VisibleSegment.segment)
        if listWidth(full) <= availableWidth - Self.fitSlack {
            return full
        }
        guard segments.count >= 2 else { return full }

        let root = segments.first!
        // Try smaller tails (counted from the current location backward) until
        // the root + tail + "…" fits. A tail of `count - 1` is the untruncated
        // full path, so this starts from the most-recently-collapsed-anyway
        // candidate and shrinks.
        for tail in stride(from: segments.count - 1, through: 1, by: -1) {
            let tailSegs = Array(segments.suffix(tail))
            let rootAndTail = [root] + tailSegs.filter { $0.url != root.url }
            let hiddenCount = segments.count - rootAndTail.count
            let candidate = buildCollapsed(rootAndTail, hiddenCount: hiddenCount)
            if listWidth(candidate) <= availableWidth - Self.fitSlack {
                return candidate
            }
        }

        // Nothing fits with the root — show "…" + the current segment.
        return [.truncation, .segment(segments.last!)]
    }

    private func buildCollapsed(_ kept: [PathSegment], hiddenCount: Int) -> [VisibleSegment] {
        guard !kept.isEmpty else { return [.truncation] }
        var result: [VisibleSegment] = [.segment(kept[0])]
        if hiddenCount > 0 {
            result.append(.truncation)
        }
        for segment in kept.dropFirst() {
            result.append(.segment(segment))
        }
        return result
    }

    // MARK: - Width estimation

    /// Estimated rendered width of a visible list, including its ">" separators
    /// and the `segGap` between items.
    private func listWidth(_ visible: [VisibleSegment]) -> CGFloat {
        guard !visible.isEmpty else { return 0 }
        var width: CGFloat = 0
        for (index, item) in visible.enumerated() {
            width += itemWidth(item, showSeparator: index > 0)
            if index < visible.count - 1 {
                width += Self.segGap
            }
        }
        return width
    }

    private func itemWidth(_ item: VisibleSegment, showSeparator: Bool) -> CGFloat {
        let separator = showSeparator ? Self.chevronWidth + Self.chevronGap : 0
        switch item {
        case let .segment(segment):
            return separator + Self.iconSize + Self.iconGap + textWidth(segment.label)
        case .truncation:
            return separator + textWidth("…")
        }
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Self.font]).width
    }

    // MARK: - Segment view

    @ViewBuilder
    private func segmentView(_ item: VisibleSegment, showSeparator: Bool) -> some View {
        switch item {
        case .truncation:
            HStack(spacing: Self.iconGap) {
                if showSeparator {
                    chevron
                }
                Text("…")
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.muted)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())

        case let .segment(segment):
            segmentItemView(segment, showSeparator: showSeparator)
        }
    }

    private func segmentItemView(_ segment: PathSegment, showSeparator: Bool) -> some View {
        HStack(spacing: Self.iconGap) {
            if showSeparator {
                chevron
            }
            Image(nsImage: FileIconCache.shared.icon(forURL: segment.url, size: Self.iconSize))
                .frame(width: Self.iconSize, height: Self.iconSize)
            Text(segment.label)
                .font(DesignToken.Typography.caption)
                .foregroundStyle(segment.isCurrent ? DesignToken.bodyStrong : DesignToken.muted)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !segment.isCurrent else { return }
            browser.navigate(to: segment.url)
        }
        .nsContextMenu {
            segmentMenu(segment)
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls, into: segment.url)
            return true
        }
    }

    /// Small right chevron between path components. Fixed frame so the width
    /// estimate matches the rendered size.
    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DesignToken.mutedSoft)
            .frame(width: Self.chevronWidth)
    }

    // MARK: - Context menu

    private func segmentMenu(_ segment: PathSegment) -> NSMenu {
        let url = segment.url
        let menu = NSMenu()
        menu.addActionItem(title: l10n["finder.file.copyPath"], icon: "link") {
            FinderCardBrowser.copyPaths([url])
        }
        menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
            FinderCardBrowser.revealInFinder([url])
        }
        menu.addActionItem(title: l10n["finder.file.copyName"], icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(segment.label, forType: .string)
        }
        return menu
    }

    // MARK: - Drop destination

    /// Moves (or copies, ⌥ / cross-volume) the dropped files into the segment's
    /// directory, reusing the same plan semantics as the file lists. The
    /// browser's `transfer` guards against moving a directory into itself or a
    /// descendant and skips same-directory drops.
    private func handleDrop(_ urls: [URL], into directory: URL) {
        let target = directory.standardizedFileURL
        let sources = urls.map(\.standardizedFileURL)

        let copy = if NSEvent.modifierFlags.contains(.option) {
            true
        } else if sources.contains(where: { !Self.isSameVolume($0, target) }) {
            true
        } else {
            false
        }

        do {
            if copy {
                try browser.copy(urls, into: target)
            } else {
                try browser.move(urls, into: target)
            }
        } catch {
            onError?(error)
        }
    }

    private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        guard let left = try? lhs.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
              let right = try? rhs.resourceValues(forKeys: keys).volumeIdentifier as? NSObject
        else { return true }
        return left == right
    }
}
