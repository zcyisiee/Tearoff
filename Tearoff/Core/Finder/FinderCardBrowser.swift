import AppKit
import Foundation
import OSLog
import UniformTypeIdentifiers

/// Errors surfaced by the Finder card's file operations. Plain English for
/// now — localization happens in the UI layer.
enum FinderOperationError: LocalizedError {
    case invalidName
    case nameTaken
    case invalidDestination
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "That name can’t be used."
        case .nameTaken:
            "An item with that name already exists here."
        case .invalidDestination:
            "That destination isn’t valid."
        case let .underlying(error):
            error.localizedDescription
        }
    }
}

/// The non-UI engine behind a Finder card: current directory, its entries,
/// directory watching, and the file operations the card's menus offer.
/// One instance per card view — the view owns it in `@State`.
@Observable
final class FinderCardBrowser {
    enum LoadError: Equatable, Error {
        case notFound
        case notReadable
        case other(String)
    }

    // MARK: - Observable state

    private(set) var currentURL: URL?
    private(set) var entries: [FinderEntry] = []
    private(set) var isLoading = false
    private(set) var loadError: LoadError?

    /// Selected entry ids (= `FinderEntry.id`, standardized paths).
    var selection: Set<String> = []

    /// Always equals `entries.count`; kept as its own property for the UI's
    /// count label.
    private(set) var totalCount = 0

    /// Sort column applied on `reload()`. The card view syncs this from the
    /// card's sidecar settings on mount and whenever they change; changing it
    /// here does not re-enumerate on its own (call `reload()` for immediate
    /// effect, or let the card's onChange drive it).
    var sortKey: FinderSortKey = .name

    /// Direction of the sort. `true` = ascending.
    var sortAscending: Bool = true

    /// Observer for the app-wide hidden-file toggle; reloads when it flips.
    private var showHiddenFilesObserver: NSObjectProtocol?

    // MARK: - Watching

    private(set) var isWatching = false
    private var watcher: DirectoryWatcher?

    init() {
        // The hidden-file flag is app-wide shared state in `AppSettings`; each
        // mounted browser reloads when it flips so all cards stay in sync.
        showHiddenFilesObserver = NotificationCenter.default.addObserver(
            forName: .finderShowHiddenFilesChanged,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let showHiddenFilesObserver {
            NotificationCenter.default.removeObserver(showHiddenFilesObserver)
        }
    }

    // MARK: - History

    /// Previous locations for ⌘[ (`goBack`). Back-most is furthest in the past.
    private var backStack: [URL] = []
    /// Locations discarded by a forward push / new navigation, for ⌘]
    /// (`goForward`). Front-most is next in the future.
    private var forwardStack: [URL] = []

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    // MARK: - Callbacks

    /// Wired by the UI to persist `currentPath` into the sidecar.
    var onCurrentURLChanged: ((URL?) -> Void)?

    /// Bumped on every `reload()`; stale background results are dropped.
    private var generation = 0

    // MARK: - Navigation

    /// Shows `url` (standardized). Clears selection, fires
    /// `onCurrentURLChanged`, reloads, and — when watching — re-targets the
    /// vnode watcher at the new directory.
    ///
    /// `recordsHistory` is `true` for user navigation (path-bar click, folder
    /// activation, `goUp`): the previous location is pushed onto the back
    /// stack and the forward stack is cleared, Finder-style. It is `false` for
    /// the initial mount and for store-driven repositioning (`syncBrowserWithURL`),
    /// which establish the canonical location without adding a history entry.
    func navigate(to url: URL?, recordsHistory: Bool = true) {
        let standardized = url?.standardizedFileURL

        if recordsHistory, let previous = currentURL, previous != standardized {
            backStack.append(previous)
            forwardStack.removeAll()
        }

        currentURL = standardized
        selection = []
        onCurrentURLChanged?(standardized)

        if isWatching {
            retargetWatcher(to: standardized)
        }
        reload()
    }

    /// Navigates to the parent directory. Returns false when there's nowhere
    /// to go (no current directory, or already at the filesystem root).
    /// Counts as a navigation (pushes the current location onto the back stack).
    @discardableResult
    func goUp() -> Bool {
        guard let currentURL else { return false }
        let parent = currentURL.deletingLastPathComponent()
        // At "/" deletingLastPathComponent returns "/" itself.
        guard parent.path != currentURL.path else { return false }
        navigate(to: parent)
        return true
    }

    /// Steps back in history. Pops the previous location, pushes the current
    /// one onto the forward stack, and re-targets without recording a new
    /// history entry. Returns false when the back stack is empty.
    @discardableResult
    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        if let currentURL {
            forwardStack.append(currentURL)
        }
        revealHistoryLocation(previous)
        return true
    }

