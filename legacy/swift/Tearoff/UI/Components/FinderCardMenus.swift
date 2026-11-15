import AppKit
import SwiftUI

/// NSMenu builders for the Finder card surface: the card itself, rows in its
/// file list, and favourites chips. NSMenu (not SwiftUI `.contextMenu`) so SF
/// Symbol icons render reliably — same reasoning as `NoteListMenus`.
enum FinderCardMenus {
    // MARK: - Card Menu

    /// Context menu for the Finder card as a whole (chrome / board-level ops).
    static func cardMenu(
        card: FinderCard,
        noteStore: NoteStore,
        l10n: L10n,
        onRename: @escaping () -> Void,
    ) -> NSMenu {
        let menu = NSMenu()
        let cardID = card.id

        menu.addActionItem(title: l10n["common.rename"], icon: "pencil", action: onRename)

        if let url = card.currentURL {
            menu.addActionItem(title: l10n["finder.card.revealInFinder"], icon: "folder") {
                FinderCardBrowser.revealInFinder([url])
            }
        }

        // Move To submenu — Root + top-level folders, skipping where the card
        // already lives. Cards can't nest further, so no tree here.
        let topLevel = noteStore.folders.filter(\.isTopLevel)
        if !card.folder.isEmpty || !topLevel.isEmpty {
            let submenu = NSMenu()
            if !card.folder.isEmpty {
                submenu.addActionItem(title: l10n["common.root"], icon: "house") {
                    noteStore.moveFinderCard(card, to: "")
                }
            }
            for folder in topLevel where folder.name != card.folder {
                submenu.addActionItem(title: folder.displayName, icon: "folder") {
                    noteStore.moveFinderCard(card, to: folder.name)
                }
            }
            let moveItem = NSMenuItem(title: l10n["common.moveTo"], action: nil, keyEquivalent: "")
            moveItem.image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            moveItem.submenu = submenu
            menu.addItem(moveItem)
        }

        // Color submenu (identity color, same swatch approach as note menus)
        let colorItem = NSMenuItem(title: l10n["noteColor.menu"], action: nil, keyEquivalent: "")
        colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        colorItem.submenu = cardColorSubmenu(for: card, noteStore: noteStore, l10n: l10n)
        menu.addItem(colorItem)

        menu.addActionItem(
            title: card.pinned ? l10n["note.unpin"] : l10n["note.pin"],
            icon: card.pinned ? "pin.slash" : "pin",
        ) {
            // Read the card fresh — the snapshot may be stale by click time.
            guard let current = noteStore.finderCards.first(where: { $0.id == cardID }) else { return }
            noteStore.togglePin(on: current)
        }

        menu.addItem(.separator())

        let deleteItem = menu.addActionItem(title: l10n["finder.card.delete"], icon: "trash") {
            guard let current = noteStore.finderCards.first(where: { $0.id == cardID }) else { return }
            noteStore.deleteFinderCard(current)
        }
        deleteItem.attributedTitle = destructiveTitle(l10n["finder.card.delete"])

        return menu
    }

    /// Identity-color picker for a Finder card.
    private static func cardColorSubmenu(for card: FinderCard, noteStore: NoteStore, l10n: L10n) -> NSMenu {
        let menu = NSMenu()
        let cardID = card.id

        let none = menu.addActionItem(title: l10n["noteColor.none"], icon: "circle.slash") {
            if let current = noteStore.finderCards.first(where: { $0.id == cardID }) {
                noteStore.setFinderCardColor(nil, on: current)
            }
        }
        if card.color == nil {
            none.state = .on
        }

        menu.addItem(.separator())
        for color in NoteColor.allCases {
            let item = menu.addActionItem(title: color.label, icon: "circle.fill") {
                if let current = noteStore.finderCards.first(where: { $0.id == cardID }) {
                    noteStore.setFinderCardColor(color, on: current)
                }
            }
            item.image = swatchImage(color.strip, ring: card.color == color)
            if card.color == color {
                item.state = .on
            }
        }
        return menu
    }

    // MARK: - File Menu

