import AppKit
import UniformTypeIdentifiers

/// Caches file icons for Finder card entries — the 16×16 variant for list rows
/// and the 64×64 variant for icon-grid items — keyed so that per-row rendering
/// never calls `NSWorkspace` on a cache hit. Cache misses return an immediate
/// lightweight placeholder while fetching the actual icon asynchronously in
/// the background.
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private static let defaultFolderIcon16: NSImage = {
        let img = NSWorkspace.shared.icon(for: .folder).copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        return img
    }()

    private static let defaultFolderIcon64: NSImage = {
        let img = NSWorkspace.shared.icon(for: .folder).copy() as! NSImage
        img.size = NSSize(width: 64, height: 64)
        return img
    }()

    private static let defaultFileIcon16: NSImage = {
        let img = NSWorkspace.shared.icon(for: .data).copy() as! NSImage
        img.size = NSSize(width: 16, height: 16)
        return img
    }()

    private static let defaultFileIcon64: NSImage = {
        let img = NSWorkspace.shared.icon(for: .data).copy() as! NSImage
        img.size = NSSize(width: 64, height: 64)
        return img
    }()

    private var inFlightKeys = Set<NSString>()
    private var callbacks: [NSString: [(NSImage) -> Void]] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 2048
    }

    private func placeholder(isDirectory: Bool, size: CGFloat) -> NSImage {
        if isDirectory {
            size > 32 ? Self.defaultFolderIcon64 : Self.defaultFolderIcon16
        } else {
            size > 32 ? Self.defaultFileIcon64 : Self.defaultFileIcon16
        }
    }

    private func cacheKey(for entry: FinderEntry, size: CGFloat) -> (key: NSString, keyBase: String) {
        let keyBase: String = if entry.isDirectory {
            "dir"
        } else if entry.isPackage {
            entry.url.path
        } else if let identifier = entry.contentTypeIdentifier {
            identifier
        } else {
            "ext:\(entry.url.pathExtension.lowercased())"
        }
        let key = "\(Int(size)):\(keyBase)" as NSString
        return (key, keyBase)
    }

    /// Returns a `size`×`size`-ready image for the entry. If the image is cached,
    /// it is returned immediately. If not, a fast placeholder is returned and
    /// `onLoaded` is invoked on the main thread once the real icon finishes loading off-main.
    func icon(for entry: FinderEntry, size: CGFloat = 16, onLoaded: ((NSImage) -> Void)? = nil) -> NSImage {
        let (key, _) = cacheKey(for: entry, size: size)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        enqueueAsyncLoad(key: key, size: size, onLoaded: onLoaded) {
            let unsized: NSImage = if entry.isDirectory {
                NSWorkspace.shared.icon(for: .folder)
            } else if entry.isPackage {
                NSWorkspace.shared.icon(forFile: entry.url.path)
            } else if let identifier = entry.contentTypeIdentifier {
                NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
            } else {
                NSWorkspace.shared.icon(forFile: entry.url.path)
            }
            return unsized
        }

        return placeholder(isDirectory: entry.isDirectory, size: size)
    }

    /// Returns a `size`×`size` icon for a bare filesystem URL.
    /// If cached, returns immediately; otherwise returns a placeholder and loads asynchronously.
    func icon(forURL url: URL, size: CGFloat = 16, onLoaded: ((NSImage) -> Void)? = nil) -> NSImage {
        let key = "url:\(Int(size)):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        enqueueAsyncLoad(key: key, size: size, onLoaded: onLoaded) {
            url.path == "/"
                ? NSWorkspace.shared.icon(for: .folder)
                : NSWorkspace.shared.icon(forFile: url.path)
        }

        return placeholder(isDirectory: true, size: size)
    }

    private func enqueueAsyncLoad(
        key: NSString,
        size: CGFloat,
        onLoaded: ((NSImage) -> Void)?,
        fetchUnsized: @escaping () -> NSImage,
    ) {
        lock.lock()
        if let onLoaded {
            callbacks[key, default: []].append(onLoaded)
        }
        guard !inFlightKeys.contains(key) else {
            lock.unlock()
            return
        }
        inFlightKeys.insert(key)
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let unsized = fetchUnsized()
            let sized = unsized.copy() as! NSImage
            sized.size = NSSize(width: size, height: size)

            cache.setObject(sized, forKey: key)

            lock.lock()
            inFlightKeys.remove(key)
            let pending = callbacks.removeValue(forKey: key) ?? []
            lock.unlock()

            if !pending.isEmpty {
                DispatchQueue.main.async {
                    for cb in pending {
                        cb(sized)
                    }
                }
            }
        }
    }
}
