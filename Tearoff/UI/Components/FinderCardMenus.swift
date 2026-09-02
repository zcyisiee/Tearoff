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

    /// Blank-area (no row clicked) menu: New Folder / Reveal / Copy Path.
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
        l10n: L10n,
    ) -> NSMenu {
        let menu = NSMenu()
        let favoriteID = favorite.id
        let cardID = card.id

        menu.addActionItem(title: l10n["finder.file.reveal"], icon: "folder") {
            FinderCardBrowser.revealInFinder([favorite.url])
        }

        menu.addItem(.separator())

        menu.addActionItem(title: l10n["finder.favorite.remove"], icon: "minus.circle") {
            guard let current = noteStore.finderCards.first(where: { $0.id == cardID }) else { return }
            noteStore.removeFavorite(id: favoriteID, from: current)
        }

        return menu
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
