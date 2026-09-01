import AppKit
import Foundation
import ImageIO

/// Shared downsampled-image cache for every markdown image surface (editor,
/// read-only previews, note-card thumbnails). Decodes through ImageIO with a
/// pixel cap so a 48MP photo never materializes as a 48MP bitmap just to be
/// drawn at 650pt — and keys entries by path + mtime so edits on disk
/// invalidate naturally.
///
/// Animated files (GIF/HEVC-sequence) decode to their static first frame;
/// editors don't animate embeds.
final class ImageDecodingCache {
    static let shared = ImageDecodingCache()

    /// Editor/preview ceiling: the engine's fallback max width is 650pt, so a
    /// 2x decode of anything wider than ~1300px is wasted memory.
    static let editorMaxDimension: CGFloat = 1300
    /// Card thumbnails render ≤ ~240pt wide at 2x.
    static let cardMaxDimension: CGFloat = 480

    private let cache = NSCache<NSString, NSImage>()
    private let decodeQueue = DispatchQueue(label: "Tearoff.imageDecode", qos: .utility, attributes: .concurrent)

    private init() {
        cache.countLimit = 220
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    // MARK: - Lookup

    /// Downsampled image for `url`, decoded synchronously on miss.
    /// Returns nil when the file is missing or undecodable.
    func image(at url: URL, maxDimension: CGFloat) -> NSImage? {
        guard let mtime = modificationDate(at: url) else { return nil }
        let key = cacheKey(url: url, mtime: mtime, maxDimension: maxDimension)
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = decode(url: url, maxDimension: maxDimension) else { return nil }
        cache.setObject(image, forKey: key, cost: estimatedBytes(image))
        return image
    }

    /// Warm the cache off the main thread (large-note open path). The cache
    /// write is keyed exactly like `image(at:)`, so later synchronous lookups hit.
    func prefetch(urls: [URL], maxDimension: CGFloat) {
        guard !urls.isEmpty else { return }
        decodeQueue.async { [self] in
            for url in urls {
                guard let mtime = modificationDate(at: url) else { continue }
                let key = cacheKey(url: url, mtime: mtime, maxDimension: maxDimension)
                guard cache.object(forKey: key) == nil else { continue }
                guard let image = decode(url: url, maxDimension: maxDimension) else { continue }
                cache.setObject(image, forKey: key, cost: estimatedBytes(image))
            }
        }
    }

    // MARK: - Decoding

    /// CGImageSource thumbnail decode: one-shot downsample to the longest side
    /// of `maxDimension * 2` (2x screen). First frame only for sequences.
    private func decode(url: URL, maxDimension: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let maxPixels = maxDimension * 2
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        // Report points, not pixels, so the engine's width math stays in pt.
        let scale = 2.0
        image.size = NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale)
        return image
    }

    private func modificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func cacheKey(url: URL, mtime: Date, maxDimension: CGFloat) -> NSString {
        "\(url.path)|\(mtime.timeIntervalSince1970)|\(Int(maxDimension))" as NSString
    }

    private func estimatedBytes(_ image: NSImage) -> Int {
        if let rep = image.representations.first as? NSBitmapImageRep {
            return rep.bytesPerPlane
        }
        return Int(image.size.width * image.size.height * 4)
    }
}
