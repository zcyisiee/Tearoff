import Foundation
import OSLog

// MARK: - DailyNoteService

/// All logic specific to the Daily Notes feature.
///
/// Responsibilities:
/// - Canonical date string for today (`yyyy-MM-dd`).
/// - Recognising whether a note is a daily note (folder == "Daily", title matches `^\d{4}-\d{2}-\d{2}$`).
/// - Archiving past dailies from `Daily/` → `Daily/Archive/`.
/// - Opening or creating today's daily note via `NoteStore`.
/// - One-time migration of root-level date-titled notes into `Daily/` or `Daily/Archive/`.
enum DailyNoteService {
    // MARK: - Constants

    static let dailyFolder = "Daily"
    static let archiveFolder = "Daily/Archive"

    // MARK: - Date helpers

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// ISO date string for `date` (default: today).
    static func dateString(for date: Date = Date()) -> String {
        isoFormatter.string(from: date)
    }

    /// Returns the Date parsed from an ISO `yyyy-MM-dd` title, or nil.
    static func date(fromTitle title: String) -> Date? {
        guard isISODateTitle(title) else { return nil }
        return isoFormatter.date(from: title)
    }

    /// True when `title` exactly matches `\d{4}-\d{2}-\d{2}`.
    static func isISODateTitle(_ title: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}$"#
        return (try? NSRegularExpression(pattern: pattern))
            .map { $0.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil }
            ?? false
    }

    // MARK: - Recognition

    /// True when `note` is a daily note (lives in "Daily", ISO date title).
    static func isDaily(_ note: some NoteIdentity) -> Bool {
        note.folder == dailyFolder && isISODateTitle(note.title)
    }

    /// True when `note` is today's daily note.
    static func isTodayDaily(_ note: some NoteIdentity) -> Bool {
        isDaily(note) && note.title == dateString()
    }

    /// True when `note` is a past daily (daily, but not today).
    static func isPastDaily(_ note: some NoteIdentity) -> Bool {
        isDaily(note) && note.title != dateString()
    }

    // MARK: - Open / Create

    /// Focus today's daily note, creating it if it doesn't exist.
    ///
    /// The note surfaces in the root board's Daily zone in in-place (temporary)
    /// edit mode — the lightweight path the user expects from a hotkey. The
    /// board consumes `pendingDailyNote` (mirroring the `pendingNewNote` flow),
    /// because only the board can drive its own inline-edit and scroll state.
    @MainActor
    static func openOrCreateToday(in noteStore: NoteStore) {
        // Run archival first — moves stale dailies before we look for today's.
        archivePastDailies(in: noteStore)

        let todayTitle = dateString()
        let exists = noteStore.notes.contains {
            $0.folder == dailyFolder && $0.title == todayTitle
        }
        if !exists {
            createToday(in: noteStore, title: todayTitle)
        }

        // Hand off to the board: close any open editor, go home, then enter
        // in-place edit on today's daily card.
        noteStore.pendingDailyNote = true
    }

    /// Create today's daily note file in `Daily/` and insert it into the store.
    @MainActor
    private static func createToday(in noteStore: NoteStore, title: String) {
        let content = "# \(title)\n\n"
        let now = Date()
        var note = Note(
            id: UUID(),
            title: title,
            content: content,
            createdAt: now,
            modifiedAt: now,
            folder: dailyFolder,
        )
        do {
            let result = try FileStorage.writeNote(note)
            note.savedFilename = result.filename
            note.savedAt = result.savedAt
        } catch {
            Log.storage.error("[DailyNoteService] writeNote failed — \(error)")
        }
        noteStore.notes.append(note)
        noteStore.refreshFolders()
    }

    /// Today's daily note, if it exists in the store.
    static func todayNote(in noteStore: NoteStore) -> Note? {
        let todayTitle = dateString()
        return noteStore.notes.first {
            $0.folder == dailyFolder && $0.title == todayTitle
        }
    }

    // MARK: - Archival

    /// Move all `Daily/` notes whose title date < today into `Daily/Archive/`.
    /// Safe to call repeatedly (idempotent). Called at app launch, on shortcut press,
    /// and when the panel activates on a new calendar day.
    @MainActor
    static func archivePastDailies(in noteStore: NoteStore) {
        let today = dateString()
        let toArchive = noteStore.notes.filter {
            $0.folder == dailyFolder
                && isISODateTitle($0.title)
                && $0.title < today // ISO strings compare lexicographically
        }
        for note in toArchive {
            guard let index = noteStore.notes.firstIndex(where: { $0.id == note.id }) else { continue }
            do {
                let movedSavedAt = try FileStorage.moveNote(note, toFolder: archiveFolder, withFilename: nil)
                noteStore.notes[index].folder = archiveFolder
                noteStore.notes[index].savedAt = movedSavedAt
            } catch {
                Log.storage.error("[DailyNoteService] archive failed for '\(note.title, privacy: .public)' — \(error)")
            }
        }
        if !toArchive.isEmpty {
            noteStore.refreshFolders()
        }
    }

    // MARK: - Migration

    private static let migrationKey = "dailyMigrationDone_v1"

    /// One-time migration: scan root notes whose titles look like dates
    /// (`\d{4}-\d{1,2}-\d{1,2}`) and move them into `Daily/` or `Daily/Archive/`.
    /// Guarded by a UserDefaults flag so it only runs once.
    @MainActor
    static func migrateIfNeeded(in noteStore: NoteStore) {
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationKey) }

        let today = dateString()
        // Match both zero-padded and non-zero-padded date formats.
        let loose = #"^\d{4}-\d{1,2}-\d{1,2}$"#
        guard let regex = try? NSRegularExpression(pattern: loose) else { return }

        let candidates = noteStore.notes.filter { note in
            guard note.folder.isEmpty else { return false }
            let r = NSRange(note.title.startIndex..., in: note.title)
            return regex.firstMatch(in: note.title, range: r) != nil
        }

        for note in candidates {
            guard let index = noteStore.notes.firstIndex(where: { $0.id == note.id }) else { continue }

            // Normalise to ISO format (zero-pad month/day).
            let isoTitle = normaliseToISO(note.title) ?? note.title
            let targetFolder = isoTitle < today ? archiveFolder : dailyFolder

            // Rename the note title if it wasn't already ISO-padded.
            if isoTitle != note.title {
                noteStore.notes[index].title = isoTitle
                // Rewrite the heading line too.
                var lines = noteStore.notes[index].content.components(separatedBy: "\n")
                if let headingIdx = lines.firstIndex(where: { $0.hasPrefix("#") }) {
                    let prefix = String(lines[headingIdx].prefix(while: { $0 == "#" }))
                    lines[headingIdx] = "\(prefix) \(isoTitle)"
                    noteStore.notes[index].content = lines.joined(separator: "\n")
                }
                noteStore.notes[index].modifiedAt = Date()
            }

            do {
                let movedSavedAt = try FileStorage.moveNote(noteStore.notes[index], toFolder: targetFolder, withFilename: nil)
                noteStore.notes[index].folder = targetFolder
                noteStore.notes[index].savedAt = movedSavedAt
                Log.storage.info("[DailyNoteService] migrated '\(isoTitle, privacy: .public)' → \(targetFolder, privacy: .public)")
            } catch {
                Log.storage.error("[DailyNoteService] migration move failed for '\(isoTitle, privacy: .public)' — \(error)")
            }
        }

        if !candidates.isEmpty {
            noteStore.refreshFolders()
        }
    }

    /// Converts a loose `YYYY-M-D` or `YYYY-MM-D` style title into the canonical
    /// `YYYY-MM-DD` form, returning nil if parsing fails.
    private static func normaliseToISO(_ title: String) -> String? {
        let parts = title.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

// MARK: - NoteIdentity

/// Minimal interface for DailyNoteService recognition helpers so they can work
/// on any type that exposes folder and title (Note, lightweight previews, etc.).
protocol NoteIdentity {
    var folder: String { get }
    var title: String { get }
}

extension Note: NoteIdentity {}
