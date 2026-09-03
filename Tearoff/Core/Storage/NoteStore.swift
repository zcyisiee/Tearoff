import Foundation
import OSLog
import SwiftUI

extension Notification.Name {
    /// Request to close the full editor through the animated path — the board
    /// shrinks the editor box back into its note card before the store closes
    /// the note. Posted by Escape handling (`SidePanelController`), which lives
    /// below the SwiftUI layer and can't drive the morph itself.
    static let editorCloseRequested = Notification.Name("Tearoff.editorCloseRequested")
}

@Observable
final class NoteStore {
    // MARK: - State

    var notes: [Note] = []
    /// Finder cards share the board stream with notes — same folder tab
    /// membership, pin-first order, and manual `sortOrder` identity space.
    var finderCards: [FinderCard] = []
    var trashedNotes: [Note] = []
    var trashedFolders: [TrashedFolder] = []
    var folders: [Folder] = []
    var selectedFolder: Folder?
    var selectedNote: Note?
    var showTrash = false

    /// Settings page route state. When true the board shows the in-panel
    /// settings page; Escape (or the back button) returns to the browse state.
    var showSettings = false

    /// Set at launch when "Choose on launch" is on and ≥2 storage roots are configured.
    /// While true, the panel shows a non-blocking storage-root picker instead of the
    /// note list; picking a root clears this and switches (temporary) to that root.
    var awaitingRootChoice: Bool = false

    /// Bumped on every storage-root switch. List views animate row changes off this
    /// (`.animation(value:)`) so the note/folder rows fade out and in while the panel
    /// chrome (card, header) stays stable — content fades, not the panel.
    var rootSwitchToken: Int = 0

    // MARK: - List Selection (multi-select)

    /// Identity for a row in the note list. Notes and Finder cards share a UUID
    /// identity space (the board keys card frames and drag sessions by UUID);
    /// folders use path.
    enum SelectableID: Hashable {
        case note(UUID)
        case finderCard(UUID)
        case folder(String)
    }

    /// What's selected in the visible list — distinct from `selectedNote` /
    /// `selectedFolder` (which represent what's *open*). Empty after navigation.
    var selection: Set<SelectableID> = []

    /// ID of note whose title is currently selected on the board card.
    var selectedTitleNoteID: UUID?

    /// True when the expanded editor's header title is currently selected.
    var isEditorTitleSelected: Bool = false

    /// Anchor row for ⇧-click range selection.
    private var selectionAnchor: SelectableID?

    /// The "active end" of a shift-extended range — walks with ⇧-arrow / ⇧-click
    /// while `selectionAnchor` stays put. Equals anchor for non-extended selections.
    private var selectionExtensionEnd: SelectableID?

    // MARK: - Navigation Direction

    enum NavigationDirection {
        case forward
        case backward
        case overlay
        case none
    }

    var navigationDirection: NavigationDirection = .none

    /// Pending note moves that have name conflicts at the destination.
    /// The first element is the active conflict shown by the UI; remaining elements
    /// queue up so a batch move surfaces every collision sequentially instead of dropping
    /// all but the last.
    struct PendingNoteMoveConflict {
        let noteID: UUID
        let targetFolder: String
    }

    var pendingNoteMoveConflicts: [PendingNoteMoveConflict] = []

    /// Pending folder moves that have name conflicts at the destination. Same queue semantics as notes.
    struct PendingFolderMoveConflict {
        let folderName: String
        let targetParent: String
    }

    var pendingFolderMoveConflicts: [PendingFolderMoveConflict] = []

    /// Conflict when both Tearoff and an external editor modified the same open note.
    struct PendingExternalChange {
        let noteID: UUID
        let diskContent: String
        let diskDate: Date
        let diskTags: [TagColor]
    }

    var pendingExternalChange: PendingExternalChange?

    /// Called when an open note is auto-synced from disk — pushes new content directly to the editor.
    var onNeedEditorReload: ((String) -> Void)?

    /// Cached set of folder paths that exist on disk (including empty folders).
    /// Updated only by disk-mutating folder operations — avoids a full filesystem
    /// enumeration on every `refreshFolders()` call.
    private var diskFolderNames: Set<String> = []

    /// Set to true to trigger the search bar on HomeFolderView after navigating back.
    var pendingSearchOnHome = false
    /// Set to true by the shortcut handler to trigger "new folder" in the currently visible list view.
    var pendingNewFolder = false
    /// Set to true by the shortcut handler to trigger note creation in the board view.
    var pendingNewNote = false
    /// Set to true by the ⌘F shortcut handler when a note is open — consumed by EditorScreen
    /// to show the in-editor find bar.
    var pendingEditorFind: Bool = false

    /// Folder to return to when the user dismisses search (set when search is triggered from a subfolder).
    var searchReturnFolder: Folder?

    /// Active tag filter applied within the search experience. Session-only; cleared on dismiss.
    var activeTagFilter: Set<TagColor> = []

    /// Cached set of tag colors in use across all active notes. Avoids an O(N×T)
    /// recomputation on every TagFilterBar render. Updated by the handful of
    /// mutators that touch tags.
    private(set) var allUsedTags: Set<TagColor> = []

    /// Timestamp of recent rename operations per note. Used to guard `updateContent`
    /// against stale editor debounced callbacks reverting the new title.
    private var recentlyRenamedNotes: [UUID: Date] = [:]

    private func recomputeAllUsedTags() {
        allUsedTags = Set(notes.flatMap(\.tags))
    }

    /// Notes filtered by selected folder (unsorted — views apply sort via `sortedNotes`).
    var filteredNotes: [Note] {
        if let folder = selectedFolder {
            notes.filter { $0.folder == folder.name }
        } else {
            notes
        }
    }

    /// Finder cards under the same folder filter as `filteredNotes` (unsorted).
    var filteredFinderCards: [FinderCard] {
        if let folder = selectedFolder {
            finderCards.filter { $0.folder == folder.name }
        } else {
            finderCards
        }
    }

    /// The Finder card whose embedded file list currently has keyboard focus.
    /// The panel's ⌘⇧N handler routes shortcuts to it instead of the board.
    var focusedFinderCardID: UUID?

    // MARK: - Sorting

    /// Pinned notes always float to the top; within each group the requested
    /// sort applies. `.manual` orders by the drag-assigned `sortOrder` (notes
    /// without one fall back to their title) and ignores `ascending`.
    func sortedNotes(_ notes: [Note], by sortBy: AppSettings.SortBy, ascending: Bool) -> [Note] {
        sortedBoardItems(notes: notes, finderCards: [], by: sortBy, ascending: ascending).compactMap(\.note)
    }

    /// Interleave notes and Finder cards into one ordered stream using the
    /// shared board ordering — the single source of truth both `sortedNotes`
    /// and the board's keyboard/drag order go through.
    func sortedBoardItems(notes: [Note], finderCards: [FinderCard], by sortBy: AppSettings.SortBy, ascending: Bool) -> [BoardItem] {
        let items = notes.map(BoardItem.note) + finderCards.map(BoardItem.finder)
        let ordered = items.sorted { a, b in
            if sortBy == .manual {
                switch (a.sortOrder, b.sortOrder) {
                case let (lhs?, rhs?):
                    if lhs != rhs {
                        return lhs < rhs
                    }
                    return a.sortTitle.localizedCaseInsensitiveCompare(b.sortTitle) == .orderedAscending
                case (nil, _?):
                    return false // unpositioned items sink below positioned ones
                case (_?, nil):
                    return true
                case (nil, nil):
                    return a.sortTitle.localizedCaseInsensitiveCompare(b.sortTitle) == .orderedAscending
                }
            }
            let result: Bool = switch sortBy {
            case .name:
                a.sortTitle.localizedCaseInsensitiveCompare(b.sortTitle) == .orderedAscending
            case .dateModified:
                a.modifiedAt < b.modifiedAt
            case .dateCreated:
                a.createdAt < b.createdAt
            case .manual:
                false
            }
            return ascending ? result : !result
        }
        return ordered.filter(\.pinned) + ordered.filter { !$0.pinned }
    }

    func sortedFolders(_ folders: [Folder], by sortBy: AppSettings.SortBy, ascending: Bool) -> [Folder] {
        // Manual order only applies to notes; folders fall back to modification date.
        let effective: AppSettings.SortBy = sortBy == .manual ? .dateModified : sortBy
        return folders.sorted { a, b in
            let result: Bool = switch effective {
            case .name:
                a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .dateModified:
                // nil dates (empty folders) sort to end
                switch (a.latestModifiedAt, b.latestModifiedAt) {
                case let (aDate?, bDate?): aDate < bDate
                case (nil, _): false
                case (_, nil): true
                }
            case .dateCreated:
                switch (a.earliestCreatedAt, b.earliestCreatedAt) {
                case let (aDate?, bDate?): aDate < bDate
                case (nil, _): false
                case (_, nil): true
                }
            case .manual:
                false
            }
            return ascending ? result : !result
        }
    }

    // MARK: - Animated Navigation

    func navigateToHome() {
        Log.navigation.debug("[NoteStore] navigateToHome")
        navigationDirection = .backward
        clearSelection()
        withAnimation(DesignToken.Motion.morph) {
            selectedNote = nil
            selectedFolder = nil
        }
    }

    func navigateToFolder(_ folder: Folder) {
        let name = folder.name
        Log.navigation.debug("[NoteStore] navigateToFolder — \(name, privacy: .public)")
        navigationDirection = .forward
        clearSelection()
        withAnimation(DesignToken.Motion.morph) {
            selectedFolder = folder
        }
    }

    func navigateToSubfolder(_ folder: Folder) {
        let name = folder.name
        Log.navigation.debug("[NoteStore] navigateToSubfolder — \(name, privacy: .public)")
        navigationDirection = .forward
        clearSelection()
        withAnimation(DesignToken.Motion.morph) {
            selectedFolder = folder
        }
    }

