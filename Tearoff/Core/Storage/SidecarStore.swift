import Foundation
import OSLog

/// In-memory store for `.tearoff/meta.json` — the sidecar that holds all
/// note metadata previously embedded in YAML front matter.
final class SidecarStore {
    static let shared = SidecarStore()

    // MARK: - Schema

    struct NoteEntry: Codable {
        var path: String // relative to rootURL, e.g. "folder/Note.md"
        var createdAt: Date
        var modifiedAt: Date
        var savedAt: Date // last Tearoff write — external-change sentinel
        var tags: [String] // TagColor rawValues
        var color: String? // NoteColor rawValue
        var pinned: Bool? // v3 — board pin (nil/false = not pinned)
        var sortOrder: Int? // v3 — manual drag order within a visible list
    }

    struct TrashEntry: Codable {
        var filename: String // bare filename inside .trash/
        var originalPath: String
        var trashedAt: Date
        var createdAt: Date
        var modifiedAt: Date
        var tags: [String]
        var color: String? // NoteColor rawValue
    }

    struct FolderEntry: Codable {
        var color: String // TagColor rawValue
    }

    struct FinderCardEntry: Codable {
        struct FavoriteEntry: Codable {
            var id: String
            var path: String
            var displayName: String
        }

        var title: String? // nil → UI falls back to selected favourite's displayName
        var folder: String // Tearoff folder path, "" = root
        var favorites: [FavoriteEntry]
        var selectedFavoriteID: String?
        var currentPath: String? // absolute path currently browsed
        var pinned: Bool? // v4 — board pin (nil/false = not pinned)
        var sortOrder: Int? // v4 — manual drag order within a visible list
        var color: String? // NoteColor rawValue
        var isExpanded: Bool? // v4 — legacy tall/default flag; migrated into `listHeight` (no longer written)
        var listHeight: Double? // v5 — file list height in points (nil = default 240)
        var viewMode: String? // v6 — file list view: "icon" / "list" (nil = default icon)
        var sortKey: String? // v7 — file list sort column: "name" / "kind" / "modifiedDate" (nil = default name)
        var sortAscending: Bool? // v7 — file list sort direction (nil = default ascending)
        var iconSize: Double? // v8 — icon-grid icon size in points (nil = default 64)
        var chipFontSize: Double? // v8 — favourites chip font size in points (nil = default 11)
        var createdAt: Date
        var modifiedAt: Date
    }

