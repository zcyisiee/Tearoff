import Foundation

/// One entry in the board's card stream — a markdown note or a Finder card.
/// Unifies the fields the board orders and lays out on so pin-first sorting,
/// manual drag order, and folder membership work across both kinds through a
/// single code path.
enum BoardItem: Identifiable, Hashable {
    case note(Note)
    case finder(FinderCard)

    var id: UUID {
        switch self {
        case let .note(note): note.id
        case let .finder(card): card.id
        }
    }

    /// Tearoff folder path, "" = root — same semantics for both kinds.
    var folder: String {
        switch self {
        case let .note(note): note.folder
        case let .finder(card): card.folder
        }
    }

    var pinned: Bool {
        switch self {
        case let .note(note): note.pinned
        case let .finder(card): card.pinned
        }
    }

    /// Manual sort position within a visible list; nil when never dragged.
    var sortOrder: Int? {
        switch self {
        case let .note(note): note.sortOrder
        case let .finder(card): card.sortOrder
        }
    }

    /// Title the board sorts and displays by.
    var sortTitle: String {
        switch self {
        case let .note(note): note.title
        case let .finder(card): card.displayTitle
        }
    }

    var createdAt: Date {
        switch self {
        case let .note(note): note.createdAt
        case let .finder(card): card.createdAt
        }
    }

    var modifiedAt: Date {
        switch self {
        case let .note(note): note.modifiedAt
        case let .finder(card): card.modifiedAt
        }
    }

    /// The wrapped note when this is a note, nil for Finder cards.
    var note: Note? {
        if case let .note(note) = self {
            note
        } else {
            nil
        }
    }

    /// The wrapped Finder card when this is one, nil for notes.
    var finderCard: FinderCard? {
        if case let .finder(card) = self {
            card
        } else {
            nil
        }
    }

    /// Selection identity in the shared board row space.
    var selectableID: NoteStore.SelectableID {
        switch self {
        case let .note(note): .note(note.id)
        case let .finder(card): .finderCard(card.id)
        }
    }
}