    func navigateBack() {
        let from = selectedNote?.title ?? selectedFolder?.name ?? "home"
        Log.navigation.debug("[NoteStore] navigateBack from \(from, privacy: .public)")
        navigationDirection = .backward
        clearSelection()
        if selectedNote != nil {
            saveDirtyNotes()
            withAnimation(DesignToken.Motion.morph) {
                selectedNote = nil
            }
        } else if let parent = selectedFolder?.parentPath, !parent.isEmpty {
            withAnimation(DesignToken.Motion.morph) {
                selectedFolder = folders.first { $0.name == parent }
                    ?? Folder(name: parent, noteCount: 0)
            }
        } else {
            withAnimation(DesignToken.Motion.morph) {
                selectedFolder = nil
            }
        }
    }

    func openNote(_ note: Note) {
        let title = note.title
        Log.navigation.debug("[NoteStore] openNote — \(title, privacy: .public)")
        navigationDirection = .forward
        selectedTitleNoteID = nil
        isEditorTitleSelected = false
        // The collapsed card hides behind the morphing editor box, so clearing
        // the in-place edit here never renders as a visible small-card bounce.
        withAnimation(DesignToken.Motion.morph) {
            clearSelection()
            inlineEditingNoteID = nil
            selectedNote = note
        }
    }

    func openNoteFromSearch(_ note: Note) {
        let title = note.title
        let folder = note.folder
        Log.navigation.debug("[NoteStore] openNoteFromSearch — \(title, privacy: .public) in \(folder, privacy: .public)")
        if !note.folder.isEmpty {
            selectedFolder = Folder(name: note.folder, noteCount: 0)
        }
        navigationDirection = .forward
        selectedTitleNoteID = nil
        isEditorTitleSelected = false
        withAnimation(DesignToken.Motion.morph) {
            selectedNote = note
        }
    }

    func closeNote() {
        let title = selectedNote?.title ?? "nil"
        Log.navigation.debug("[NoteStore] closeNote — \(title, privacy: .public)")
        navigationDirection = .backward
        saveDirtyNotes()
        isEditorTitleSelected = false
        selectedTitleNoteID = nil
        withAnimation(DesignToken.Motion.morph) {
            selectedNote = nil
        }
    }

    /// Notes in the current folder only (not descendants). Root = notes with empty folder.
    private var currentFolderNotes: [Note] {
        if let folder = selectedFolder {
            notes.filter { $0.folder == folder.name }
        } else {
            notes.filter(\.folder.isEmpty)
        }
    }

    func navigateToNextNote(sortedBy appSettings: AppSettings) {
        guard let current = selectedNote else { return }
        let sorted = sortedNotes(currentFolderNotes, by: appSettings.sortBy, ascending: appSettings.sortAscending)
        guard let index = sorted.firstIndex(where: { $0.id == current.id }),
              index + 1 < sorted.count
        else { return }
        let next = sorted[index + 1]
        let title = next.title
        Log.navigation.debug("[NoteStore] navigateToNextNote — \(title, privacy: .public)")
        saveDirtyNotes()
        navigationDirection = .forward
        withAnimation(DesignToken.Motion.morph) {
            selectedNote = next
        }
    }

    func navigateToPreviousNote(sortedBy appSettings: AppSettings) {
        guard let current = selectedNote else { return }
        let sorted = sortedNotes(currentFolderNotes, by: appSettings.sortBy, ascending: appSettings.sortAscending)
        guard let index = sorted.firstIndex(where: { $0.id == current.id }),
              index > 0
        else { return }
        let prev = sorted[index - 1]
        let title = prev.title
        Log.navigation.debug("[NoteStore] navigateToPreviousNote — \(title, privacy: .public)")
        saveDirtyNotes()
        navigationDirection = .backward
        withAnimation(DesignToken.Motion.morph) {
            selectedNote = prev
        }
    }

    func openTrash() {
        Log.navigation.debug("[NoteStore] openTrash")
        navigationDirection = .overlay
        clearSelection()
        withAnimation(DesignToken.Motion.morph) {
            showTrash = true
        }
    }

    func closeTrash() {
        Log.navigation.debug("[NoteStore] closeTrash")
        navigationDirection = .overlay
        clearSelection()
        withAnimation(DesignToken.Motion.morph) {
            showTrash = false
        }
    }

    // MARK: - Dirty Tracking

    private var dirtyNoteIDs: Set<UUID> = []

    // MARK: - Lifecycle

    func loadFromDisk() {
        do {
            let loaded = try FileStorage.loadAllNotes()
            // Auto-correct duplicate UUIDs — reassign a new UUID to any duplicate and re-save
            // to disk so both notes survive (e.g. user copied a .md file in Finder)
            var seen = Set<UUID>()
            notes = loaded.map { note in
                guard seen.insert(note.id).inserted else {
                    let newID = UUID()
                    Log.storage.warning("[NoteStore] duplicate UUID '\(note.id)' for '\(note.title, privacy: .public)' — reassigning to \(newID)")
                    let fixed = Note(
                        id: newID,
                        title: note.title,
                        content: note.content,
                        createdAt: note.createdAt,
                        modifiedAt: note.modifiedAt,
                        savedAt: note.savedAt,
                        folder: note.folder,
                        trashedAt: note.trashedAt,
                        savedFilename: note.savedFilename,
                    )
                    do {
                        try FileStorage.writeNote(fixed) // return value intentionally discarded (dedup path)
                    } catch {
                        Log.storage.error("[NoteStore] failed to re-save deduped note — \(error)")
                    }
                    return fixed
                }
                return note
            }
            trashedNotes = try FileStorage.loadTrashedNotes()
            trashedFolders = try FileStorage.loadTrashedFolders()
            autoPurgeExpiredTrash()
            diskFolderNames = Set((try? FileStorage.discoverFolders()) ?? [])
            refreshFolders()
            finderCards = SidecarStore.shared.allFinderCardEntries
                .map { FinderCard(id: $0.id, entry: $0.entry) }
                .sorted { $0.createdAt < $1.createdAt }
            focusedFinderCardID = nil
            let noteCount = notes.count
            let cardCount = finderCards.count
            let trashCount = trashedNotes.count + trashedFolders.count
            Log.storage.info("[NoteStore] loaded \(noteCount) notes, \(cardCount) Finder cards, \(trashCount) trashed items")
        } catch {
            Log.storage.error("[NoteStore] loadFromDisk failed — \(error)")
        }
    }

    /// Called on every app foreground transition. Checks each note for external modifications
    /// and reloads or prompts based on dirty state.
    func checkForExternalChanges() {
        let count = notes.count
        Log.storage.debug("[ExternalSync] checking \(count) notes")
        for i in notes.indices {
            let note = notes[i]
            guard let diskDate = FileStorage.modificationDate(for: note) else {
                let t = note.title
                Log.storage.debug("[ExternalSync] '\(t, privacy: .public)' — file not found on disk")
                continue
            }
            // Compare file mtime against savedAt (last time Tearoff wrote this file).
            // Using savedAt instead of modifiedAt prevents false positives from auto-saves
            // that write the file without changing content.
            let diff = diskDate.timeIntervalSince(note.savedAt)
            let t = note.title
            Log.storage.debug("[ExternalSync] '\(t, privacy: .public)' — diff: \(String(format: "%.3f", diff))s")
            guard diff > 1 else { continue }

            let noteID = notes[i].id
            let isOpen = selectedNote?.id == noteID
            let isDirty = dirtyNoteIDs.contains(noteID)

            guard let reloaded = FileStorage.reloadContent(for: notes[i]) else { continue }
            let diskContent = reloaded.content
            let diskModifiedAt = reloaded.modifiedAt
            let diskSavedAt = reloaded.savedAt
            let diskTags = reloaded.tags

            let title = notes[i].title
            if isOpen, isDirty {
                // Both Tearoff and external have changes — prompt user
                Log.storage.info("[NoteStore] external conflict on open note '\(title, privacy: .public)'")
                pendingExternalChange = PendingExternalChange(noteID: noteID, diskContent: diskContent, diskDate: diskDate, diskTags: diskTags)
            } else {
                // Safe to auto-reload: note not open, or open but no Tearoff edits
                Log.storage.info("[NoteStore] auto-syncing '\(title, privacy: .public)' from external change")
                notes[i].content = diskContent
                notes[i].modifiedAt = diskModifiedAt
                notes[i].savedAt = diskSavedAt
                notes[i].tags = diskTags
                dirtyNoteIDs.remove(noteID)
                // Persist updated savedAt to sidecar so the watcher doesn't re-fire on next launch
                if var entry = SidecarStore.shared.noteEntry(for: noteID) {
                    entry.savedAt = diskSavedAt
                    entry.modifiedAt = diskModifiedAt
                    entry.tags = diskTags.map(\.rawValue)
                    SidecarStore.shared.upsertNote(entry, for: noteID)
                    try? SidecarStore.shared.save()
                }
                if isOpen {
                    selectedNote = notes[i]
                    onNeedEditorReload?(diskContent)
                }
                recomputeAllUsedTags()
            }
        }
    }

    /// Resolve external conflict: keep Tearoff edits (discard disk) or reload from disk.
    func resolveExternalChange(keepTearoffEdits: Bool) {
        guard let conflict = pendingExternalChange else { return }
        pendingExternalChange = nil
        if !keepTearoffEdits,
           let i = notes.firstIndex(where: { $0.id == conflict.noteID })
        {
            notes[i].content = conflict.diskContent
            notes[i].modifiedAt = conflict.diskDate
            notes[i].savedAt = conflict.diskDate
            notes[i].tags = conflict.diskTags
            dirtyNoteIDs.remove(conflict.noteID)
            // Persist updated savedAt + tags so the watcher doesn't re-fire on next launch
            if var entry = SidecarStore.shared.noteEntry(for: conflict.noteID) {
                entry.savedAt = conflict.diskDate
                entry.modifiedAt = conflict.diskDate
                entry.tags = conflict.diskTags.map(\.rawValue)
                SidecarStore.shared.upsertNote(entry, for: conflict.noteID)
                try? SidecarStore.shared.save()
            }
            recomputeAllUsedTags()
            if selectedNote?.id == conflict.noteID {
                selectedNote = notes[i]
                onNeedEditorReload?(conflict.diskContent)
            }
        }
    }

