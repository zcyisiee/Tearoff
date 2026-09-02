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

    // MARK: - Watching

    private(set) var isWatching = false
    private var watcher: DirectoryWatcher?

    // MARK: - Callbacks

    /// Wired by the UI to persist `currentPath` into the sidecar.
    var onCurrentURLChanged: ((URL?) -> Void)?

    /// Bumped on every `reload()`; stale background results are dropped.
    private var generation = 0

    // MARK: - Navigation

    /// Shows `url` (standardized). Clears selection, fires
    /// `onCurrentURLChanged`, reloads, and — when watching — re-targets the
    /// vnode watcher at the new directory.
    func navigate(to url: URL?) {
        let standardized = url?.standardizedFileURL
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
    @discardableResult
    func goUp() -> Bool {
        guard let currentURL else { return false }
        let parent = currentURL.deletingLastPathComponent()
        // At "/" deletingLastPathComponent returns "/" itself.
        guard parent.path != currentURL.path else { return false }
        navigate(to: parent)
        return true
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

        isLoading = true
        let startedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.enumerate(url)
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
    /// result comes back sorted (directories first, then
    /// `localizedStandardCompare`), packages treated as file-like entries,
    /// hidden items skipped.
    nonisolated static func enumerate(_ url: URL) -> Result<[FinderEntry], LoadError> {
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
                if name.hasPrefix(".") {
                    continue
                }

                guard let values = try? itemURL.resourceValues(forKeys: keys) else { continue }
                if values.isHidden == true {
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

            newEntries.sort { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory {
                    return lhs.isDirectory
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return .success(newEntries)
        } catch {
            return .failure(Self.loadError(for: error))
        }
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