    /// Context menu inside the file list. `entries` = clicked row(s) with the
    /// current selection folded in (Finder semantics); empty = blank-area menu.
    static func fileMenu(
        entries: [FinderEntry],
        browser: FinderCardBrowser,
        commands: FinderListCommands,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
        onQuickLook: @escaping ([URL]) -> Void,
        onGetInfo: @escaping (FinderEntry) -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        if entries.isEmpty {
            blankAreaMenu(into: menu, browser: browser, commands: commands, l10n: l10n, onError: onError)
            return menu
        }

        let urls = entries.map(\.url)

        menu.addActionItem(title: l10n["finder.file.open"], icon: "arrow.up.forward.app") {
            FinderCardBrowser.open(urls)
        }

        if let openWith = openWithSubmenu(for: urls[0], l10n: l10n) {
            let item = NSMenuItem(title: l10n["finder.file.openWith"], action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "app.gift", accessibilityDescription: nil)
            item.submenu = openWith
            menu.addItem(item)
        }

        menu.addActionItem(title: l10n["finder.file.quickLook"], icon: "eye") {
            onQuickLook(urls)
        }

        if entries.count == 1 {
            menu.addActionItem(title: l10n["finder.file.getInfo"], icon: "info.circle") {
                onGetInfo(entries[0])
            }
        }

        menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
            FinderCardBrowser.revealInFinder(urls)
        }

        menu.addActionItem(title: l10n["finder.file.copyPath"], icon: "link") {
            FinderCardBrowser.copyPaths(urls)
        }

        menu.addItem(.separator())

        if entries.count == 1 {
            menu.addActionItem(title: l10n["common.rename"], icon: "pencil") {
                commands.beginRename(entries[0])
            }
        }

        menu.addActionItem(title: l10n["finder.file.duplicate"], icon: "plus.square.on.square") {
            do {
                try browser.duplicate(urls)
            } catch {
                onError(error)
            }
        }