    // MARK: - Duplicate Detection

    /// Whether a note title already exists in the given folder (case-insensitive filename match).
    func noteTitleExists(_ title: String, in folder: String, excluding noteID: UUID? = nil) -> Bool {
        let sanitized = FileStorage.sanitizeForFilename(title)
        return notes.contains { note in
            note.id != noteID
                && note.folder == folder
                && FileStorage.sanitizeForFilename(note.title).caseInsensitiveCompare(sanitized) == .orderedSame
        }
    }

    /// Effective on-disk filename for a note (savedFilename if set, else title-derived).
    /// `noteTitleExists` is purely title-based and misses the case where a title was
    /// renamed in memory but `savedFilename` still points at the old on-disk name — or
    /// where an orphan `.md` file exists in the destination directory. The move path
    /// must use this helper to avoid the OS-level NSCocoaErrorDomain 516 leaking through.
    private func noteFilenameWouldCollide(_ filename: String, in folder: String, excluding noteID: UUID? = nil) -> Bool {
        let collidesInMemory = notes.contains { other in
            other.id != noteID
                && other.folder == folder
                && (other.savedFilename ?? other.filename).caseInsensitiveCompare(filename) == .orderedSame
        }
        if collidesInMemory {
            return true
        }
        let destURL = folder.isEmpty
            ? FileStorage.rootURL.appendingPathComponent(filename)
            : FileStorage.rootURL.appendingPathComponent(folder).appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: destURL.path)
    }

    /// Symmetric helper for folder moves — catches in-memory sibling clashes plus
    /// orphan directories on disk that aren't tracked in `folders`. Without the
    /// filesystem check, `moveFolder` would skip the conflict alert and fall through
    /// to `FileStorage.moveFolder`, where macOS surfaces NSCocoaErrorDomain 516.
    private func folderWouldCollide(displayName: String, in newParent: String, excluding folderPath: String? = nil) -> Bool {
        let siblings = newParent.isEmpty
            ? folders.filter(\.isTopLevel)
            : childFolders(of: newParent)
        let collidesInMemory = siblings.contains { sib in
            sib.name != folderPath
                && sib.displayName.caseInsensitiveCompare(displayName) == .orderedSame
        }
        if collidesInMemory {
            return true
        }
        let destURL = newParent.isEmpty
            ? FileStorage.rootURL.appendingPathComponent(displayName)
            : FileStorage.rootURL.appendingPathComponent(newParent).appendingPathComponent(displayName)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    // MARK: - Note CRUD

    func createNote(in folder: String = "") -> Note {
        let baseTitle = L10n.shared["common.untitled"]
        var title = baseTitle
        var counter = 2
        while noteTitleExists(title, in: folder) {
            title = "\(baseTitle) \(counter)"
            counter += 1
        }
        let now = Date()
        var note = Note(
            id: UUID(),
            title: title,
            content: "# \(title)\n\n",
            createdAt: now,
            modifiedAt: now,
            folder: folder,
        )
        do {
            let result = try FileStorage.writeNote(note)
            note.savedFilename = result.filename
            note.savedAt = result.savedAt
        } catch {
            Log.storage.error("[NoteStore] writeNote failed — \(error)")
        }
        notes.append(note)
        refreshFolders()
        return note
    }

    func updateContent(for noteID: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        guard notes[index].content != content else { return }

        let now = Date()
        recentlyRenamedNotes = recentlyRenamedNotes.filter { now.timeIntervalSince($0.value) < 10.0 }

        var effectiveContent = content
        // Only derive title from content when an explicit # heading is present.
        // Without this guard, a rename on a headingless note reverts within ~150ms
        // because the editor fires contentChanged on load and extractTitle returns
        // the raw first line, overwriting the manually-set title.
        let firstLine = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        if firstLine.hasPrefix("#") {
            let extracted = Self.extractTitle(from: content)
            let isRecentlyRenamed = recentlyRenamedNotes[noteID].map { now.timeIntervalSince($0) < 5.0 } ?? false
            if isRecentlyRenamed, extracted != notes[index].title {
                // Editor callback carrying a stale heading from before rename.
                // Reconstruct the first heading line using the store's current title instead of reverting.
                var lines = content.components(separatedBy: "\n")
                if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("#") }) {
                    let prefix = String(lines[headingIndex].prefix(while: { $0 == "#" }))
                    lines[headingIndex] = "\(prefix) \(notes[index].title)"
                    effectiveContent = lines.joined(separator: "\n")
                }
            } else {
                notes[index].title = extracted
            }
        }
        notes[index].content = effectiveContent
        notes[index].modifiedAt = now
        dirtyNoteIDs.insert(noteID)

        // Also update selectedNote if it matches
        if selectedNote?.id == noteID {
            selectedNote = notes[index]
        }
    }

    func renameNote(_ note: Note, to newTitle: String) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !noteTitleExists(trimmed, in: note.folder, excluding: note.id) else { return }

        let now = Date()
        notes[index].title = trimmed
        notes[index].modifiedAt = now
        recentlyRenamedNotes[note.id] = now

        // Update the first # heading line in content to match the new title
        var lines = notes[index].content.components(separatedBy: "\n")
        if let headingIndex = lines.firstIndex(where: { $0.hasPrefix("#") }) {
            let prefix = String(lines[headingIndex].prefix(while: { $0 == "#" }))
            lines[headingIndex] = "\(prefix) \(trimmed)"
            notes[index].content = lines.joined(separator: "\n")
        }

        if selectedNote?.id == note.id {
            selectedNote = notes[index]
            onNeedEditorReload?(notes[index].content)
        }

        // Persist immediately on rename (disk file rename + sidecar save),
        // consistent with renameFinderCard.
        saveNoteImmediately(note.id)
    }

    /// Toggle a single tag on a note. Updates in-memory state and marks the note dirty.
    func toggleTag(_ tag: TagColor, on note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        if let i = notes[index].tags.firstIndex(of: tag) {
            notes[index].tags.remove(at: i)
        } else {
            notes[index].tags.append(tag)
        }
        notes[index].modifiedAt = Date()
        dirtyNoteIDs.insert(note.id)
        if selectedNote?.id == note.id {
            selectedNote = notes[index]
        }
        recomputeAllUsedTags()
    }

    /// Set (or clear) the note's identity color. Updates in-memory state and marks dirty.
    func setNoteColor(_ color: NoteColor?, on note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].color = color
        notes[index].modifiedAt = Date()
        dirtyNoteIDs.insert(note.id)
        if selectedNote?.id == note.id {
            selectedNote = notes[index]
        }
    }

    // MARK: - Inline card editing

    /// The note currently being edited in place on its board card (nil = none).
    /// Lives on the store so AppKit-level Escape handling (SidePanelController)
    /// can peel this layer off before hiding the panel.
    var inlineEditingNoteID: UUID?

    /// Enter in-place editing on a card. Only one card edits at a time. The
    /// card box grows into its editor with the shared morph spring.
    func beginInlineEdit(_ note: Note) {
        withAnimation(DesignToken.Motion.morph) {
            inlineEditingNoteID = note.id
        }
    }

    /// Leave in-place editing and flush the debounced save to disk. The card
    /// box collapses back with the shared morph spring.
    func endInlineEdit() {
        guard inlineEditingNoteID != nil else { return }
        withAnimation(DesignToken.Motion.morph) {
            inlineEditingNoteID = nil
        }
        saveDirtyNotes()
    }

    /// Toggle the `- [ ]` / `- [x]` marker on `lineIndex` (0-based) of the
    /// note's content. Line indexes come from the structured card preview.
    func toggleTask(at lineIndex: Int, on note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var lines = notes[index].content.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return }
        let line = lines[lineIndex]
        if let range = line.range(of: "[ ]") {
            lines[lineIndex] = line.replacingCharacters(in: range, with: "[x]")
        } else if let range = line.range(of: "[x]") ?? line.range(of: "[X]") {
            lines[lineIndex] = line.replacingCharacters(in: range, with: "[ ]")
        } else {
            return
        }
        notes[index].content = lines.joined(separator: "\n")
        notes[index].modifiedAt = Date()
        dirtyNoteIDs.insert(note.id)
        if selectedNote?.id == note.id {
            selectedNote = notes[index]
        }
    }

    // MARK: - Pin & Manual Order

    /// Toggle the board pin on a note. Pin state is sidecar metadata — it does
    /// not touch the note body or its modified date.
    func togglePin(on note: Note) {
        setPinned(!note.pinned, on: note)
    }

    func setPinned(_ pinned: Bool, on note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        guard notes[index].pinned != pinned else { return }
        notes[index].pinned = pinned
        syncNoteMeta(at: index)
        if selectedNote?.id == note.id {
            selectedNote = notes[index]
        }
    }

    /// Toggle the board pin on a Finder card (sidecar metadata only).
    func togglePin(on card: FinderCard) {
        setPinned(!card.pinned, on: card)
    }

    func setPinned(_ pinned: Bool, on card: FinderCard) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }) else { return }
        guard finderCards[index].pinned != pinned else { return }
        finderCards[index].pinned = pinned
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Assign a fresh manual drag order to every visible board item, placing
    /// the dragged one just above/below its drop target. The first drag flips
    /// the sort setting to `.manual` so the new order is what the board displays.
    /// Pass `persist: false` for live in-drag commits — the board saves the
    /// sidecar once when the drag ends instead of hitting the disk on every
    /// reorder crossing.
    func reorderBoardItem(_ draggedID: UUID, dropTargetID: UUID, above: Bool, in visible: [BoardItem], persist: Bool = true) {
        guard draggedID != dropTargetID else { return }
        guard visible.contains(where: { $0.id == draggedID }),
              visible.contains(where: { $0.id == dropTargetID })
        else { return }

        var ids = visible.map(\.id)
        ids.removeAll { $0 == draggedID }
        guard let targetIndex = ids.firstIndex(of: dropTargetID) else { return }
        let insertion = min(ids.count, above ? targetIndex : targetIndex + 1)
        ids.insert(draggedID, at: insertion)

        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        for index in notes.indices where order[notes[index].id] != nil {
            let newOrder = order[notes[index].id]
            if notes[index].sortOrder != newOrder {
                notes[index].sortOrder = newOrder
                syncNoteMeta(at: index)
            }
        }
        for index in finderCards.indices where order[finderCards[index].id] != nil {
            let newOrder = order[finderCards[index].id]
            if finderCards[index].sortOrder != newOrder {
                finderCards[index].sortOrder = newOrder
                persistFinderCard(finderCards[index])
            }
        }
        if AppSettings.shared.sortBy != .manual {
            AppSettings.shared.sortBy = .manual
        }
        if persist {
            try? SidecarStore.shared.save()
        }
        let targetTitle = visible.first(where: { $0.id == dropTargetID })?.sortTitle ?? "?"
        Log.storage.info("[NoteStore] reorder — '\(draggedID)' → \(above ? "above" : "below", privacy: .public) '\(targetTitle, privacy: .public)'")
    }

    /// Notes-only form of `reorderBoardItem` kept for existing callers.
    func reorderNote(_ draggedID: UUID, dropTargetID: UUID, above: Bool, in visible: [Note], persist: Bool = true) {
        reorderBoardItem(draggedID, dropTargetID: dropTargetID, above: above, in: visible.map(BoardItem.note), persist: persist)
    }

    /// Push the current pin/sort metadata of `notes[index]` into its sidecar entry.
    private func syncNoteMeta(at index: Int) {
        let note = notes[index]
        if var entry = SidecarStore.shared.noteEntry(for: note.id) {
            entry.pinned = note.pinned
            entry.sortOrder = note.sortOrder
            SidecarStore.shared.upsertNote(entry, for: note.id)
        }
    }

    /// Snapshot a Finder card into its sidecar entry (without saving to disk).
    private func persistFinderCard(_ card: FinderCard) {
        SidecarStore.shared.upsertFinderCard(SidecarStore.FinderCardEntry(card), for: card.id)
    }

    /// Flush pending sidecard metadata to disk — the escape hatch for callers
    /// that batched cheap updates with `persist: false`.
    func saveSidecar() {
        try? SidecarStore.shared.save()
    }

    // MARK: - Finder Card CRUD

    /// Create an empty Finder card in `folder`. Under manual sort it takes the
    /// next position after everything already in that folder.
    @discardableResult
    func createFinderCard(in folder: String = "") -> FinderCard {
        let now = Date()
        var card = FinderCard(folder: folder, createdAt: now, modifiedAt: now)
        if AppSettings.shared.sortBy == .manual {
            let existing = notes.filter { $0.folder == folder }.compactMap(\.sortOrder)
                + finderCards.filter { $0.folder == folder }.compactMap(\.sortOrder)
            card.sortOrder = (existing.max() ?? -1) + 1
        }
        finderCards.append(card)
        persistFinderCard(card)
        try? SidecarStore.shared.save()
        Log.storage.info("[NoteStore] created Finder card \(card.id) in '\(folder, privacy: .public)'")
        return card
    }

    /// Delete a Finder card outright — cards are sidecar metadata only, so
    /// unlike notes there is no trash round-trip.
    func deleteFinderCard(_ card: FinderCard) {
        finderCards.removeAll { $0.id == card.id }
        SidecarStore.shared.removeFinderCard(id: card.id)
        selection.remove(.finderCard(card.id))
        if focusedFinderCardID == card.id {
            focusedFinderCardID = nil
        }
        try? SidecarStore.shared.save()
        Log.storage.info("[NoteStore] deleted Finder card \(card.id)")
    }

    /// Replace the stored card wholesale and bump its modified date. The
    /// browser passes `persist: false` on frequent navigation and flushes via
    /// `saveSidecar()` later.
    func updateFinderCard(_ card: FinderCard, persist: Bool = true) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }) else { return }
        var updated = card
        updated.modifiedAt = Date()
        finderCards[index] = updated
        persistFinderCard(updated)
        if persist {
            try? SidecarStore.shared.save()
        }
    }

    /// Set the card's explicit title; an empty or whitespace-only name clears
    /// it back to the fallback (selected favourite's name).
    func renameFinderCard(_ card: FinderCard, to title: String?) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard newTitle != finderCards[index].title else { return }
        finderCards[index].title = newTitle
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Set (or clear) the card's identity color.
    func setFinderCardColor(_ color: NoteColor?, on card: FinderCard) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }) else { return }
        guard finderCards[index].color != color else { return }
        finderCards[index].color = color
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Move a Finder card between folders. Cards can't collide — they have no
    /// on-disk file of their own.
    func moveFinderCard(_ card: FinderCard, to folder: String) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }),
              finderCards[index].folder != folder
        else { return }
        finderCards[index].folder = folder
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Set the card's file-list height in points. The view passes
    /// `persist: false` during a live resize (cheap, memory-only) and flushes
    /// via `saveSidecar()` when the drag ends.
    func setFinderCardListHeight(_ height: Double, for cardID: UUID, persist: Bool = false) {
        guard let index = finderCards.firstIndex(where: { $0.id == cardID }),
              finderCards[index].listHeight != height
        else { return }
        finderCards[index].listHeight = height
        persistFinderCard(finderCards[index])
        if persist {
            try? SidecarStore.shared.save()
        }
    }

    /// Switch a Finder card between its icon grid and list view. Persisted to
    /// the sidecar immediately (view mode is a discrete, infrequent toggle).
    func setFinderCardViewMode(_ mode: FinderCardViewMode, for cardID: UUID) {
        guard let index = finderCards.firstIndex(where: { $0.id == cardID }),
              finderCards[index].viewMode != mode
        else { return }
        finderCards[index].viewMode = mode
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Set a Finder card's sort column and direction. Persisted to the sidecar
    /// immediately (sort is a discrete, infrequent toggle), mirroring
    /// `setFinderCardViewMode`.
    func setFinderCardSort(key: FinderSortKey, ascending: Bool, for cardID: UUID) {
        guard let index = finderCards.firstIndex(where: { $0.id == cardID }),
              finderCards[index].sortKey != key || finderCards[index].sortAscending != ascending
        else { return }
        finderCards[index].sortKey = key
        finderCards[index].sortAscending = ascending
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Set a Finder card's icon-grid icon size in points. Persisted
    /// immediately (discrete, infrequent change), mirroring
    /// `setFinderCardViewMode`.
    func setFinderCardIconSize(_ size: Double, for cardID: UUID) {
        guard let index = finderCards.firstIndex(where: { $0.id == cardID }),
              finderCards[index].iconSize != size
        else { return }
        finderCards[index].iconSize = size
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Set a Finder card's favourites chip font size in points. Persisted
    /// immediately, mirroring `setFinderCardIconSize`.
    func setFinderCardChipFontSize(_ size: Double, for cardID: UUID) {
        guard let index = finderCards.firstIndex(where: { $0.id == cardID }),
              finderCards[index].chipFontSize != size
        else { return }
        finderCards[index].chipFontSize = size
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Add a directory to the card's favourites and select it. Non-directories
    /// are rejected; re-adding an existing favourite just re-selects it.
    @discardableResult
    func addFavorite(_ url: URL, to card: FinderCard) -> FinderFavorite? {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }) else { return nil }
        let path = url.standardizedFileURL.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            Log.storage.warning("[NoteStore] addFavorite — not a directory: '\(path, privacy: .public)'")
            return nil
        }
        if let existing = finderCards[index].favorites.first(where: { $0.path == path }) {
            finderCards[index].selectedFavoriteID = existing.id
            finderCards[index].currentPath = nil
            persistFinderCard(finderCards[index])
            try? SidecarStore.shared.save()
            return existing
        }
        let favorite = FinderFavorite(path: path)
        finderCards[index].favorites.append(favorite)
        finderCards[index].selectedFavoriteID = favorite.id
        finderCards[index].currentPath = nil
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
        return favorite
    }

    /// Remove a favourite from the card. If it was the selected one, selection
    /// falls back to the first remaining favourite and the browser resets home.
    func removeFavorite(id favoriteID: UUID, from card: FinderCard) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }),
              let favIndex = finderCards[index].favorites.firstIndex(where: { $0.id == favoriteID })
        else { return }
        let wasSelected = finderCards[index].selectedFavoriteID == favoriteID
        finderCards[index].favorites.remove(at: favIndex)
        if wasSelected {
            finderCards[index].selectedFavoriteID = finderCards[index].favorites.first?.id
            finderCards[index].currentPath = nil
        }
        finderCards[index].modifiedAt = Date()
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Point the card's browser at a favourite as its home.
    func selectFavorite(id favoriteID: UUID, in card: FinderCard) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }),
              finderCards[index].favorites.contains(where: { $0.id == favoriteID }),
              finderCards[index].selectedFavoriteID != favoriteID
        else { return }
        finderCards[index].selectedFavoriteID = favoriteID
        finderCards[index].currentPath = nil
        persistFinderCard(finderCards[index])
        try? SidecarStore.shared.save()
    }

    /// Record where the browser currently sits. Navigation is cheap, so this
    /// only touches the sidecar in memory unless `persist` is set — callers
    /// flush with `saveSidecar()` when it matters.
    func setCurrentPath(_ path: String?, for card: FinderCard, persist: Bool = false) {
        guard let index = finderCards.firstIndex(where: { $0.id == card.id }),
              finderCards[index].currentPath != path
        else { return }
        finderCards[index].currentPath = path
        persistFinderCard(finderCards[index])
        if persist {
            try? SidecarStore.shared.save()
        }
    }

    /// Toggle a tag in the active sidebar filter. Multi-select acts as OR.
    func toggleTagFilter(_ tag: TagColor) {
        // Filter change → visible row set may shrink; selection would point at hidden rows.
        clearSelection()
        if activeTagFilter.contains(tag) {
            activeTagFilter.remove(tag)
        } else {
            activeTagFilter.insert(tag)
        }
    }

    func clearTagFilter() {
        activeTagFilter.removeAll()
    }

    // MARK: - Selection actions

    func isSelected(_ id: SelectableID) -> Bool {
        selection.contains(id)
    }

    /// Mouse-driven selection handler matching Finder semantics.
    /// `visibleOrder` is the current flat row order used for ⇧-click ranges.
    func handleSelectionClick(
        on item: SelectableID,
        isShift: Bool,
        isCommand: Bool,
        visibleOrder: [SelectableID],
    ) {
        if isCommand {
            if selection.contains(item) {
                selection.remove(item)
            } else {
                selection.insert(item)
            }
            selectionAnchor = item
            selectionExtensionEnd = item
        } else if isShift,
                  let anchor = selectionAnchor,
                  let a = visibleOrder.firstIndex(of: anchor),
                  let b = visibleOrder.firstIndex(of: item)
        {
            let lo = min(a, b)
            let hi = max(a, b)
            selection = Set(visibleOrder[lo ... hi])
            selectionExtensionEnd = item
        } else {
            selection = [item]
            selectionAnchor = item
            selectionExtensionEnd = item
        }
    }

    /// Replace selection with a single item (used when right-clicking an unselected row).
    func replaceSelection(with item: SelectableID) {
        selection = [item]
        selectionAnchor = item
        selectionExtensionEnd = item
    }

    func clearSelection() {
        selection.removeAll()
        selectionAnchor = nil
        selectionExtensionEnd = nil
        selectedTitleNoteID = nil
    }

    // MARK: - Keyboard navigation

    /// Flat row order matching what the active list view is rendering.
    /// Empty when keyboard navigation shouldn't apply (editor, trash, settings).
    var keyboardNavOrder: [SelectableID] {
        if selectedNote != nil || showTrash || showSettings {
            return []
        }
        let s = AppSettings.shared
        if let parent = selectedFolder?.name {
            let kidFolders = sortedFolders(childFolders(of: parent), by: s.sortBy, ascending: s.sortAscending)
            let folderItems = sortedBoardItems(notes: filteredNotes, finderCards: filteredFinderCards, by: s.sortBy, ascending: s.sortAscending)
            return kidFolders.map { .folder($0.name) } + folderItems.map(\.selectableID)
        }
        let topLevel = sortedFolders(folders.filter(\.isTopLevel), by: s.sortBy, ascending: s.sortAscending)
        let rootItems = sortedBoardItems(
            notes: notes.filter(\.folder.isEmpty),
            finderCards: finderCards.filter(\.folder.isEmpty),
            by: s.sortBy,
            ascending: s.sortAscending,
        )
        return topLevel.map { .folder($0.name) } + rootItems.map(\.selectableID)
    }

    /// Move the selection one row down (or up). When `extending` is true,
    /// walk the active end from the anchor (⇧-arrow); otherwise replace with a single item.
    /// Returns true if the keystroke was consumed.
    @discardableResult
    func moveSelection(direction: Int, extending: Bool) -> Bool {
        let order = keyboardNavOrder
        guard !order.isEmpty else { return false }

        // Cursor walks `selectionExtensionEnd` for ⇧-arrows so each press advances
        // by one. Falls back to anchor / first selected row when state is missing.
        let cursor = selectionExtensionEnd ?? selectionAnchor ?? selection.first

        // No prior cursor (or it points at a hidden row) — land on first/last.
        guard let cursor, let idx = order.firstIndex(of: cursor) else {
            let target = direction > 0 ? order.first! : order.last!
            selection = [target]
            selectionAnchor = target
            selectionExtensionEnd = target
            return true
        }

        let next = max(0, min(order.count - 1, idx + direction))
        let target = order[next]

        if extending {
            // Anchor stays put; only the extension end walks.
            let anchor = selectionAnchor ?? cursor
            guard let a = order.firstIndex(of: anchor) else {
                selection = [target]
                selectionAnchor = target
                selectionExtensionEnd = target
                return true
            }
            let lo = min(a, next)
            let hi = max(a, next)
            selection = Set(order[lo ... hi])
            selectionExtensionEnd = target
        } else {
            selection = [target]
            selectionAnchor = target
            selectionExtensionEnd = target
        }
        return true
    }

    /// Activate the lone selected item: open the note, or navigate into the folder.
    /// No-op when the selection isn't a single item.
    @discardableResult
    func openSelectedItem() -> Bool {
        guard selection.count == 1, let item = selection.first else { return false }
        switch item {
        case let .note(id):
            if let note = notes.first(where: { $0.id == id }) {
                openNote(note)
                return true
            }
        case let .folder(path):
            if let folder = folders.first(where: { $0.name == path }) {
                navigateToFolder(folder)
                return true
            }
        case .finderCard:
            // Finder cards handle their own activation in the browser UI.
            return false
        }
        return false
    }

    // MARK: - Batch actions

    /// Move every note + folder in the current selection to the trash.
    /// Folders that are descendants of another selected folder are skipped
    /// because the parent's trash already swept them up.
    func trashSelection() {
        guard !selection.isEmpty else { return }
        let snapshot = selection
        let noteIDs: [UUID] = snapshot.compactMap {
            if case let .note(id) = $0 {
                id
            } else {
                nil
            }
        }
        let folderPaths: [String] = snapshot.compactMap {
            if case let .folder(path) = $0 {
                path
            } else {
                nil
            }
        }
        let finderCardIDs: [UUID] = snapshot.compactMap {
            if case let .finderCard(id) = $0 {
                id
            } else {
                nil
            }
        }
        Log.storage.info("[NoteStore] trashSelection — \(noteIDs.count) notes, \(finderCardIDs.count) Finder cards, \(folderPaths.count) folders")
        for id in noteIDs {
            if let note = notes.first(where: { $0.id == id }) {
                trashNote(note)
            }
        }
        for id in finderCardIDs {
            if let card = finderCards.first(where: { $0.id == id }) {
                deleteFinderCard(card)
            }
        }
        for path in folderPaths where folders.contains(where: { $0.name == path }) {
            trashFolder(path)
        }
        clearSelection()
    }

    /// Notes currently in the selection (resolved against the live note list).
    var selectedNotes: [Note] {
        selection.compactMap {
            if case let .note(id) = $0 {
                return notes.first(where: { $0.id == id })
            }
            return nil
        }
    }

    /// Folders currently in the selection.
    var selectedFolderPaths: [String] {
        selection.compactMap {
            if case let .folder(path) = $0 {
                path
            } else {
                nil
            }
        }
    }

    /// Finder cards currently in the selection (resolved against the live card list).
    var selectedFinderCards: [FinderCard] {
        selection.compactMap {
            if case let .finderCard(id) = $0 {
                return finderCards.first(where: { $0.id == id })
            }
            return nil
        }
    }

    /// Move every selected note and folder into `targetFolder`.
    /// A target that is a selected folder itself or a descendant of a selected folder is skipped
    /// to avoid moving a folder into itself.
    func moveSelection(toFolder targetFolder: String) {
        guard !selection.isEmpty else { return }
        let noteSnapshot = selectedNotes
        let cardSnapshot = selectedFinderCards
        let folderSnapshot = selectedFolderPaths
        let noteConflictsBefore = pendingNoteMoveConflicts.count
        let folderConflictsBefore = pendingFolderMoveConflicts.count
        for note in noteSnapshot {
            moveNote(note, to: targetFolder)
        }
        for card in cardSnapshot {
            moveFinderCard(card, to: targetFolder)
        }
        for path in folderSnapshot {
            // Skip moving a folder into itself or any of its own descendants.
            if targetFolder == path || targetFolder.hasPrefix(path + "/") {
                continue
            }
            moveFolder(path, toParent: targetFolder)
        }
        let queuedNotes = pendingNoteMoveConflicts.count - noteConflictsBefore
        let queuedFolders = pendingFolderMoveConflicts.count - folderConflictsBefore
        let movedNotes = noteSnapshot.count - queuedNotes
        let movedFolders = folderSnapshot.count - queuedFolders
        Log.storage.info("[NoteStore] moveSelection → '\(targetFolder, privacy: .public)' — moved \(movedNotes) notes + \(cardSnapshot.count) Finder cards + \(movedFolders) folders, queued \(queuedNotes + queuedFolders) conflicts")
        clearSelection()
    }

    /// Aggregate state of `tag` across the selected notes (for menu indicators).
    /// Returns `.on` when every selected note has it, `.off` when none do, `.mixed` otherwise.
    enum SelectionTagState { case on, off, mixed }
    func tagState(_ tag: TagColor) -> SelectionTagState {
        let notes = selectedNotes
        guard !notes.isEmpty else { return .off }
        let withTag = notes.count(where: { $0.tags.contains(tag) })
        if withTag == 0 {
            return .off
        }
        if withTag == notes.count {
            return .on
        }
        return .mixed
    }

    /// Finder/Mail-style batch tag toggle: if every selected note already has the tag,
    /// remove it from all of them; otherwise add the tag to every note that lacks it.
    func toggleTagOnSelection(_ tag: TagColor) {
        let notes = selectedNotes
        guard !notes.isEmpty else { return }
        let allHave = notes.allSatisfy { $0.tags.contains(tag) }
        Log.storage.info("[NoteStore] toggleTagOnSelection \(allHave ? "remove" : "add", privacy: .public) '\(tag.rawValue, privacy: .public)' on \(notes.count) notes")
        for note in notes {
            let has = note.tags.contains(tag)
            if allHave, has {
                toggleTag(tag, on: note)
            } else if !allHave, !has {
                toggleTag(tag, on: note)
            }
        }
    }

    /// Batch identity-color set across the selected notes and Finder cards (nil clears).
    func setNoteColorOnSelection(_ color: NoteColor?) {
        let notes = selectedNotes
        for note in notes {
            setNoteColor(color, on: note)
        }
        for card in selectedFinderCards {
            setFinderCardColor(color, on: card)
        }
        guard !notes.isEmpty || !selectedFinderCards.isEmpty else { return }
        try? SidecarStore.shared.save()
    }

    /// Batch pin/unpin across the selected notes and Finder cards.
    func setPinnedOnSelection(_ pinned: Bool) {
        let notes = selectedNotes
        for note in notes {
            setPinned(pinned, on: note)
        }
        for card in selectedFinderCards {
            setPinned(pinned, on: card)
        }
        guard !notes.isEmpty || !selectedFinderCards.isEmpty else { return }
        try? SidecarStore.shared.save()
    }

    func deleteNote(_ note: Note) {
        if selectedTitleNoteID == note.id {
            selectedTitleNoteID = nil
        }
        notes.removeAll { $0.id == note.id }
        dirtyNoteIDs.remove(note.id)
        do {
            try FileStorage.deleteNote(note)
        } catch {
            Log.storage.error("[NoteStore] deleteNote failed — \(error)")
        }
        refreshFolders()
    }

    func moveNote(_ note: Note, to folder: String) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let actualFilename = notes[index].savedFilename ?? notes[index].filename
        if noteFilenameWouldCollide(actualFilename, in: folder, excluding: note.id) {
            pendingNoteMoveConflicts.append(PendingNoteMoveConflict(noteID: note.id, targetFolder: folder))
            return
        }
        performMoveNote(at: index, to: folder)
    }

    func resolveNoteMoveConflict(keepBoth: Bool) {
        guard !pendingNoteMoveConflicts.isEmpty else { return }
        let conflict = pendingNoteMoveConflicts.removeFirst()
        guard let index = notes.firstIndex(where: { $0.id == conflict.noteID }) else { return }
        let folder = conflict.targetFolder
        let originalFilename = notes[index].savedFilename ?? notes[index].filename

        if keepBoth {
            // Find an unused title whose derived filename also doesn't collide on disk.
            let baseTitle = notes[index].title
            var counter = 2
            var newTitle = "\(baseTitle) \(counter)"
            var newFilename = "\(FileStorage.sanitizeForFilename(newTitle)).md"
            while noteFilenameWouldCollide(newFilename, in: folder, excluding: conflict.noteID) {
                counter += 1
                newTitle = "\(baseTitle) \(counter)"
                newFilename = "\(FileStorage.sanitizeForFilename(newTitle)).md"
            }
            notes[index].title = newTitle
            notes[index].modifiedAt = Date()
            // Rewrite the H1 heading line to match.
            var lines = notes[index].content.components(separatedBy: "\n")
            if let headingIdx = lines.firstIndex(where: { $0.hasPrefix("#") }) {
                let prefix = String(lines[headingIdx].prefix(while: { $0 == "#" }))
                lines[headingIdx] = "\(prefix) \(newTitle)"
                notes[index].content = lines.joined(separator: "\n")
            }
            // Atomic move + rename so the file actually lands at the new name on disk.
            performMoveNote(at: index, to: folder, renamingTo: newFilename)
            return
        }

        // Replace: trash the in-memory note whose effective filename matches at the destination.
        // If no in-memory note matches but a file is squatting on the destination path,
        // treat it as an orphan and remove it so the move can proceed.
        if let existing = notes.first(where: {
            $0.id != conflict.noteID
                && $0.folder == folder
                && (($0.savedFilename ?? $0.filename).caseInsensitiveCompare(originalFilename) == .orderedSame)
        }) {
            trashNote(existing)
        } else {
            let destURL = folder.isEmpty
                ? FileStorage.rootURL.appendingPathComponent(originalFilename)
                : FileStorage.rootURL.appendingPathComponent(folder).appendingPathComponent(originalFilename)
            if FileManager.default.fileExists(atPath: destURL.path) {
                do {
                    try FileManager.default.removeItem(at: destURL)
                    Log.storage.info("[NoteStore] resolveNoteMoveConflict Replace — removed orphan file at '\(destURL.path, privacy: .public)'")
                } catch {
                    Log.storage.error("[NoteStore] resolveNoteMoveConflict Replace — failed to remove orphan: \(error)")
                    return
                }
            }
        }

        if let idx = notes.firstIndex(where: { $0.id == conflict.noteID }) {
            performMoveNote(at: idx, to: folder)
        }
    }

    /// Drains the entire note conflict queue with one choice — backs the "Keep Both All" / "Replace All" buttons.
    func resolveAllNoteMoveConflicts(keepBoth: Bool) {
        var resolved = 0
        while !pendingNoteMoveConflicts.isEmpty {
            let before = pendingNoteMoveConflicts.count
            resolveNoteMoveConflict(keepBoth: keepBoth)
            if pendingNoteMoveConflicts.count >= before {
                break
            } // safety: ensure forward progress
            resolved += 1
        }
        Log.storage.info("[NoteStore] resolveAllNoteMoveConflicts \(keepBoth ? "keepBoth" : "replace", privacy: .public) — \(resolved) resolved")
    }

    /// Drops just the head note conflict — the next conflict (if any) becomes active.
    func skipNoteMoveConflict() {
        guard !pendingNoteMoveConflicts.isEmpty else { return }
        _ = pendingNoteMoveConflicts.removeFirst()
        let remaining = pendingNoteMoveConflicts.count
        Log.storage.info("[NoteStore] skipNoteMoveConflict — 1 note kept in original folder, \(remaining) remaining")
    }

    /// Discards every pending note conflict — items remain in their original folders.
    func cancelAllNoteMoveConflicts() {
        let count = pendingNoteMoveConflicts.count
        pendingNoteMoveConflicts.removeAll()
        if count > 0 {
            Log.storage.info("[NoteStore] cancelAllNoteMoveConflicts — \(count) notes kept in original folders")
        }
    }

    private func performMoveNote(at index: Int, to folder: String, renamingTo newFilename: String? = nil) {
        let note = notes[index]
        do {
            let movedSavedAt = try FileStorage.moveNote(note, toFolder: folder, withFilename: newFilename)
            notes[index].folder = folder
            notes[index].savedFilename = newFilename ?? note.savedFilename ?? note.filename
            notes[index].savedAt = movedSavedAt
            refreshFolders()
        } catch {
            Log.storage.error("[NoteStore] moveNote failed — \(error)")
        }
    }

    // MARK: - Trash

    func trashNote(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].trashedAt = Date()
        dirtyNoteIDs.remove(note.id)

        // Move file to .trash/<UUID>_<Title>.md
        do {
            try FileStorage.trashNote(notes[index])
            let trashFilename = "\(notes[index].id.uuidString)_\(FileStorage.sanitizeForFilename(notes[index].title)).md"
            notes[index].savedFilename = trashFilename
        } catch {
            Log.storage.error("[NoteStore] trashNote failed — \(error)")
        }

        let trashedNote = notes.remove(at: index)
        trashedNotes.append(trashedNote)

        if inlineEditingNoteID == note.id {
            inlineEditingNoteID = nil
        }
        if selectedNote?.id == note.id {
            navigationDirection = .backward
            withAnimation(DesignToken.Motion.morph) {
                selectedNote = nil
            }
        }
        refreshFolders()
    }

    /// Move every note in `name` and its descendant folders into `target`,
    /// auto-renaming on filename collision (keep-both, never queuing
    /// `pendingNoteMoveConflicts`), then trash the leftover empty folder tree.
    /// Backs the "move notes out, then delete folder" choice of the folder
    /// delete flow.
    func dissolveFolder(_ name: String, movingNotesTo target: String) {
        guard !name.isEmpty else { return }
        guard target != name, !target.hasPrefix(name + "/") else { return }

        let prefix = name + "/"
        let moving = notes.filter { $0.folder == name || $0.folder.hasPrefix(prefix) }

        for note in moving {
            guard let index = notes.firstIndex(where: { $0.id == note.id }) else { continue }
            let originalFilename = notes[index].savedFilename ?? notes[index].filename

            // Keep-both on collision: bump the title until neither the
            // in-memory siblings nor the destination on disk collide.
            var renamedFilename: String?
            if noteFilenameWouldCollide(originalFilename, in: target, excluding: note.id) {
                let baseTitle = notes[index].title
                var counter = 2
                var newTitle = "\(baseTitle) \(counter)"
                var candidate = "\(FileStorage.sanitizeForFilename(newTitle)).md"
                while noteFilenameWouldCollide(candidate, in: target, excluding: note.id) {
                    counter += 1
                    newTitle = "\(baseTitle) \(counter)"
                    candidate = "\(FileStorage.sanitizeForFilename(newTitle)).md"
                }
                notes[index].title = newTitle
                notes[index].modifiedAt = Date()
                // Rewrite the H1 heading line to match.
                var lines = notes[index].content.components(separatedBy: "\n")
                if let headingIdx = lines.firstIndex(where: { $0.hasPrefix("#") }) {
                    let headingPrefix = String(lines[headingIdx].prefix(while: { $0 == "#" }))
                    lines[headingIdx] = "\(headingPrefix) \(newTitle)"
                    notes[index].content = lines.joined(separator: "\n")
                }
                renamedFilename = candidate
            }
            performMoveNote(at: index, to: target, renamingTo: renamedFilename)
        }

        // Don't trash the tree if a move failed and left notes behind —
        // trashFolder would otherwise take those notes with it.
        let leftover = notes.contains { $0.folder == name || $0.folder.hasPrefix(prefix) }
        if leftover {
            Log.storage.error("[NoteStore] dissolveFolder — some notes failed to move; leaving '\(name, privacy: .public)' in place")
            refreshFolders()
            return
        }

        // The notes already left, so the folder tree is empty — this trashes
        // the directories plus the sidecar folder color via the existing path.
        trashFolder(name)
        Log.storage.info("[NoteStore] dissolveFolder — moved \(moving.count) notes from '\(name, privacy: .public)' into '\(target, privacy: .public)', trashed empty tree")
    }

    func trashFolder(_ name: String) {
        guard !name.isEmpty else { return }
        let prefix = name + "/"
        let now = Date()
        let folderID = UUID()

        // Collect notes in this folder and subfolders
        let folderNotes = notes.filter { $0.folder == name || $0.folder.hasPrefix(prefix) }

        // Move entire folder directory to .trash/
        do {
            try FileStorage.trashFolder(name, id: folderID, trashedAt: now)
        } catch {
            Log.storage.error("[NoteStore] trashFolder failed — \(error)")
            return
        }

        // Remove notes from active array
        notes.removeAll { $0.folder == name || $0.folder.hasPrefix(prefix) }

        // Finder cards aren't destroyed with the folder — they repot to root.
        let repottedIDs = finderCards
            .filter { $0.folder == name || $0.folder.hasPrefix(prefix) }
            .map(\.id)
        if !repottedIDs.isEmpty {
            for id in repottedIDs {
                if let index = finderCards.firstIndex(where: { $0.id == id }) {
                    finderCards[index].folder = ""
                    persistFinderCard(finderCards[index])
                }
            }
            try? SidecarStore.shared.save()
            Log.storage.info("[NoteStore] trashFolder — repotted \(repottedIDs.count) Finder cards to root")
        }

        let displayName = (name as NSString).lastPathComponent
        let savedDirname = "\(folderID.uuidString)_\(displayName)"
        trashedFolders.append(TrashedFolder(
            id: folderID,
            displayName: displayName,
            originalPath: name,
            trashedAt: now,
            notes: folderNotes,
            savedDirname: savedDirname,
        ))

        // Navigate away if inside this folder or any descendant
        if selectedFolder?.name == name || (selectedFolder?.name.hasPrefix(prefix) ?? false) {
            navigationDirection = .backward
            withAnimation(DesignToken.Motion.morph) {
                selectedFolder = nil
            }
        }

        // Deselect note if it was in the trashed folder
        if let sel = selectedNote, sel.folder == name || sel.folder.hasPrefix(prefix) {
            navigationDirection = .backward
            withAnimation(DesignToken.Motion.morph) {
                selectedNote = nil
            }
        }

        // Remove trashed folder and all sub-paths from cache
        let oldPrefix = name + "/"
        diskFolderNames = diskFolderNames.filter { $0 != name && !$0.hasPrefix(oldPrefix) }
        refreshFolders()
    }

    func restoreNote(_ note: Note) {
        guard let index = trashedNotes.firstIndex(where: { $0.id == note.id }) else { return }
        trashedNotes[index].trashedAt = nil

        // Move file from .trash/ back to original folder
        do {
            let result = try FileStorage.restoreNote(trashedNotes[index])
            trashedNotes[index].savedFilename = result.filename
            trashedNotes[index].savedAt = result.savedAt
        } catch {
            Log.storage.error("[NoteStore] restoreNote failed — \(error)")
        }

        let restoredNote = trashedNotes.remove(at: index)
        notes.append(restoredNote)
        refreshFolders()
    }

    func restoreFolder(_ folder: TrashedFolder) {
        do {
            try FileStorage.restoreFolder(folder)
        } catch {
            Log.storage.error("[NoteStore] restoreFolder failed — \(error)")
            return
        }

        // Sync savedAt from the sidecar — restoreFolder wrote the actual post-move
        // file mtimes there, so in-memory notes match what checkForExternalChanges sees.
        var restoredNotes = folder.notes
        for i in restoredNotes.indices {
            if let entry = SidecarStore.shared.noteEntry(for: restoredNotes[i].id) {
                restoredNotes[i].savedAt = entry.savedAt
            }
        }
        notes.append(contentsOf: restoredNotes)
        trashedFolders.removeAll { $0.id == folder.id }
        refreshFolders()
    }

    func permanentlyDeleteNote(_ note: Note) {
        trashedNotes.removeAll { $0.id == note.id }
        do {
            try FileStorage.deleteTrashedNote(note)
        } catch {
            Log.storage.error("[NoteStore] permanentlyDeleteNote failed — \(error)")
        }
    }

    func permanentlyDeleteFolder(_ folder: TrashedFolder) {
        trashedFolders.removeAll { $0.id == folder.id }
        do {
            try FileStorage.deleteTrashedFolder(folder)
        } catch {
            Log.storage.error("[NoteStore] permanentlyDeleteFolder failed — \(error)")
        }
        // Folder color metadata persists under the original path while in trash so
        // restore preserves it. Permanent delete is the right place to clean it up.
        SidecarStore.shared.removeFolderSubtree(path: folder.originalPath)
        try? SidecarStore.shared.save()
    }

    func emptyTrash() {
        for note in trashedNotes {
            do {
                try FileStorage.deleteTrashedNote(note)
            } catch {
                Log.storage.error("[NoteStore] emptyTrash note failed — \(error)")
            }
        }
        trashedNotes.removeAll()

        for folder in trashedFolders {
            do {
                try FileStorage.deleteTrashedFolder(folder)
            } catch {
                Log.storage.error("[NoteStore] emptyTrash folder failed — \(error)")
            }
        }
        trashedFolders.removeAll()
    }

    /// Total number of items in trash (notes + folders).
    var trashItemCount: Int {
        trashedNotes.count + trashedFolders.count
    }

    /// Whether trash is empty (no notes and no folders).
    var isTrashEmpty: Bool {
        trashedNotes.isEmpty && trashedFolders.isEmpty
    }

    /// Permanently delete notes/folders that have been in trash for more than 60 days.
    private func autoPurgeExpiredTrash() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let expiredNotes = trashedNotes.filter { ($0.trashedAt ?? Date()) < cutoff }
        for note in expiredNotes {
            permanentlyDeleteNote(note)
        }
        let expiredFolders = trashedFolders.filter { $0.trashedAt < cutoff }
        for folder in expiredFolders {
            permanentlyDeleteFolder(folder)
        }
        let purgedCount = expiredNotes.count + expiredFolders.count
        if purgedCount > 0 {
            Log.storage.info("[NoteStore] auto-purged \(purgedCount) expired trash items")
        }
    }

    // MARK: - Folder CRUD

    func createFolder(named name: String, in parent: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fullPath = parent.isEmpty ? trimmed : "\(parent)/\(trimmed)"
        do {
            try FileStorage.ensureFolderExists(fullPath)
            diskFolderNames.insert(fullPath)
            refreshFolders()
        } catch {
            Log.storage.error("[NoteStore] createFolder failed — \(error)")
        }
    }

    func renameFolder(_ oldName: String, to newName: String) {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldName.isEmpty, !trimmedNew.isEmpty, oldName != trimmedNew else { return }
        // Build new full path: replace last component only
        let parent = (oldName as NSString).deletingLastPathComponent
        let parentPath = parent == "." ? "" : parent
        let newFullPath = parentPath.isEmpty ? trimmedNew : "\(parentPath)/\(trimmedNew)"
        guard !folders.contains(where: { $0.name == newFullPath }) else { return }

        do {
            try FileStorage.renameFolder(oldName, to: newFullPath)
            // Update notes in this folder AND all subfolders
            let oldPrefix = oldName + "/"
            for i in notes.indices {
                if notes[i].folder == oldName {
                    notes[i].folder = newFullPath
                } else if notes[i].folder.hasPrefix(oldPrefix) {
                    notes[i].folder = newFullPath + String(notes[i].folder.dropFirst(oldName.count))
                }
            }
            if selectedFolder?.name == oldName {
                selectedFolder = Folder(name: newFullPath, noteCount: selectedFolder?.noteCount ?? 0)
            }
            // Update cache: rename oldName and all sub-paths (reuses oldPrefix declared above)
            diskFolderNames = Set(diskFolderNames.map { path in
                if path == oldName {
                    return newFullPath
                }
                if path.hasPrefix(oldPrefix) {
                    return newFullPath + path.dropFirst(oldName.count)
                }
                return path
            })
            updateSidecarPaths(for: notes)
            SidecarStore.shared.renameFolderEntries(from: oldName, to: newFullPath)
            SidecarStore.shared.renameFinderCardFolders(from: oldName, to: newFullPath)
            for i in finderCards.indices {
                if finderCards[i].folder == oldName {
                    finderCards[i].folder = newFullPath
                } else if finderCards[i].folder.hasPrefix(oldPrefix) {
                    finderCards[i].folder = newFullPath + String(finderCards[i].folder.dropFirst(oldName.count))
                }
            }
            try? SidecarStore.shared.save()
            refreshFolders()
        } catch {
            Log.storage.error("[NoteStore] renameFolder failed — \(error)")
        }
    }

    func moveFolder(_ name: String, toParent newParent: String) {
        guard !name.isEmpty else { return }
        let displayName = (name as NSString).lastPathComponent
        let newFullPath = newParent.isEmpty ? displayName : "\(newParent)/\(displayName)"
        guard newFullPath != name else { return }
        guard !newParent.hasPrefix(name + "/"), newParent != name else { return }

        if folderWouldCollide(displayName: displayName, in: newParent, excluding: name) {
            pendingFolderMoveConflicts.append(PendingFolderMoveConflict(folderName: name, targetParent: newParent))
            return
        }
        performMoveFolder(name, toParent: newParent)
    }

    func resolveFolderMoveConflict(keepBoth: Bool) {
        guard !pendingFolderMoveConflicts.isEmpty else { return }
        let conflict = pendingFolderMoveConflicts.removeFirst()
        let name = conflict.folderName
        let newParent = conflict.targetParent
        let displayName = (name as NSString).lastPathComponent
        let targetFullPath = newParent.isEmpty ? displayName : "\(newParent)/\(displayName)"

        if keepBoth {
            // Loop on filesystem-aware check so we don't pick a name an orphan dir already squats on.
            var counter = 2
            var newDisplayName = "\(displayName) \(counter)"
            while folderWouldCollide(displayName: newDisplayName, in: newParent) {
                counter += 1
                newDisplayName = "\(displayName) \(counter)"
            }
            // Rename locally first, then move
            renameFolder(name, to: newDisplayName)
            let renamedPath = (name as NSString).deletingLastPathComponent
            let renamedParent = renamedPath == "." ? "" : renamedPath
            let renamedFullPath = renamedParent.isEmpty ? newDisplayName : "\(renamedParent)/\(newDisplayName)"
            performMoveFolder(renamedFullPath, toParent: newParent)
            return
        }

        // Replace: trash the existing tracked folder at destination, OR remove an orphan dir on disk.
        if let existingFolder = folders.first(where: { $0.name == targetFullPath }) {
            trashFolder(existingFolder.name)
        } else {
            let destURL = newParent.isEmpty
                ? FileStorage.rootURL.appendingPathComponent(displayName)
                : FileStorage.rootURL.appendingPathComponent(newParent).appendingPathComponent(displayName)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: destURL.path, isDirectory: &isDir), isDir.boolValue {
                do {
                    try FileManager.default.removeItem(at: destURL)
                    Log.storage.info("[NoteStore] resolveFolderMoveConflict Replace — removed orphan directory at '\(destURL.path, privacy: .public)'")
                } catch {
                    Log.storage.error("[NoteStore] resolveFolderMoveConflict Replace — failed to remove orphan directory: \(error)")
                    return
                }
            }
        }
        performMoveFolder(name, toParent: newParent)
    }

    /// Drains the entire folder conflict queue with one choice — backs the "Keep Both All" / "Replace All" buttons.
    func resolveAllFolderMoveConflicts(keepBoth: Bool) {
        var resolved = 0
        while !pendingFolderMoveConflicts.isEmpty {
            let before = pendingFolderMoveConflicts.count
            resolveFolderMoveConflict(keepBoth: keepBoth)
            if pendingFolderMoveConflicts.count >= before {
                break
            }
            resolved += 1
        }
        Log.storage.info("[NoteStore] resolveAllFolderMoveConflicts \(keepBoth ? "keepBoth" : "replace", privacy: .public) — \(resolved) resolved")
    }

    /// Drops just the head folder conflict.
    func skipFolderMoveConflict() {
        guard !pendingFolderMoveConflicts.isEmpty else { return }
        _ = pendingFolderMoveConflicts.removeFirst()
        let remaining = pendingFolderMoveConflicts.count
        Log.storage.info("[NoteStore] skipFolderMoveConflict — 1 folder kept in original parent, \(remaining) remaining")
    }

    /// Discards every pending folder conflict.
    func cancelAllFolderMoveConflicts() {
        let count = pendingFolderMoveConflicts.count
        pendingFolderMoveConflicts.removeAll()
        if count > 0 {
            Log.storage.info("[NoteStore] cancelAllFolderMoveConflicts — \(count) folders kept in original parents")
        }
    }

    private func performMoveFolder(_ name: String, toParent newParent: String) {
        let displayName = (name as NSString).lastPathComponent
        let newFullPath = newParent.isEmpty ? displayName : "\(newParent)/\(displayName)"

        do {
            try FileStorage.moveFolder(name, toParent: newParent)
            let oldPrefix = name + "/"
            for i in notes.indices {
                if notes[i].folder == name {
                    notes[i].folder = newFullPath
                } else if notes[i].folder.hasPrefix(oldPrefix) {
                    notes[i].folder = newFullPath + "/" + String(notes[i].folder.dropFirst(oldPrefix.count))
                }
            }
            if selectedFolder?.name == name {
                selectedFolder = Folder(name: newFullPath, noteCount: selectedFolder?.noteCount ?? 0)
            }
            // Update cache: rename moved folder and all sub-paths (reuses oldPrefix declared above)
            diskFolderNames = Set(diskFolderNames.map { path in
                if path == name {
                    return newFullPath
                }
                if path.hasPrefix(oldPrefix) {
                    return newFullPath + "/" + path.dropFirst(oldPrefix.count)
                }
                return path
            })
            updateSidecarPaths(for: notes)
            SidecarStore.shared.renameFolderEntries(from: name, to: newFullPath)
            SidecarStore.shared.renameFinderCardFolders(from: name, to: newFullPath)
            for i in finderCards.indices {
                if finderCards[i].folder == name {
                    finderCards[i].folder = newFullPath
                } else if finderCards[i].folder.hasPrefix(oldPrefix) {
                    finderCards[i].folder = newFullPath + "/" + String(finderCards[i].folder.dropFirst(oldPrefix.count))
                }
            }
            try? SidecarStore.shared.save()
            refreshFolders()
        } catch {
            Log.storage.error("[NoteStore] moveFolder failed — \(error)")
        }
    }

    /// Folders that are direct children of the given parent path.
    func childFolders(of parent: String) -> [Folder] {
        folders.filter { $0.parentPath == parent }
    }

    /// All notes in a folder (and its subfolders), sorted by most recently
    /// modified. Used by the hover-peek preview to show the folder's contents.
    func recentNotes(in folder: Folder) -> [Note] {
        let prefix = folder.name + "/"
        let folderNotes = notes.filter { $0.folder == folder.name || $0.folder.hasPrefix(prefix) }
        return folderNotes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Immediate child folders of the given folder. Used by the hover-peek
    /// preview to show the folder hierarchy.
    func subfolders(of folder: Folder) -> [Folder] {
        let prefix = folder.name + "/"
        return folders.filter { child in
            child.name.hasPrefix(prefix) && !child.name.dropFirst(prefix.count).contains("/")
        }
    }

    /// Set or clear the color of a folder. Persisted in the sidecar; UI refresh follows.
    func setFolderColor(_ color: TagColor?, for folderName: String) {
        guard !folderName.isEmpty else { return }
        if let color {
            SidecarStore.shared.upsertFolder(
                SidecarStore.FolderEntry(color: color.rawValue),
                forPath: folderName,
            )
        } else {
            SidecarStore.shared.removeFolder(path: folderName)
        }
        try? SidecarStore.shared.save()
        refreshFolders()
    }

    // MARK: - Save

    /// Persist a single note to disk immediately (including file rename, asset directory move,
    /// and sidecar entry update) and clear its dirty flag.
    @discardableResult
    func saveNoteImmediately(_ noteID: UUID) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return false }
        do {
            let result = try FileStorage.writeNote(notes[index])
            notes[index].savedFilename = result.filename
            notes[index].savedAt = result.savedAt
            if let updated = result.updatedContent {
                notes[index].content = updated
                if selectedNote?.id == noteID {
                    selectedNote?.content = updated
                    let noteTitle = notes[index].title
                    Log.storage.info("[Image] reloading editor after image path rewrite for '\(noteTitle, privacy: .public)'")
                    onNeedEditorReload?(updated)
                }
            }
            if selectedNote?.id == noteID {
                selectedNote?.savedFilename = result.filename
                selectedNote?.savedAt = result.savedAt
            }
            // Clean up orphaned images (deleted from body but file still on disk).
            // Shared-assets mode keeps files until explicitly deleted (Typora-like).
            if AppSettings.shared.imageStorageMode == .hiddenDirectory {
                FileStorage.cleanOrphanedImages(forNote: notes[index], body: notes[index].content)
            }
            dirtyNoteIDs.remove(noteID)
            return true
        } catch {
            Log.storage.error("[NoteStore] saveNoteImmediately failed for \(noteID) — \(error)")
            return false
        }
    }

    func saveDirtyNotes() {
        if !dirtyNoteIDs.isEmpty {
            let count = dirtyNoteIDs.count
            Log.storage.debug("[NoteStore] saving \(count) dirty notes")
        }
        let idsToSave = dirtyNoteIDs
        for noteID in idsToSave {
            saveNoteImmediately(noteID)
        }
    }

    // MARK: - Private

    private func refreshFolders() {
        let folderNames = Set(notes.map(\.folder)).filter { !$0.isEmpty }
        let allNames = folderNames.union(diskFolderNames).sorted()

        folders = allNames.map { name in
            let prefix = name + "/"
            // Count notes in this folder AND all subfolders (recursive)
            let descendantNotes = notes.filter { $0.folder == name || $0.folder.hasPrefix(prefix) }
            let color = SidecarStore.shared.folderEntry(forPath: name)
                .flatMap { TagColor(rawValue: $0.color) }
            return Folder(
                name: name,
                noteCount: descendantNotes.count,
                latestModifiedAt: descendantNotes.map(\.modifiedAt).max(),
                earliestCreatedAt: descendantNotes.map(\.createdAt).min(),
                color: color,
            )
        }
        // Folder/note membership changed → tag set may have too.
        recomputeAllUsedTags()
    }

    /// Sync sidecar NoteEntry.path for all notes whose current in-memory path
    /// differs from what is stored. Called after folder rename/move.
    private func updateSidecarPaths(for notes: [Note]) {
        var changed = false
        for note in notes {
            let actualFilename = note.savedFilename ?? note.filename
            let expectedPath = note.folder.isEmpty ? actualFilename : "\(note.folder)/\(actualFilename)"
            if var entry = SidecarStore.shared.noteEntry(for: note.id), entry.path != expectedPath {
                entry.path = expectedPath
                SidecarStore.shared.upsertNote(entry, for: note.id)
                changed = true
            }
        }
        if changed {
            try? SidecarStore.shared.save()
        }
    }

    private static func extractTitle(from content: String) -> String {
        let firstLine = content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let stripped = firstLine.drop { $0 == "#" || $0 == " " }
        return stripped.isEmpty ? L10n.shared["common.untitled"] : String(stripped)
    }
}
