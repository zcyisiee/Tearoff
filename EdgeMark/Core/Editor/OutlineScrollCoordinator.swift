import AppKit
import Foundation
import SwiftUI

// MARK: - OutlineWindowAnchor

/// Zero-size representable placed next to the editor text view. Reports its
/// window as soon as it joins one, so the coordinator can anchor to the right
/// window without guessing from NSApp.keyWindow.
struct OutlineWindowAnchor: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: AnchorView, context _: Context) {
        nsView.onWindowChange = onWindowChange
    }

    final class AnchorView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            onWindowChange?(window)
        }
    }
}

// MARK: - OutlineScrollCoordinator

/// Bridges the outline UI to the engine's text view: resolves the editor's
/// NSScrollView (inside the given window), reports which heading is at the top
/// of the viewport as it scrolls, and scrolls to a heading on outline clicks.
/// Scrolling walks TextKit 2 layout fragments — `scrollRangeToVisible` is
/// unreliable for off-screen content (same reason the engine's find avoids it).
final class OutlineScrollCoordinator {
    /// Called on scroll with the index of the heading at/above the viewport top.
    var onVisibleIndexChanged: ((Int) -> Void)?

    private weak var textView: NSTextView?
    private weak var clipView: NSClipView?
    private var observers: [NSObjectProtocol] = []
    private(set) var entries: [OutlineEntry] = []
    private var lastIndex: Int?

    func setEntries(_ entries: [OutlineEntry]) {
        self.entries = entries
        lastIndex = nil
        syncVisible()
    }

    /// Anchor to the editor's window — called from a view that lives in the same
    /// window as the engine text view (never NSApp.keyWindow, which could be a
    /// peek panel with its own read-only text view).
    func attach(to window: NSWindow?) {
        detach()
        guard let tv = findEditorTextView(in: window?.contentView) else { return }
        textView = tv
        clipView = tv.enclosingScrollView?.contentView

        let center = NotificationCenter.default
        if let clip = clipView {
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main,
            ) { [weak self] _ in self?.syncVisible() })
        }
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        textView = nil
        clipView = nil
        lastIndex = nil
    }

    /// Scroll so the heading's line sits just below the top edge. Does not move
    /// focus or the caret.
    func scrollToEntry(at index: Int) {
        guard let clip = clipView, let tv = textView,
              index < entries.count, let y = headingYs()[index]
        else { return }
        let target = max(0, y - clip.contentInsets.top - 8)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        tv.enclosingScrollView?.reflectScrolledClipView(clip)
        syncVisible()
    }

    // MARK: - Visible heading

    private func syncVisible() {
        guard !entries.isEmpty, let clip = clipView else { return }
        let ys = headingYs()
        // Top of the viewport in text-view coordinates: the clip view's bounds
        // origin plus its top content inset (same mapping the engine uses).
        let visibleTop = clip.bounds.minY + clip.contentInsets.top
        var index = 0
        for (i, y) in ys.enumerated() {
            if let y, y <= visibleTop + 40 {
                index = i
            } else {
                break
            }
        }
        guard index != lastIndex else { return }
        lastIndex = index
        onVisibleIndexChanged?(index)
    }

    /// Y (min frame) of each heading's first layout fragment, single forward
    /// walk over fragments in document order.
    private func headingYs() -> [CGFloat?] {
        var ys: [CGFloat?] = Array(repeating: nil, count: entries.count)
        guard let tv = textView, let tlm = tv.textLayoutManager,
              let content = tlm.textContentManager, !entries.isEmpty
        else { return ys }
        let docStart = content.documentRange.location
        var nextEntry = 0
        tlm.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            let fragStart = content.offset(from: docStart, to: fragment.rangeInElement.location)
            let fragEnd = fragStart + content.offset(
                from: fragment.rangeInElement.location,
                to: fragment.rangeInElement.endLocation,
            )
            let minY = fragment.layoutFragmentFrame.minY
            while nextEntry < ys.count, entries[nextEntry].range.location < fragEnd {
                ys[nextEntry] = minY
                nextEntry += 1
            }
            return nextEntry < ys.count
        }
        return ys
    }
}
