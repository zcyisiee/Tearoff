import Foundation

/// How the embedded file list renders its entries. Persisted per card in the
/// sidecar (v6).
enum FinderCardViewMode: String, Codable, Hashable {
    /// 64pt icon grid (Finder "icon view").
    case icon
    /// Single-column list (Finder "list view").
    case list
}

/// The column the embedded file list sorts by, plus its direction. Persisted
/// per card in the sidecar (v7). Directories are always grouped first; these
/// keys order within the directories group and within the files group.
enum FinderSortKey: String, Codable, CaseIterable, Hashable {
    /// By name (`localizedStandardCompare`).
    case name
    /// By kind (file extension / UTI group), then by name.
    case kind
    /// By content modification date, then by name.
    case modifiedDate
}

/// A saved favourite (bookmark) inside a Finder card — one browsable directory.
struct FinderFavorite: Identifiable, Hashable, Codable {
    let id: UUID
    var path: String // absolute filesystem path
    /// Shown in the card header when no explicit title is set. Defaults to the
    /// folder's own name; the user can't edit it in v1.
    var displayName: String

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    init(id: UUID = UUID(), path: String, displayName: String? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

/// A board card that embeds a mini file browser. Unlike a `Note` there is no
/// `.md` file — the card is pure sidecar metadata: its favourites, which one
/// is selected, where the browser currently sits, plus the same board-level
/// fields (folder, pin, order, color) a note carries.
struct FinderCard: Identifiable, Hashable {
    let id: UUID

    /// Optional explicit card title. nil → the UI falls back to the selected
    /// favourite's display name.
    var title: String?

    /// Tearoff folder path, "" = root — same semantics as `Note.folder`.
    var folder: String

    var favorites: [FinderFavorite]
    var selectedFavoriteID: UUID?

    /// Absolute path currently browsed. nil → the selected favourite's root.
    var currentPath: String?

    /// Pinned cards float above the rest of the board. Persisted in the sidecar.
    var pinned: Bool

    /// Manual sort position within a visible list (drag-reorder). nil = no
    /// explicit position yet. Persisted in the sidecar.
    var sortOrder: Int?

    /// Identity color (SideNotes-style card color). Persisted in the sidecar.
    var color: NoteColor?

    /// Height of the embedded file list in points. nil = default (240). The
    /// user resizes it with the card's bottom-edge drag handle; persisted in
    /// the sidecar.
    var listHeight: Double?

    /// How the embedded file list renders its entries. Persisted in the
    /// sidecar (v6). Defaults to the icon grid.
    var viewMode: FinderCardViewMode

    /// Column the embedded file list sorts by. Persisted per card (v7).
    /// Defaults to name ascending (Finder's default for name sort).
    var sortKey: FinderSortKey

    /// Direction of the sort. `true` = ascending. Persisted per card (v7).
    var sortAscending: Bool

    /// Icon-grid icon size in points. nil = default (64). Persisted (v8).
    var iconSize: Double?

    /// Favourites chip font size in points. nil = default (11). Persisted (v8).
    var chipFontSize: Double?

    var createdAt: Date
    var modifiedAt: Date

    /// Header title: explicit title if non-empty, otherwise the selected
    /// favourite's name, otherwise a generic fallback.
    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return selectedFavorite?.displayName ?? "Finder"
    }

    var selectedFavorite: FinderFavorite? {
        guard let selectedFavoriteID else { return nil }
        return favorites.first { $0.id == selectedFavoriteID }
    }

    /// Where the browser should currently be showing.
    var currentURL: URL? {
        if let currentPath {
            return URL(fileURLWithPath: currentPath, isDirectory: true)
        }
        return selectedFavorite?.url
    }

    init(
        id: UUID = UUID(),
        title: String? = nil,
        folder: String = "",
        favorites: [FinderFavorite] = [],
        selectedFavoriteID: UUID? = nil,
        currentPath: String? = nil,
        pinned: Bool = false,
        sortOrder: Int? = nil,
        color: NoteColor? = nil,
        listHeight: Double? = nil,
        viewMode: FinderCardViewMode = .icon,
        sortKey: FinderSortKey = .name,
        sortAscending: Bool = true,
        iconSize: Double? = nil,
        chipFontSize: Double? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
    ) {
        self.id = id
        self.title = title
        self.folder = folder
        self.favorites = favorites
        self.selectedFavoriteID = selectedFavoriteID
        self.currentPath = currentPath
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.color = color
        self.listHeight = listHeight
        self.viewMode = viewMode
        self.sortKey = sortKey
        self.sortAscending = sortAscending
        self.iconSize = iconSize
        self.chipFontSize = chipFontSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// Compare all UI-visible properties.
    static func == (lhs: FinderCard, rhs: FinderCard) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.folder == rhs.folder
            && lhs.favorites == rhs.favorites
            && lhs.selectedFavoriteID == rhs.selectedFavoriteID
            && lhs.currentPath == rhs.currentPath
            && lhs.pinned == rhs.pinned
            && lhs.sortOrder == rhs.sortOrder
            && lhs.color == rhs.color
            && lhs.listHeight == rhs.listHeight
            && lhs.viewMode == rhs.viewMode
            && lhs.sortKey == rhs.sortKey
            && lhs.sortAscending == rhs.sortAscending
            && lhs.iconSize == rhs.iconSize
            && lhs.chipFontSize == rhs.chipFontSize
    }
}

extension FinderCard {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Sidecar conversion

extension FinderCard {
    /// Rebuild a card from its sidecar entry. Favourite IDs that fail to parse
    /// are regenerated rather than dropped.
    init(id: UUID, entry: SidecarStore.FinderCardEntry) {
        let favorites = entry.favorites.map { fav in
            FinderFavorite(
                id: UUID(uuidString: fav.id) ?? UUID(),
                path: fav.path,
                displayName: fav.displayName,
            )
        }
        let selectedID = entry.selectedFavoriteID.flatMap(UUID.init(uuidString:))
        self.init(
            id: id,
            title: entry.title,
            folder: entry.folder,
            favorites: favorites,
            selectedFavoriteID: selectedID,
            currentPath: entry.currentPath,
            pinned: entry.pinned ?? false,
            sortOrder: entry.sortOrder,
            color: entry.color.flatMap(NoteColor.init),
            listHeight: entry.listHeight ?? (entry.isExpanded == true ? 480 : nil),
            viewMode: entry.viewMode.flatMap(FinderCardViewMode.init(rawValue:)) ?? .icon,
            sortKey: entry.sortKey.flatMap(FinderSortKey.init(rawValue:)) ?? .name,
            sortAscending: entry.sortAscending ?? true,
            iconSize: entry.iconSize,
            chipFontSize: entry.chipFontSize,
            createdAt: entry.createdAt,
            modifiedAt: entry.modifiedAt,
        )
    }
}

extension SidecarStore.FinderCardEntry {
    /// Snapshot a card into its sidecar representation.
    init(_ card: FinderCard) {
        self.init(
            title: card.title,
            folder: card.folder,
            favorites: card.favorites.map {
                .init(id: $0.id.uuidString, path: $0.path, displayName: $0.displayName)
            },
            selectedFavoriteID: card.selectedFavoriteID?.uuidString,
            currentPath: card.currentPath,
            pinned: card.pinned,
            sortOrder: card.sortOrder,
            color: card.color?.rawValue,
            isExpanded: nil,
            listHeight: card.listHeight,
            viewMode: card.viewMode.rawValue,
            sortKey: card.sortKey.rawValue,
            sortAscending: card.sortAscending,
            iconSize: card.iconSize,
            chipFontSize: card.chipFontSize,
            createdAt: card.createdAt,
            modifiedAt: card.modifiedAt,
        )
    }
}