    /// Steps forward in history. Pops the next location, pushes the current
    /// one back onto the back stack, and re-targets without recording a new
    /// history entry. Returns false when the forward stack is empty.
    @discardableResult
    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        if let currentURL {
            backStack.append(currentURL)
        }
        revealHistoryLocation(next)
        return true
    }

    /// Applies a history location (forward/back traversal) without touching the
    /// stacks: sets the URL, clears selection, notifies, re-targets, reloads.
    private func revealHistoryLocation(_ url: URL) {
        let standardized = url.standardizedFileURL
        currentURL = standardized
        selection = []
        onCurrentURLChanged?(standardized)

        if isWatching {
            retargetWatcher(to: standardized)
        }
        reload()
    }

    // MARK: - Loading

    /// Re-enumerates the current directory off the main thread. Results are
    /// applied on the main thread only if the user hasn't navigated away in
    /// the meantime (generation counter).
    func reload() {
        generation += 1
        let generation = generation

        guard let url = currentURL else {
            entries = []
            totalCount = 0
            loadError = nil
            isLoading = false
            return
        }

        // Capture the sort + hidden-file settings off the main thread — the
        // dispatched closure reads them off-main, so snapshot them here.
        let sortKey = sortKey
        let sortAscending = sortAscending
        let showsHiddenFiles = AppSettings.shared.showHiddenFiles

        isLoading = true
        let startedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.enumerate(url, sortKey: sortKey, sortAscending: sortAscending, showsHiddenFiles: showsHiddenFiles)
            Task { @MainActor in
                // Stale: the user navigated away while we were enumerating.
                guard generation == self.generation else { return }
                let elapsed = Date().timeIntervalSince(startedAt)
                Log.finder.debug("Enumerated \(url.lastPathComponent, privacy: .public) in \(String(format: "%.1f", elapsed * 1000), privacy: .public) ms")
                self.apply(result)
            }
        }
    }

    private func apply(_ result: Result<[FinderEntry], LoadError>) {
        isLoading = false
        switch result {
        case let .success(newEntries):
            loadError = nil
            entries = newEntries
            totalCount = newEntries.count
        case let .failure(error):
            entries = []
            totalCount = 0
            loadError = error
            Log.finder.error("Enumeration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pure, Sendable in/out — runs entirely off the main thread. One
    /// `contentsOfDirectory` pass fetching every needed key at once; the
    /// result comes back sorted (directories first, then by `sortKey` with the
    /// given direction), packages treated as file-like entries, hidden items
    /// skipped unless `showsHiddenFiles` is true.
    nonisolated static func enumerate(
        _ url: URL,
        sortKey: FinderSortKey = .name,
        sortAscending: Bool = true,
        showsHiddenFiles: Bool = false,
    ) -> Result<[FinderEntry], LoadError> {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .contentTypeKey,
        ]

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsSubdirectoryDescendants],
            )

            var newEntries: [FinderEntry] = []
            newEntries.reserveCapacity(contents.count)

            for itemURL in contents {
                let name = itemURL.lastPathComponent
                if !showsHiddenFiles, name.hasPrefix(".") {
                    continue
                }

                guard let values = try? itemURL.resourceValues(forKeys: keys) else { continue }
                if !showsHiddenFiles, values.isHidden == true {
                    continue
                }

                let isSymlink = values.isSymbolicLink ?? false
                let isPackage = (values.isPackage ?? false)
                    || (values.contentType?.conforms(to: .package) ?? false)
                // Resolve symlinks only for isDirectory classification.
                var isRealDirectory: Bool
                if isSymlink {
                    let resolved = itemURL.resolvingSymlinksInPath()
                    isRealDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                } else {
                    isRealDirectory = values.isDirectory ?? false
                }

                newEntries.append(
                    FinderEntry(
                        url: itemURL.standardizedFileURL,
                        name: name,
                        isDirectory: isRealDirectory && !isPackage,
                        isPackage: isPackage,
                        isSymlink: isSymlink,
                        modifiedAt: values.contentModificationDate,
                        fileSize: isRealDirectory && !isPackage ? nil : Int64(values.fileSize ?? 0),
                        contentTypeIdentifier: values.contentType?.identifier,
                    ),
                )
            }

            // Directories always group first, then files; within each group
            // apply the card's sort column and direction.
            let directories = newEntries.filter(\.isDirectory)
            let files = newEntries.filter { !$0.isDirectory }
            newEntries = Self.sort(directories, key: sortKey, ascending: sortAscending)
                + Self.sort(files, key: sortKey, ascending: sortAscending)
            return .success(newEntries)
        } catch {
            return .failure(Self.loadError(for: error))
        }
    }

    /// Sorts a single group (all directories, or all files) by `sortKey` in the
    /// given direction. Used only for the in-group ordering — directories are
    /// always placed ahead of files by the caller.
    private nonisolated static func sort(_ entries: [FinderEntry], key: FinderSortKey, ascending: Bool) -> [FinderEntry] {
        switch key {
        case .modifiedDate:
            // Nil dates always sort last, independent of direction, so the
            // same stable rule holds for both up and down.
            entries.sorted { lhs, rhs in
                switch (lhs.modifiedAt, rhs.modifiedAt) {
                case let (left?, right?):
                    if left != right {
                        return ascending ? left < right : left > right
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                case (nil, nil):
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
        default:
            entries.sorted { lhs, rhs in
                let order = compare(lhs, rhs, key: key)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }
    }

    /// One-step ordering for name/kind. Returns `.orderedSame` to mean "equal
    /// per this key, fall back to name" — the caller never needs to break the
    /// tie itself.
    private nonisolated static func compare(_ lhs: FinderEntry, _ rhs: FinderEntry, key: FinderSortKey) -> ComparisonResult {
        switch key {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .kind:
            let leftKind = kindLabel(lhs)
            let rightKind = kindLabel(rhs)
            let byKind = leftKind.localizedStandardCompare(rightKind)
            if byKind != .orderedSame {
                return byKind
            }
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedDate:
            // Handled by the dedicated `sort` branch; a fallback for safety.
            return lhs.name.localizedStandardCompare(rhs.name)
        }
    }

    /// The kind group a file belongs to — its lowercased extension ("txt",
    /// "png"), or a placeholder for extension-less files so they group
    /// together and sort after named ones. Directories are split out by the
    /// caller and never reach here in practice.
    private nonisolated static func kindLabel(_ entry: FinderEntry) -> String {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "\u{10FFFF}" : ext
    }

    private nonisolated static func loadError(for error: Error) -> LoadError {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain else {
            return .other(error.localizedDescription)
        }
        switch CocoaError.Code(rawValue: nsError.code) {
        case .fileNoSuchFile, .fileReadNoSuchFile:
            return .notFound
        case .fileReadNoPermission:
            return .notReadable
        default:
            return .other(error.localizedDescription)
        }
    }

    // MARK: - Watching

    /// Installs a vnode watcher on the current directory. One watcher per
    /// visible card, on its current directory only.
    func startWatching() {
        guard !isWatching, let url = currentURL else { return }
        isWatching = true
        watcher = makeWatcher(at: url)
        watcher?.start()
    }

    /// Releases the watcher (closing its file descriptor). Zero idle cost
    /// afterwards — the card re-enumerates once and re-watches when shown.
    func stopWatching() {
        watcher?.stop()
        watcher = nil
        isWatching = false
    }

    private func makeWatcher(at url: URL) -> DirectoryWatcher {
        DirectoryWatcher(url: url, debounce: 0.2) { [weak self] event in
            self?.handleWatchEvent(event)
        }
    }

    /// Moves the watcher to a new directory (navigate-while-watching).
    private func retargetWatcher(to url: URL?) {
        watcher?.stop()
        watcher = nil
        guard let url else { return }
        watcher = makeWatcher(at: url)
        watcher?.start()
    }

    private func handleWatchEvent(_ event: DirectoryWatcher.Event) {
        switch event {
        case .contentsChanged:
            reload()
        case .directoryVanished:
            // Release the fd on the dead directory; `isWatching` stays true so
            // the next navigate re-arms. reload() surfaces `.notFound`.
            watcher?.stop()
            watcher = nil
            reload()
        }
    }

    // MARK: - File operations

    /// Finder-convention non-colliding destination: `Name 2.ext`,
    /// `Name 3.ext`, … until free. Returns `proposed` unchanged when free.
    func uniqueDestinationURL(for proposed: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: proposed.path) else { return proposed }

        let directory = proposed.deletingLastPathComponent()
        let ext = proposed.pathExtension
        let base = ext.isEmpty
            ? proposed.lastPathComponent
            : proposed.deletingPathExtension().lastPathComponent

        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    /// Finder-convention duplicate destination: `Name copy.ext`, then
    /// `Name copy 2.ext`, `Name copy 3.ext`, …
    private func duplicateDestinationURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(ext)"
            return directory.appendingPathComponent(name)
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: candidate("copy").path) {
            return candidate("copy")
        }
        var counter = 2
        while fileManager.fileExists(atPath: candidate("copy \(counter)").path) {
            counter += 1
        }
        return candidate("copy \(counter)")
    }

    /// Renames `url` in place. Empty or "/"-containing names are rejected;
    /// an unchanged name is a no-op returning the original URL; a taken name
    /// throws `.nameTaken` (case-only renames are allowed, Finder-style).
    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FinderOperationError.invalidName
        }

        let destination = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        if destination.path.caseInsensitiveCompare(url.path) == .orderedSame {
            if destination.path == url.path {
                return url // unchanged — no-op
            }
            // Case-only rename — allowed even though the destination "exists".
        } else if FileManager.default.fileExists(atPath: destination.path) {
            throw FinderOperationError.nameTaken
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw FinderOperationError.underlying(error)
        }
        reload()
        return destination
    }

    /// Trashes each item, continuing past failures and throwing the first
    /// error at the end.
    func trash(_ urls: [URL]) throws {
        var firstError: Error?
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        reload()
        if let firstError {
            throw FinderOperationError.underlying(firstError)
        }
    }

    /// Creates a folder in the current directory, falling back to Finder-style
    /// numbered names on collision. Returns the created URL.
    @discardableResult
    func createFolder(named name: String) throws -> URL {
        guard let currentURL else {
            throw FinderOperationError.invalidDestination
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw FinderOperationError.invalidName
        }

        let destination = uniqueDestinationURL(
            for: currentURL.appendingPathComponent(trimmed, isDirectory: true),
        )
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            throw FinderOperationError.underlying(error)
        }
        reload()
        return destination
    }

    /// Duplicates each item as `Name copy.ext`, `Name copy 2.ext`, …
    func duplicate(_ urls: [URL]) throws {
        var firstError: Error?
        for url in urls {
            let source = url.standardizedFileURL
            let destination = duplicateDestinationURL(for: source)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        reload()
        if let firstError {
            throw FinderOperationError.underlying(firstError)
        }
    }

    /// Moves items into `directory`, giving each a unique destination name.
    /// Refuses to move a directory into itself or its descendant
    /// (`.invalidDestination`); moving within the same directory is a silent
    /// no-op for that item.
    func move(_ urls: [URL], into directory: URL) throws {
        try transfer(urls, into: directory, copying: false)
    }

    /// Copies items into `directory`, giving each a unique destination name.
    func copy(_ urls: [URL], into directory: URL) throws {
        try transfer(urls, into: directory, copying: true)
    }

    private func transfer(_ urls: [URL], into directory: URL, copying: Bool) throws {
        let destinationDirectory = directory.standardizedFileURL
        var firstError: Error?

        for url in urls {
            let source = url.standardizedFileURL
            let sourceDirectory = source.deletingLastPathComponent()

            // Source dir == destination dir — no-op, skip silently.
            guard sourceDirectory != destinationDirectory else { continue }

            if !copying, Self.isDirectory(at: source) {
                let sourcePath = source.path
                let destinationPath = destinationDirectory.path
                if destinationPath == sourcePath
                    || destinationPath.hasPrefix(sourcePath + "/")
                {
                    if firstError == nil {
                        firstError = FinderOperationError.invalidDestination
                    }
                    continue
                }
            }

            let destination = uniqueDestinationURL(
                for: destinationDirectory.appendingPathComponent(source.lastPathComponent),
            )
            do {
                if copying {
                    try FileManager.default.copyItem(at: source, to: destination)
                } else {
                    try FileManager.default.moveItem(at: source, to: destination)
                }
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        reload()
        if let firstError {
            throw firstError
        }
    }

    private nonisolated static func isDirectory(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }

    // MARK: - Launch helpers

    static func open(_ urls: [URL]) {
        for url in urls {
            NSWorkspace.shared.open(url)
        }
    }

    static func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func copyPaths(_ urls: [URL]) {
        let paths = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths, forType: .string)
    }
}
