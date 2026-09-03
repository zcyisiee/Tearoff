import Foundation

/// Manages the inline note rename flow for board cards.
/// Caller is responsible for setting @FocusState after calling beginRename.
@Observable
final class NoteRenameCoordinator {
    var renamingNoteID: UUID?
    var text: String = ""

    // MARK: - Begin

    func beginRename(_ note: Note) {
        renamingNoteID = note.id
        text = note.title
    }

    // MARK: - Conflict check

    func isConflicting(in noteStore: NoteStore) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let noteID = renamingNoteID else { return false }
        let folder = noteStore.notes.first(where: { $0.id == noteID })?.folder ?? ""
        return noteStore.noteTitleExists(trimmed, in: folder, excluding: noteID)
    }

    // MARK: - Commit / Cancel

    func commit(note: Note, noteStore: NoteStore) {
        guard !isConflicting(in: noteStore) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != note.title {
            noteStore.renameNote(note, to: trimmed)
        }
        clear()
    }

    func cancel(noteStore _: NoteStore) {
        clear()
    }

    func commitOrCancel(note: Note, noteStore: NoteStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isConflicting(in: noteStore) {
            cancel(noteStore: noteStore)
        } else {
            commit(note: note, noteStore: noteStore)
        }
    }

    // MARK: - Private

    private func clear() {
        renamingNoteID = nil
        text = ""
    }
}
