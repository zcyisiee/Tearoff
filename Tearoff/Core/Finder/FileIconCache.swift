import AppKit
import UniformTypeIdentifiers

/// Caches small (16×16 pt) file icons for Finder card rows, keyed so that
/// per-row rendering never calls `NSWorkspace` on a cache hit.
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 512
    }

    /// Returns a 16×16-ready image for the entry. The cached image is a sized
    /// copy so SwiftUI `Image(nsImage:)` renders crisp at row size.
    func icon(for entry: FinderEntry) -> NSImage {
        let key: NSString
        let unsized: NSImage

        if entry.isDirectory {
            // Plain directories and symlinks-to-directories share one icon.
            // (A symlink classified as a directory already resolved its target
            // during enumeration, so `entry.isDirectory` covers both cases.)
            key = "dir"
            unsized = NSWorkspace.shared.icon(for: .folder)
        } else if entry.isPackage {
            // Packages (.app, .rtfd …) have custom per-item icons.
            key = entry.url.path as NSString
            unsized = NSWorkspace.shared.icon(forFile: entry.url.path)
        } else if let identifier = entry.contentTypeIdentifier {
            key = identifier as NSString
            unsized = NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
        } else {
            // No UTType available — fall back to the file's own icon, cached
            // by extension so siblings share it.
            let ext = entry.url.pathExtension.lowercased()
            key = "ext:\(ext)" as NSString
            unsized = NSWorkspace.shared.icon(forFile: entry.url.path)
        }

        if let cached = cache.object(forKey: key) {
            return cached
        }

        let sized = unsized.copy() as! NSImage
        sized.size = NSSize(width: 16, height: 16)
        cache.setObject(sized, forKey: key)
        return sized
    }
}
