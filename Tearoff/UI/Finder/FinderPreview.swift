import AppKit
import Foundation
import OSLog
import QuickLookUI

/// One helper object that both drives Quick Look for a Finder card and exposes
/// the system "Get Info" bridge. A card holds one instance (`@State`) so the
/// panel's data source / delegate stay alive across the panel's lifetime.
///
/// Quick Look uses the app's single `QLPreviewPanel`. `NSURL` itself is a
/// `QLPreviewItem`, so the data source hands over raw URLs and the panel
/// handles thumbnail/preview generation for files, folders, and symlinks.
@MainActor
final class FinderQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// URLs backing the current Quick Look session, in display order.
    private var urls: [URL] = []
    /// Fired once when the panel closes — the card uses it to resume auto-hide.
    private var onClose: (() -> Void)?

    /// Opens (or re-targets) the shared Quick Look panel on `urls`. Closing the
    /// panel (via `previewPanelDidClose`) invokes `onClose` exactly once, so the
    /// card can resume the panel's auto-hide.
    func show(_ urls: [URL], onClose: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        self.onClose = onClose

        guard let panel = QLPreviewPanel.shared() else {
            Log.finder.error("Quick Look panel unavailable")
            onClose()
            return
        }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in _: QLPreviewPanel) -> Int {
        urls.count
    }

    func previewPanel(_: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        urls[index] as NSURL
    }

    // MARK: QLPreviewPanelDelegate

    func previewPanelDidClose(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        let close = onClose
        urls = []
        onClose = nil
        close?()
    }
}

/// System-bridge helpers for the Finder card's file menus.
enum FinderSystemBridge {
    /// Opens the Finder "Get Info" window for `url` via AppleScript. There is
    /// no `NSWorkspace` API for Get Info; the Finder script is the lightest
    /// system bridge. The app is not sandboxed, so this only needs the user to
    /// grant Automation access to Finder on first use.
    static func presentGetInfo(for url: URL) {
        // Quote the path for AppleScript's string literal.
        let escaped = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\")"

        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            Log.finder.error("Get Info failed: \(message, privacy: .public)")
        }
    }
}