        addNewFolderItem(to: menu, browser: browser, commands: commands, l10n: l10n, onError: onError)

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["finder.file.moveToTrash"], icon: "trash") {
            do {
                try browser.trash(urls)
            } catch {
                onError(error)
            }
        }

        return menu
    }

    /// Blank-area (no row clicked) menu: New Folder / Reveal / Copy Path / Show
    /// Hidden Files.
    private static func blankAreaMenu(
        into menu: NSMenu,
        browser: FinderCardBrowser,
        commands: FinderListCommands,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) {
        addNewFolderItem(to: menu, browser: browser, commands: commands, l10n: l10n, onError: onError)

        if let url = browser.currentURL {
            menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
                FinderCardBrowser.revealInFinder([url])
            }
            menu.addActionItem(title: l10n["finder.file.copyPath"], icon: "link") {
                FinderCardBrowser.copyPaths([url])
            }
        }

        menu.addItem(.separator())
        addShowHiddenFilesItem(to: menu, l10n: l10n)
    }

    /// "Show Hidden Files" check item — toggles the app-wide flag (all cards
    /// reload). Checked while hidden files are visible.
    private static func addShowHiddenFilesItem(to menu: NSMenu, l10n: L10n) {
        let item = menu.addActionItem(title: l10n["finder.file.showHidden"], icon: "eye.slash") {
            AppSettings.shared.showHiddenFiles.toggle()
        }
        if AppSettings.shared.showHiddenFiles {
            item.state = .on
        }
    }

    private static func addNewFolderItem(
        to menu: NSMenu,
        browser: FinderCardBrowser,
        commands: FinderListCommands,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) {
        menu.addActionItem(title: l10n["common.newFolder"], icon: "folder.badge.plus") {
            do {
                let url = try browser.createFolder(named: l10n["finder.untitledFolder"])
                commands.beginRename(FinderEntry.placeholderFolder(at: url))
            } catch {
                onError(error)
            }
        }
    }

    /// "Open With" apps for the first entry — up to 8, each with its own icon.
    private static func openWithSubmenu(for url: URL, l10n _: L10n) -> NSMenu? {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(8)
        guard !apps.isEmpty else { return nil }

        let submenu = NSMenu()
        for appURL in apps {
            let item = submenu.addActionItem(
                title: FileManager.default.displayName(atPath: appURL.path),
                icon: "",
            ) {
                NSWorkspace.shared.open(
                    [url],
                    withApplicationAt: appURL,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: nil,
                )
            }
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            item.toolTip = appURL.path
        }
        return submenu
    }

    // MARK: - Favorite Menu

    /// Context menu for a favourites chip.
    static func favoriteMenu(
        favorite: FinderFavorite,
        card: FinderCard,
        noteStore: NoteStore,
        browser: FinderCardBrowser,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
            FinderCardBrowser.revealInFinder([favorite.url])
        }

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["finder.favorite.remove"], icon: "minus.circle") {
            guard let current = noteStore.finderCards.first(where: { $0.id == card.id }) else { return }
            noteStore.removeFavorite(id: favorite.id, from: current)
        }

        menu.addItem(.separator())

        addTrashFavoriteItem(
            to: menu,
            favorite: favorite,
            card: card,
            noteStore: noteStore,
            browser: browser,
            l10n: l10n,
            onError: onError,
        )

        return menu
    }

    /// "Move to Trash" for a favourite's folder: trashes the directory on
    /// disk, then drops the favourite so the card doesn't keep pointing at a
    /// trashed path. Shared by the chip context menu and the ⋯ favorites
    /// submenu. Recoverable (Finder Trash), so no confirmation — same as the
    /// file list's own trash item.
    private static func addTrashFavoriteItem(
        to menu: NSMenu,
        favorite: FinderFavorite,
        card: FinderCard,
        noteStore: NoteStore,
        browser: FinderCardBrowser,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) {
        menu.addActionItem(title: l10n["finder.file.moveToTrash"], icon: "trash") {
            do {
                try browser.trash([favorite.url])
            } catch {
                onError(error)
                return
            }
            if let current = noteStore.finderCards.first(where: { $0.id == card.id }) {
                noteStore.removeFavorite(id: favorite.id, from: current)
            }
        }
    }

    // MARK: - Header Menu

    /// The card's "⋯" header menu: a Favorites submenu, Add Folder…, and the
    /// current-directory actions (reveal / copy path). Built the same way as
    /// the other Finder menus — NSMenu so SF Symbol icons render reliably.
    static func headerMenu(
        card: FinderCard,
        noteStore: NoteStore,
        browser: FinderCardBrowser,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        // Favorites submenu — one entry per favourite; each expands to
        // select / reveal / remove, reusing the chip menu's actions.
        let favoritesItem = NSMenuItem(title: l10n["finder.header.favorites"], action: nil, keyEquivalent: "")
        favoritesItem.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        favoritesItem.submenu = favoritesSubmenu(
            card: card,
            noteStore: noteStore,
            browser: browser,
            l10n: l10n,
            onError: onError,
        )
        menu.addItem(favoritesItem)

        menu.addActionItem(title: l10n["finder.favorite.add"], icon: "folder.badge.plus") {
            presentFolderPicker(
                card: card,
                noteStore: noteStore,
                directoryURL: browser.currentURL,
                allowsMultipleSelection: true,
            )
        }

        menu.addItem(.separator())

        // Reveal the browsed directory / copy its path. Prefer the live
        // browser location (the browsed directory on screen); fall back to the
        // store's canonical home when the browser has no location yet.
        if let url = browser.currentURL ?? card.currentURL {
            menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
                FinderCardBrowser.revealInFinder([url])
            }
            menu.addActionItem(title: l10n["finder.file.copyPath"], icon: "link") {
                FinderCardBrowser.copyPaths([url])
            }
        }

        menu.addItem(.separator())

        // Icon-grid icon size (per card).
        let iconSizeItem = NSMenuItem(title: l10n["finder.iconSize.menu"], action: nil, keyEquivalent: "")
        iconSizeItem.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        iconSizeItem.submenu = iconSizeSubmenu(card: card, noteStore: noteStore)
        menu.addItem(iconSizeItem)

        // Favourites chip font size (per card).
        let chipFontItem = NSMenuItem(title: l10n["finder.chipFont.menu"], action: nil, keyEquivalent: "")
        chipFontItem.image = NSImage(systemSymbolName: "textformat.size", accessibilityDescription: nil)
        chipFontItem.submenu = chipFontSizeSubmenu(card: card, noteStore: noteStore)
        menu.addItem(chipFontItem)

        menu.addItem(.separator())
        addShowHiddenFilesItem(to: menu, l10n: l10n)

        return menu
    }

    /// Icon-grid icon size options; the card's current size is checked.
    private static func iconSizeSubmenu(card: FinderCard, noteStore: NoteStore) -> NSMenu {
        let menu = NSMenu()
        let cardID = card.id
        let current = card.iconSize ?? 64
        for size in [32.0, 48, 64, 96, 128] {
            let item = menu.addActionItem(title: "\(Int(size)) pt", icon: "") {
                noteStore.setFinderCardIconSize(size, for: cardID)
            }
            if current == size {
                item.state = .on
            }
        }
        return menu
    }

    /// Favourites chip font size options; the card's current size is checked.
    private static func chipFontSizeSubmenu(card: FinderCard, noteStore: NoteStore) -> NSMenu {
        let menu = NSMenu()
        let cardID = card.id
        let current = card.chipFontSize ?? 11
        for size in [9.0, 10, 11, 12, 13] {
            let item = menu.addActionItem(title: "\(Int(size)) pt", icon: "") {
                noteStore.setFinderCardChipFontSize(size, for: cardID)
            }
            if current == size {
                item.state = .on
            }
        }
        return menu
    }

    // MARK: - Sort Menu

    /// The header's sort dropdown: the three sort columns (current key checked),
    /// a separator, then ascending / descending (current direction checked).
    /// Changing an item fires `onSortChange` so the card can persist the
    /// selection and re-sort its browser.
    static func sortMenu(
        card: FinderCard,
        l10n: L10n,
        onSortChange: @escaping (FinderSortKey, Bool) -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        for key in FinderSortKey.allCases {
            let item = menu.addActionItem(title: key.displayName(l10n), icon: key.menuIcon) {
                onSortChange(key, card.sortAscending)
            }
            if card.sortKey == key {
                item.state = .on
            }
        }

        menu.addItem(.separator())

        let directions: [(ascending: Bool, title: String)] = [
            (true, l10n["finder.sort.ascending"]),
            (false, l10n["finder.sort.descending"]),
        ]
        for direction in directions {
            let item = menu.addActionItem(title: direction.title, icon: direction.ascending ? "arrow.up" : "arrow.down") {
                onSortChange(card.sortKey, direction.ascending)
            }
            if card.sortAscending == direction.ascending {
                item.state = .on
            }
        }

        return menu
    }

    /// The Favorites submenu for the header "⋯" menu. Each favourite is a
    /// submenu parent carrying select / reveal / remove — AppKit menu parents
    /// don't fire a click action alongside a submenu, so the select action
    /// lives as its first child alongside the reusable reveal / remove items.
    private static func favoritesSubmenu(
        card: FinderCard,
        noteStore: NoteStore,
        browser: FinderCardBrowser,
        l10n: L10n,
        onError: @escaping (Error) -> Void,
    ) -> NSMenu {
        let menu = NSMenu()

        if card.favorites.isEmpty {
            let empty = NSMenuItem(title: l10n["finder.header.noFavorites"], action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for favorite in card.favorites {
            let parent = NSMenuItem(title: favorite.displayName, action: nil, keyEquivalent: "")
            parent.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            if favorite.id == card.selectedFavoriteID {
                parent.state = .on
            }

            let submenu = NSMenu()
            submenu.addActionItem(title: l10n["finder.favorite.select"], icon: "checkmark.circle") {
                noteStore.selectFavorite(id: favorite.id, in: card)
            }
            submenu.addItem(.separator())
            submenu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
                FinderCardBrowser.revealInFinder([favorite.url])
            }
            submenu.addActionItem(title: l10n["finder.favorite.remove"], icon: "minus.circle") {
                guard let current = noteStore.finderCards.first(where: { $0.id == card.id }) else { return }
                noteStore.removeFavorite(id: favorite.id, from: current)
            }
            submenu.addItem(.separator())
            addTrashFavoriteItem(
                to: submenu,
                favorite: favorite,
                card: card,
                noteStore: noteStore,
                browser: browser,
                l10n: l10n,
                onError: onError,
            )

            parent.submenu = submenu
            menu.addItem(parent)
        }

        return menu
    }

    /// Presents an NSOpenPanel for choosing folder(s) to add as favourites.
    /// Suspends the panel's auto-hide while the open panel is up (the same
    /// mechanism as the board's file drag session) so the panel window can't
    /// vanish underneath a modal folder picker.
    static func presentFolderPicker(
        card: FinderCard,
        noteStore: NoteStore,
        directoryURL: URL?,
        allowsMultipleSelection: Bool,
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.directoryURL = directoryURL

        AppDelegate.shared?.panelController?.suspendAutoHide()
        panel.begin { response in
            AppDelegate.shared?.panelController?.resumeAutoHide(treatAsMouseExit: true)
            guard response == .OK else { return }
            for url in panel.urls {
                _ = noteStore.addFavorite(url, to: card)
            }
        }
    }

    // MARK: - Helpers

    /// Small filled circle swatch; selected color gets a ring.
    private static func swatchImage(_ color: Color, ring: Bool) -> NSImage? {
        let size = NSSize(width: 14, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let nsColor = NSColor(color)
            if ring {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
                NSColor.controlAccentColor.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            nsColor.setFill()
            circle.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Red-tinted menu title for destructive actions (NSMenu has no native
    /// destructive style on macOS).
    private static func destructiveTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.systemRed,
        ])
    }
}

// MARK: - Sort key display

extension FinderSortKey {
    /// Localized menu label for a sort column.
    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .name: l10n["finder.sort.name"]
        case .kind: l10n["finder.sort.kind"]
        case .modifiedDate: l10n["finder.sort.modified"]
        }
    }

    /// SF Symbol for the sort column's menu item.
    var menuIcon: String {
        switch self {
        case .name: "textformat"
        case .kind: "doc.text"
        case .modifiedDate: "calendar"
        }
    }
}
