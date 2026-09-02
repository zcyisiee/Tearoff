import Foundation
import OSLog

/// Live browsers keyed by card id, so panel-level code (Escape chain, ⌘⇧N routing,
/// show/hide watcher lifecycle) can reach the mounted cards without SwiftUI plumbing.
/// Browsers are held weakly — an entry vanishes on its own when the card view
/// unmounts without unregistering.
@MainActor
final class FinderBrowserRegistry {
    static let shared = FinderBrowserRegistry()

    private struct WeakBox {
        weak var browser: FinderCardBrowser?
        weak var commands: FinderListCommands?
    }

    private var boxes: [UUID: WeakBox] = [:]

    private init() {}

    func register(browser: FinderCardBrowser, commands: FinderListCommands, for cardID: UUID) {
        boxes[cardID] = WeakBox(browser: browser, commands: commands)
    }

    func unregister(_ cardID: UUID) {
        boxes[cardID] = nil
    }

    func browser(for cardID: UUID) -> FinderCardBrowser? {
        let browser = boxes[cardID]?.browser
        if browser == nil {
            boxes[cardID] = nil // dead entry — release the slot
        }
        return browser
    }

    func commands(for cardID: UUID) -> FinderListCommands? {
        boxes[cardID]?.commands
    }

    /// Panel hidden: release every watcher (zero idle fds).
    func suspendAllWatching() {
        for box in boxes.values {
            box.browser?.stopWatching()
        }
    }

    /// Panel shown: re-enumerate once and re-arm watchers for registered (mounted) cards.
    func resumeAllWatching() {
        for box in boxes.values {
            guard let browser = box.browser else { continue }
            browser.reload()
            browser.startWatching()
        }
    }

    /// Escape chain hook: clears the file selection of the focused card. Returns true if it cleared anything.
    func clearSelection(for cardID: UUID) -> Bool {
        commands(for: cardID)?.clearSelection() ?? false
    }

    /// ⌘⇧N routed to a focused card: create a folder named `defaultName` in its
    /// current directory and start renaming it. The list tolerates the row not
    /// existing yet (it queues the rename), so a minimal entry for the new URL
    /// is enough to drive it.
    func createFolder(in cardID: UUID, defaultName: String) {
        guard let browser = browser(for: cardID), let commands = commands(for: cardID) else { return }
        do {
            let url = try browser.createFolder(named: defaultName)
            commands.beginRename(FinderEntry.placeholderFolder(at: url))
        } catch {
            Log.finder.error("Registry createFolder failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension FinderEntry {
    /// A stand-in entry for a freshly created folder, used to kick off an
    /// inline rename before the browser's reload has produced the real row.
    static func placeholderFolder(at url: URL) -> FinderEntry {
        let standardized = url.standardizedFileURL
        return FinderEntry(
            url: standardized,
            name: standardized.lastPathComponent,
            isDirectory: true,
            isPackage: false,
            isSymlink: false,
            modifiedAt: nil,
            fileSize: nil,
            contentTypeIdentifier: nil,
        )
    }
}
