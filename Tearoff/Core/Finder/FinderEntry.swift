import Foundation

/// One row in a Finder card's file list. Produced exclusively by
/// `FinderCardBrowser.enumerate` on a background queue — a plain value type,
/// safe to hand across threads.
struct FinderEntry: Identifiable, Hashable, Sendable {
    /// Standardized absolute path — stable per row, used as selection identity.
    var id: String {
        url.path
    }

    let url: URL
    let name: String
    /// True for real folders; false for packages (.app, .rtfd …) so they act
    /// like files (double-click opens, no navigation into).
    let isDirectory: Bool
    let isPackage: Bool
    let isSymlink: Bool
    let modifiedAt: Date?
    /// nil for directories.
    let fileSize: Int64?
    /// `UTType.identifier`, used as the icon cache key when present.
    let contentTypeIdentifier: String?
}
