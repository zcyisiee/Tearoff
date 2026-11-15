import Foundation
import OSLog

/// Watches a single directory's vnode for changes — one instance per visible
/// Finder card, targeting only the card's *current* directory (no recursion,
/// no FSEvents, no watching of favourites roots).
///
/// The dispatch source uses `queue: .main` deliberately: vnode events are rare,
/// the handler only debounces, and that keeps the class MainActor-clean with no
/// Sendable gymnastics.
///
/// Idle cost when stopped is zero — `stop()` cancels the source, which closes
/// the file descriptor via its cancel handler. The owner (a card view) must
/// call `stop()` when the card scrolls away or the panel hides; `deinit` also
/// cancels the source directly as a safety net (DispatchSource cancellation is
/// thread-safe, so it works from a nonisolated deinit).
final class DirectoryWatcher {
    enum Event: Sendable {
        /// Debounced notification that the directory's contents changed.
        case contentsChanged
        /// The watched directory was renamed or deleted. Emitted immediately,
        /// cancelling any pending `contentsChanged`.
        case directoryVanished
    }

    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: (Event) -> Void

    private var source: DispatchSourceFileSystemObject?
    private let debouncer: Debouncer

    /// True while a vnode source is live (file descriptor open).
    var isActive: Bool {
        source != nil
    }

    init(url: URL, debounce: TimeInterval = 0.2, onChange: @escaping (Event) -> Void) {
        self.url = url
        debounceInterval = debounce
        self.onChange = onChange
        debouncer = Debouncer(delay: debounce)
    }

    /// Opens the directory with `O_EVTONLY` and starts watching. If the open
    /// fails (e.g. vanished directory), logs and does nothing.
    func start() {
        guard source == nil else { return }

        let path = url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            Log.finder.error("DirectoryWatcher: open(\(path, privacy: .public), O_EVTONLY) failed: errno \(errno)")
            return
        }

        let watcherSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main,
        )
        watcherSource.setEventHandler { [weak self] in
            // The queue is .main, so it's safe to hop back onto the MainActor
            // synchronously. Read state through self so nothing but the actor-
            // isolated object is captured in this @Sendable closure.
            MainActor.assumeIsolated {
                guard let self, let activeSource = self.source else { return }
                self.handleFileSystemEvent(activeSource.data)
            }
        }
        watcherSource.setCancelHandler {
            close(fd)
        }
        watcherSource.resume()
        source = watcherSource
    }

    /// Cancels the source (closing the file descriptor) and drops any pending
    /// debounced event. Idempotent.
    func stop() {
        guard let source else { return }
        self.source = nil
        debouncer.cancel()
        source.cancel()
    }

    // MARK: - Event handling

    private func handleFileSystemEvent(_ data: DispatchSource.FileSystemEvent) {
        if data.contains(.delete) || data.contains(.rename) {
            // The watched directory itself went away or was renamed — surface
            // immediately and re-arm nothing.
            debouncer.cancel()
            onChange(.directoryVanished)
        } else {
            debouncer.call { [weak self] in
                self?.onChange(.contentsChanged)
            }
        }
    }

    deinit {
        // deinit is nonisolated under default MainActor isolation, so `stop()`
        // can't be called here. Cancelling the source is thread-safe and runs
        // the cancel handler (close(fd)) on the main queue. A pending debounce
        // timer fires into a dead closure — the onChange callback captures its
        // owner weakly, so that's a no-op. Owners should still call stop().
        source?.cancel()
    }
}