    struct Payload: Codable {
        var version: Int = 4
        var notes: [String: NoteEntry] = [:] // UUID string → NoteEntry
        var trash: [String: TrashEntry] = [:] // UUID string → TrashEntry
        var folders: [String: FolderEntry] = [:] // folder path → FolderEntry
        var finderCards: [String: FinderCardEntry] = [:] // UUID string → FinderCardEntry

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            notes = try c.decodeIfPresent([String: NoteEntry].self, forKey: .notes) ?? [:]
            trash = try c.decodeIfPresent([String: TrashEntry].self, forKey: .trash) ?? [:]
            folders = try c.decodeIfPresent([String: FolderEntry].self, forKey: .folders) ?? [:]
            finderCards = try c.decodeIfPresent([String: FinderCardEntry].self, forKey: .finderCards) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case version, notes, trash, folders, finderCards
        }
    }

    // MARK: - In-memory state

    private(set) var isDirty: Bool = false
    var data = Payload() {
        didSet { isDirty = true }
    }

    var sidecarURL: URL {
        FileStorage.sidecarDirectoryURL(in: FileStorage.rootURL)
            .appendingPathComponent("meta.json")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: sidecarURL.path)
    }

    // MARK: - Load / Save

    private let debouncer = Debouncer(delay: 0.5)

    /// Schedules a debounced save, moving JSON serialization and disk I/O off the main thread.
    func scheduleSave(delay _: TimeInterval = 0.5) {
        debouncer.call { [weak self] in
            guard let self else { return }
            saveInBackground()
        }
    }

    /// Background save: snapshots the payload on the main actor, clears isDirty,
    /// and performs directory creation, JSON encoding, and atomic disk write on a background queue.
    private func saveInBackground() {
        guard isDirty else { return }
        let snapshot = data
        let targetURL = sidecarURL
        isDirty = false

        DispatchQueue.global(qos: .utility).async { [encoder] in
            do {
                let dir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let encoded = try encoder.encode(snapshot)
                try encoded.write(to: targetURL, options: .atomic)
                Log.storage.debug("[Sidecar] asynchronously saved metadata to disk")
            } catch {
                Log.storage.error("[Sidecar] background save failed: \(error)")
            }
        }
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: sidecarURL.path) else {
            // File not found — keep whatever is already in data (e.g. populated by migration).
            return
        }
        let raw = try Data(contentsOf: sidecarURL)
        data = try decoder.decode(Payload.self, from: raw)
        isDirty = false
        let count = data.notes.count
        let version = data.version
        Log.storage.info("[Sidecar] loaded \(count) note entries (v\(version))")
        // v2 → v4: newer fields (pin/order, finder cards) are optional in their
        // entries, so old payloads decode as-is; just stamp the new version back
        // to disk.
        if data.version < 4 {
            data.version = 4
            try? save(force: true)
            Log.storage.info("[Sidecar] migrated payload v\(version) → v4")
        }
    }

    func save(force: Bool = false) throws {
        debouncer.cancel()
        guard isDirty || force else { return }
        let dir = sidecarURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoded = try encoder.encode(data)
        try encoded.write(to: sidecarURL, options: .atomic)
        isDirty = false
    }

    // MARK: - Notes

    func noteEntry(for id: UUID) -> NoteEntry? {
        data.notes[id.uuidString]
    }

    /// Find a note entry by its relative path. O(n) but fine for typical vault sizes.
    func noteEntry(forPath path: String) -> (id: UUID, entry: NoteEntry)? {
        for (uuidStr, entry) in data.notes {
            if entry.path == path, let id = UUID(uuidString: uuidStr) {
                return (id, entry)
            }
        }
        return nil
    }

    func upsertNote(_ entry: NoteEntry, for id: UUID) {
        data.notes[id.uuidString] = entry
    }

    func removeNote(id: UUID) {
        data.notes.removeValue(forKey: id.uuidString)
    }

    // MARK: - Trash

    func trashEntry(for id: UUID) -> TrashEntry? {
        data.trash[id.uuidString]
    }

    func trashEntry(forFilename filename: String) -> (id: UUID, entry: TrashEntry)? {
        for (uuidStr, entry) in data.trash {
            if entry.filename == filename, let id = UUID(uuidString: uuidStr) {
                return (id, entry)
            }
        }
        return nil
    }

    func upsertTrash(_ entry: TrashEntry, for id: UUID) {
        data.trash[id.uuidString] = entry
    }

    func removeTrash(id: UUID) {
        data.trash.removeValue(forKey: id.uuidString)
    }

    // MARK: - Finder cards

    func finderCardEntry(for id: UUID) -> FinderCardEntry? {
        data.finderCards[id.uuidString]
    }

    func upsertFinderCard(_ entry: FinderCardEntry, for id: UUID) {
        data.finderCards[id.uuidString] = entry
    }

    func removeFinderCard(id: UUID) {
        data.finderCards.removeValue(forKey: id.uuidString)
    }

    var allFinderCardEntries: [(id: UUID, entry: FinderCardEntry)] {
        data.finderCards.compactMap { uuidStr, entry in
            guard let id = UUID(uuidString: uuidStr) else { return nil }
            return (id, entry)
        }
    }

    /// Rewrites `finderCards[*].folder` after a folder rename / move. Matches
    /// the renamed folder itself plus every card living in a sub-folder of it.
    func renameFinderCardFolders(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        let oldPrefix = oldPath + "/"
        let newPrefix = newPath + "/"
        for key in Array(data.finderCards.keys) {
            guard var entry = data.finderCards[key] else { continue }
            if entry.folder == oldPath {
                entry.folder = newPath
                data.finderCards[key] = entry
            } else if entry.folder.hasPrefix(oldPrefix) {
                entry.folder = newPrefix + String(entry.folder.dropFirst(oldPrefix.count))
                data.finderCards[key] = entry
            }
        }
    }

    // MARK: - Folders

    func folderEntry(forPath path: String) -> FolderEntry? {
        data.folders[path]
    }

    func upsertFolder(_ entry: FolderEntry, forPath path: String) {
        data.folders[path] = entry
    }

    func removeFolder(path: String) {
        data.folders.removeValue(forKey: path)
    }

    /// Rewrites folder entry keys after a folder rename / move. Migrates the renamed
    /// folder itself plus every nested sub-folder entry that lives under it.
    func renameFolderEntries(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        let oldPrefix = oldPath + "/"
        let newPrefix = newPath + "/"
        for key in Array(data.folders.keys) {
            if key == oldPath {
                if let entry = data.folders.removeValue(forKey: key) {
                    data.folders[newPath] = entry
                }
            } else if key.hasPrefix(oldPrefix) {
                if let entry = data.folders.removeValue(forKey: key) {
                    let newKey = newPrefix + String(key.dropFirst(oldPrefix.count))
                    data.folders[newKey] = entry
                }
            }
        }
    }

    /// Remove folder entries for a folder and all its descendants. Called on permanent delete.
    func removeFolderSubtree(path: String) {
        let prefix = path + "/"
        for key in Array(data.folders.keys) where key == path || key.hasPrefix(prefix) {
            data.folders.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - Payload Lookup Helpers

extension SidecarStore.Payload {
    func noteEntry(forPath path: String) -> (id: UUID, entry: SidecarStore.NoteEntry)? {
        for (uuidStr, entry) in notes {
            if entry.path == path, let id = UUID(uuidString: uuidStr) {
                return (id, entry)
            }
        }
        return nil
    }

    func trashEntry(forFilename filename: String) -> (id: UUID, entry: SidecarStore.TrashEntry)? {
        for (uuidStr, entry) in trash {
            if entry.filename == filename, let id = UUID(uuidString: uuidStr) {
                return (id, entry)
            }
        }
        return nil
    }

    func makeNotesByPath() -> [String: (id: UUID, entry: SidecarStore.NoteEntry)] {
        var dict: [String: (UUID, SidecarStore.NoteEntry)] = [:]
        dict.reserveCapacity(notes.count)
        for (uuidStr, entry) in notes {
            if let id = UUID(uuidString: uuidStr) {
                dict[entry.path] = (id, entry)
            }
        }
        return dict
    }

    func makeTrashByFilename() -> [String: (id: UUID, entry: SidecarStore.TrashEntry)] {
        var dict: [String: (UUID, SidecarStore.TrashEntry)] = [:]
        dict.reserveCapacity(trash.count)
        for (uuidStr, entry) in trash {
            if let id = UUID(uuidString: uuidStr) {
                dict[entry.filename] = (id, entry)
            }
        }
        return dict
    }
}
