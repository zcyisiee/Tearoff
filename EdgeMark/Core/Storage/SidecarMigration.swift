import Foundation
import OSLog

/// One-time migration from YAML front matter to the `.edgemark/meta.json` sidecar.
/// Safe to call on every launch — is a no-op when the sidecar already exists.
enum SidecarMigration {
    static func runIfNeeded() {
        guard !SidecarStore.shared.exists else { return }
        Log.storage.info("[Migration] sidecar not found — running YAML → sidecar migration")
        do {
            try run()
            Log.storage.info("[Migration] complete")
        } catch {
            Log.storage.error("[Migration] failed: \(error)")
        }
    }

    // MARK: - Migration

    private static func run() throws {
        let rootURL = FileStorage.rootURL
        let trashURL = FileStorage.trashURL

        var payload = SidecarStore.Payload()

        // --- Active notes ---
        let notePaths = collectMarkdownFiles(in: rootURL, excluding: [trashURL, rootURL.appendingPathComponent(".edgemark")])
        for url in notePaths {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let (metadata, body) = FileStorage.parseFrontMatter(text)
            let relativePath = String(url.path.dropFirst(rootURL.path.count + 1))

            if !metadata.isEmpty {
                let id = metadata["id"].flatMap { UUID(uuidString: $0) } ?? UUID()
                let created = metadata["created"].flatMap { iso.date(from: $0) } ?? fileBirthdate(url)
                let modified = metadata["modified"].flatMap { iso.date(from: $0) } ?? fileMtime(url)
                let tags = parseTagList(metadata["tags"] ?? "")

                payload.notes[id.uuidString] = SidecarStore.NoteEntry(
                    path: relativePath,
                    createdAt: created,
                    modifiedAt: modified,
                    savedAt: modified,
                    tags: tags,
                )

                // Strip YAML from file, restore original timestamps
                let cleaned = body
                let originalMtime = fileMtime(url)
                let originalBirth = fileBirthdate(url)
                try? Data(cleaned.utf8).write(to: url, options: .atomic)
                restoreTimestamps(url: url, mtime: originalMtime, birth: originalBirth)

            } else {
                // File without YAML — treat as external; inject into sidecar
                let id = UUID()
                let created = fileBirthdate(url)
                let modified = fileMtime(url)
                payload.notes[id.uuidString] = SidecarStore.NoteEntry(
                    path: relativePath,
                    createdAt: created,
                    modifiedAt: modified,
                    savedAt: modified,
                    tags: [],
                )
            }
        }

        // --- Trashed notes ---
        let trashContents = (try? FileManager.default.contentsOfDirectory(
            at: trashURL, includingPropertiesForKeys: [.isDirectoryKey],
        )) ?? []

        for url in trashContents {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if !isDir {
                // Individual trashed note: flat .md file directly in .trash/
                guard url.pathExtension == "md", !url.lastPathComponent.hasPrefix(".") else { continue }
                migrateTrashFile(url: url, trashRelativePath: url.lastPathComponent, trashedAt: nil, payload: &payload)

            } else {
                // Trashed folder: directory like .trash/UUID_FolderName/
                let dirname = url.lastPathComponent
                guard !dirname.hasPrefix(".") else { continue }

                // Read .folder.md to get trashedAt and originalPath
                let folderMetaURL = url.appendingPathComponent(".folder.md")
                var folderTrashedAt: Date? = nil
                var folderOriginalPath: String? = nil
                if let metaText = try? String(contentsOf: folderMetaURL, encoding: .utf8) {
                    let (meta, _) = FileStorage.parseFrontMatter(metaText)
                    folderTrashedAt = meta["trashedAt"].flatMap { iso.date(from: $0) }
                    folderOriginalPath = meta["originalPath"]
                }

                // Recurse into all .md files in the folder (skipping hidden)
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles],
                ) else { continue }
                for case let noteURL as URL in enumerator where noteURL.pathExtension == "md" {
                    let relPath = dirname + "/" + String(noteURL.path.dropFirst(url.path.count + 1))
                    migrateTrashFile(
                        url: noteURL,
                        trashRelativePath: relPath,
                        trashedAt: folderTrashedAt,
                        folderOriginalPath: folderOriginalPath,
                        payload: &payload,
                    )
                }
            }
        }

        // Write sidecar atomically
        SidecarStore.shared.data = payload
        try SidecarStore.shared.save()

        let noteCount = payload.notes.count
        let trashCount = payload.trash.count
        Log.storage.info("[Migration] wrote sidecar: \(noteCount) notes, \(trashCount) trashed")
    }

    // MARK: - Trash migration helper

    /// Strip YAML from one trashed .md file and inject a sidecar TrashEntry.
    /// `trashRelativePath` is the path relative to .trash/ (e.g. "UUID_Title.md" or
    /// "UUID_Projects/SubFolder/Note.md").
    private static func migrateTrashFile(
        url: URL,
        trashRelativePath: String,
        trashedAt folderTrashedAt: Date?,
        folderOriginalPath: String? = nil,
        payload: inout SidecarStore.Payload,
    ) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let (metadata, body) = FileStorage.parseFrontMatter(text)
        guard !metadata.isEmpty else { return }

        let id = metadata["id"].flatMap { UUID(uuidString: $0) } ?? UUID()
        let created = metadata["created"].flatMap { iso.date(from: $0) } ?? fileBirthdate(url)
        let modified = metadata["modified"].flatMap { iso.date(from: $0) } ?? fileMtime(url)
        let trashed = metadata["trashed"].flatMap { iso.date(from: $0) } ?? folderTrashedAt ?? fileMtime(url)
        let tags = parseTagList(metadata["tags"] ?? "")

        let originalPath: String
        if let folderBase = folderOriginalPath {
            // Folder-trashed note: strip the "UUID_Folder/" prefix from trashRelativePath
            // to get the sub-path, then prepend the folder's original path from .folder.md.
            // e.g. trashRelativePath "UUID_Projects/Sub/Note.md", folderBase "Work/Projects"
            //      → originalPath "Work/Projects/Sub/Note.md"
            let relParts = trashRelativePath.split(separator: "/", maxSplits: 1)
            let relativeWithinFolder = relParts.count > 1 ? String(relParts[1]) : url.lastPathComponent
            originalPath = folderBase + "/" + relativeWithinFolder
        } else {
            // Individually trashed note: YAML has a `folder:` field (written by trashNote).
            // Strip UUID_ prefix from filename to recover original note filename.
            let folder = metadata["folder"] ?? ""
            let filename = url.lastPathComponent
            let stem = (filename as NSString).deletingPathExtension
            let noteFilename: String
            if let underscoreIdx = stem.firstIndex(of: "_"),
               UUID(uuidString: String(stem[stem.startIndex ..< underscoreIdx])) != nil
            {
                let title = String(stem[stem.index(after: underscoreIdx)...])
                noteFilename = "\(title).md"
            } else {
                noteFilename = filename
            }
            originalPath = folder.isEmpty ? noteFilename : "\(folder)/\(noteFilename)"
        }

        payload.trash[id.uuidString] = SidecarStore.TrashEntry(
            filename: trashRelativePath,
            originalPath: originalPath,
            trashedAt: trashed,
            createdAt: created,
            modifiedAt: modified,
            tags: tags,
        )

        let originalMtime = fileMtime(url)
        let originalBirth = fileBirthdate(url)
        try? Data(body.utf8).write(to: url, options: .atomic)
        restoreTimestamps(url: url, mtime: originalMtime, birth: originalBirth)
    }

    // MARK: - Helpers

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func collectMarkdownFiles(in root: URL, excluding: [URL]) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                // Skip excluded directories
                if excluding.contains(where: { url.path.hasPrefix($0.path) }) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if url.pathExtension == "md" {
                urls.append(url)
            }
        }
        return urls
    }

    private static func parseTagList(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    private static func fileMtime(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? Date()
    }

    private static func fileBirthdate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
    }

    private static func restoreTimestamps(url: URL, mtime: Date, birth: Date) {
        try? FileManager.default.setAttributes(
            [.modificationDate: mtime, .creationDate: birth],
            ofItemAtPath: url.path,
        )
    }
}
