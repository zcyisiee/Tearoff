import AppKit
import UniformTypeIdentifiers

/// Caches file icons for Finder card entries — the 16×16 variant for list rows
/// and the 64×64 variant for icon-grid items — keyed so that per-row rendering
/// never calls `NSWorkspace` on a cache hit. A single cache holds both sizes
/// (the key embeds the size), so switching a card between list and icon view
/// shares namespace but never cross-contaminates the two scales.
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 2048
    }

    /// Returns a `size`×`size`-ready image for the entry. The cached image is a
    /// sized copy so it renders crisp at the requested size. Defaults to 16 for
    /// the list view; the icon view requests 64.
    func icon(for entry: FinderEntry, size: CGFloat = 16) -> NSImage {
        let keyBase: String
        let unsized: NSImage

        if entry.isDirectory {
            // Plain directories and symlinks-to-directories share one icon.
            // (A symlink classified as a directory already resolved its target
            // during enumeration, so `entry.isDirectory` covers both cases.)
            keyBase = "dir"
            unsized = NSWorkspace.shared.icon(for: .folder)
        } else if entry.isPackage {
            // Packages (.app, .rtfd …) have custom per-item icons.
            keyBase = entry.url.path
            unsized = NSWorkspace.shared.icon(forFile: entry.url.path)
        } else if let identifier = entry.contentTypeIdentifier {
            keyBase = identifier
            unsized = NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
        } else {
            // No UTType available — fall back to the file's own icon, cached
            // by extension so siblings share it.
            keyBase = "ext:\(entry.url.pathExtension.lowercased())"
            unsized = NSWorkspace.shared.icon(forFile: entry.url.path)
        }

        let key = "\(Int(size)):\(keyBase)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let sized = unsized.copy() as! NSImage
        sized.size = NSSize(width: size, height: size)
        cache.setObject(sized, forKey: key)
        return sized
    }

    /// Returns a `size`×`size` icon for a bare filesystem URL (used by the
    /// path bar, where segments reference directory URLs rather than
    /// `FinderEntry` values). Cached by URL path so repeated renders don't
    /// round-trip `NSWorkspace`. Destinations are directories, so this uses
    /// `icon(forFile:)`, which honours custom folder icons.
    func icon(forURL url: URL, size: CGFloat = 16) -> NSImage {
        let key = "url:\(Int(size)):\(url.path)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let unsized = url.path == "/"
            ? NSWorkspace.shared.icon(for: .folder)
            : NSWorkspace.shared.icon(forFile: url.path)
        let sized = unsized.copy() as! NSImage
        sized.size = NSSize(width: size, height: size)
        cache.setObject(sized, forKey: key)
        return sized
    }
}
