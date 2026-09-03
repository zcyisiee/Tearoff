import AppKit
import QuickLookUI
import SwiftUI

// MARK: - Appearance

/// Colours and fonts the card hands to the AppKit list so the table matches
/// the SwiftUI chrome around it. Passed wholesale; any change re-renders rows.
struct FinderListAppearance: Equatable {
    /// Selection highlight.
    var accent: NSColor
    var primaryText: NSColor
    /// Modified date.
    var secondaryText: NSColor
    var nameFont: NSFont
    var metaFont: NSFont
    var rowHeight: CGFloat
}

// MARK: - Commands

/// Imperative hooks the list's coordinator exposes to the card / menus. The
/// card creates one per card and passes it to `FinderFileListView`; the
/// coordinator fills the closures once the table exists.
final class FinderListCommands {
    var beginRename: (FinderEntry) -> Void = { _ in }
    var selectAll: () -> Void = {}
    /// Returns true if something was cleared.
    var clearSelection: () -> Bool = { false }
    var selectedEntries: () -> [FinderEntry] = { [] }
    /// Makes the table first responder.
    var focus: () -> Void = {}
}

// MARK: - Actions

/// Callbacks the list fires into the card.
struct FinderListActions {
    /// Table became (true) / resigned (false) first responder.
    var onFocusChanged: (Bool) -> Void
    /// Double-click, ⌘O, ⌘↓ on these entries. Directory → navigate, file → open.
    var onActivate: ([FinderEntry]) -> Void
    /// ⌘↑
    var onGoUp: () -> Void
    /// Right-click. `entries` = the clicked row plus current selection (Finder
    /// semantics); empty array = blank-area menu.
    var contextMenu: ([FinderEntry], FinderListCommands) -> NSMenu
    /// A drag-out session began (true) / ended (false) — the card suspends
    /// panel auto-hide for the duration.
    var onDragSessionChanged: (Bool) -> Void
    /// Left mouse-down anywhere inside the embedded list (item or blank
    /// area). SwiftUI tap gestures on the card still fire over this AppKit
    /// content, so the card uses this to tell genuine chrome taps apart from
    /// list clicks and skip board-level tap handling for the latter.
    var onListMouseDown: () -> Void
    /// Space / Quick Look on the selected entries (multi-select pages through
    /// the panel). Suspends panel auto-hide for the panel's lifetime.
    var onQuickLook: ([FinderEntry]) -> Void
    /// ⌘I / Get Info on a single entry — opens Finder's Get Info window.
    var onShowInfo: (FinderEntry) -> Void
    /// ⌘⇧. / menu toggle — flips the app-wide hidden-file flag (all cards reload).
    var onToggleHiddenFiles: () -> Void
    /// Quick Look panel was dismissed (or lost control) — resume auto-hide.
    var onQuickLookClosed: () -> Void
    /// Any failed file operation.
    var onError: (Error) -> Void
}

// MARK: - View

/// The file list inside a Finder card: a single-column `NSTableView` styled
/// after Finder's list view — rounded accent selection, type-select, inline
/// rename, full keyboard handling, drag source and drop destination — wrapped
/// in the scroll view the card embeds.
struct FinderFileListView: NSViewRepresentable {
    let browser: FinderCardBrowser
    let appearance: FinderListAppearance
    let actions: FinderListActions
    /// The card creates one `FinderListCommands` per card and passes it here;
    /// the coordinator fills it once the table exists.
    let commands: FinderListCommands
    /// Quick Look controller for this card — wired as the panel's data
    /// source/delegate during `beginPreviewPanelControl`.
    let quickLook: FinderQuickLookController

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FinderScrollView {
        let scrollView = FinderScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let table = FinderTableView()
        table.coordinator = context.coordinator
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = appearance.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsColumnSelection = false
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.focusRingType = .none
        table.registerForDraggedTypes([.fileURL])
        // External destinations only get a copy — allowing `.move` makes Finder
        // choose move for iCloud-synced sources, which triggers the system
        // "remove from iCloud Drive" confirmation. The card-internal drag
        // (`forLocal: true`) keeps move so items can be reordered/filed.
        table.setDraggingSourceOperationMask([.copy], forLocal: false)
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("finder.file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        table.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentSize.width, 1), height: 0)
        table.autoresizingMask = [.width]
        scrollView.documentView = table
        table.sizeLastColumnToFit()

        context.coordinator.attach(table: table)
        context.coordinator.registerCommands()
        context.coordinator.sync()
        return scrollView
    }

    func updateNSView(_: FinderScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_: FinderScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }
}

// MARK: - Coordinator

// MARK: - Coordinator

extension FinderFileListView {
    /// Bridges the table and the card: keeps a snapshot of the browser's
    /// entries for row lookups, mirrors selection both ways, and implements
    /// the delegate behaviour (keyboard activation, inline rename, drag &
    /// drop, context menu).
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSTextFieldDelegate {
        fileprivate(set) var parent: FinderFileListView

        /// Snapshot of `parent.browser.entries` for row lookups between reloads.
        private(set) var entries: [FinderEntry] = []

        private var lastAppearance: FinderListAppearance?
        /// Guards against feedback loops while pushing selection into the table.
        private var isSyncingSelection = false

        /// Rename asked for an entry whose row doesn't exist yet (e.g. a folder
        /// created right before the enumeration landed). Started on the next
        /// reload pass once the row shows up.
        private var pendingRenameID: String?

        private weak var table: FinderTableView?
        private weak var renamingField: NSTextField?
        private var renamingEntry: FinderEntry?
        private var isCancellingRename = false

        /// Drop plan resolved during `validateDrop`, consumed by `acceptDrop`.
        private struct DropPlan {
            var urls: [URL]
            var target: URL
            var isCopy: Bool
        }

        private var pendingDrop: DropPlan?

        init(_ parent: FinderFileListView) {
            self.parent = parent
        }

        // MARK: Lifecycle

        /// Hands the table to the coordinator. Called once from `makeNSView`
        /// before the first `sync()`; without it every `guard let table`
        /// early-returns and the list never renders.
        func attach(table: FinderTableView) {
            self.table = table
        }

        func registerCommands() {
            parent.commands.beginRename = { [weak self] entry in
                self?.beginRename(entry)
            }
            parent.commands.selectAll = { [weak self] in
                self?.table?.selectAll(nil)
            }
            parent.commands.clearSelection = { [weak self] in
                guard let self, let table, !table.selectedRowIndexes.isEmpty else { return false }
                table.deselectAll(table)
                return true
            }
            parent.commands.selectedEntries = { [weak self] in
                self?.selectedEntries() ?? []
            }
            parent.commands.focus = { [weak self] in
                guard let self, let table else { return }
                table.window?.makeFirstResponder(table)
            }
        }

        func teardown() {
            renamingField?.delegate = nil
            table?.delegate = nil
            table?.dataSource = nil
            table = nil
            renamingField = nil
            renamingEntry = nil
            pendingDrop = nil
        }

        // MARK: Sync

        /// Called from `makeNSView` / `updateNSView`. Re-renders rows when the
        /// browser's entries or the appearance changed, and mirrors external
        /// selection changes into the table.
        func sync() {
            guard let table else { return }

            if lastAppearance != parent.appearance {
                lastAppearance = parent.appearance
                table.rowHeight = parent.appearance.rowHeight
                table.reloadData()
                reloadSelection()
            }

            if entries != parent.browser.entries {
                entries = parent.browser.entries
                isSyncingSelection = true
                table.reloadData()
                isSyncingSelection = false
                reloadSelection()
                startPendingRenameIfNeeded()
            } else {
                syncSelection()
            }
        }

        /// Re-applies `browser.selection` to the table and prunes selection ids
        /// that no longer correspond to a row.
        private func reloadSelection() {
            guard let table else { return }
            var rows = IndexSet()
            for (index, entry) in entries.enumerated() where parent.browser.selection.contains(entry.id) {
                rows.insert(index)
            }
            isSyncingSelection = true
            table.selectRowIndexes(rows, byExtendingSelection: false)
            isSyncingSelection = false
            parent.browser.selection = Set(rows.compactMap { entries[$0].id })
        }

        /// External selection change (e.g. the card selected rows programmatically).
        private func syncSelection() {
            guard let table else { return }
            let tableSelection = Set(table.selectedRowIndexes.compactMap { entries[$0].id })
            guard tableSelection != parent.browser.selection else { return }
            var rows = IndexSet()
            for (index, entry) in entries.enumerated() where parent.browser.selection.contains(entry.id) {
                rows.insert(index)
            }
            isSyncingSelection = true
            table.selectRowIndexes(rows, byExtendingSelection: false)
            isSyncingSelection = false
        }

        // MARK: Row helpers

        func entry(at row: Int) -> FinderEntry? {
            row >= 0 && row < entries.count ? entries[row] : nil
        }

        func selectedEntries() -> [FinderEntry] {
            guard let table else { return [] }
            return table.selectedRowIndexes.sorted().compactMap { entry(at: $0) }
        }

        // MARK: Commands

        /// Begins inline rename. Tolerates being called before the entry's row
        /// exists — the rename starts on the next reload pass (⌘⇧N flow).
        func beginRename(_ entry: FinderEntry) {
            guard let table else { return }
            if let row = entries.firstIndex(where: { $0.id == entry.id }), row < table.numberOfRows {
                startRename(row: row)
            } else {
                pendingRenameID = entry.id
            }
        }

        private func startPendingRenameIfNeeded() {
            guard let pendingRenameID, let table else { return }
            guard let row = entries.firstIndex(where: { $0.id == pendingRenameID }), row < table.numberOfRows else {
                return
            }
            self.pendingRenameID = nil
            startRename(row: row)
        }

        private func startRename(row: Int) {
            guard let table, let entry = entry(at: row),
                  let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FinderCellView
            else { return }

            renamingEntry = entry
            renamingField = cell.nameField
            cell.nameField.isEditable = true
            cell.nameField.delegate = self
            table.scrollRowToVisible(row)
            table.window?.makeFirstResponder(cell.nameField)

            // Select the name without extension for files, the whole name for
            // folders — Finder convention.
            if let editor = cell.nameField.currentEditor() {
                let text = cell.nameField.stringValue
                let length = (text as NSString).length
                let ext = (entry.name as NSString).pathExtension
                let selectedLength = entry.isDirectory || ext.isEmpty
                    ? length
                    : length - (ext as NSString).length - 1
                editor.selectedRange = NSRange(location: 0, length: max(0, selectedLength))
            }
        }

        private func finishRename(commit: Bool) {
            guard let field = renamingField, let entry = renamingEntry else { return }
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            field.isEditable = false
            field.delegate = nil
            renamingField = nil
            renamingEntry = nil
            isCancellingRename = false

            if commit, newName != entry.name {
                do {
                    try parent.browser.rename(entry.url, to: newName)
                } catch {
                    field.stringValue = entry.name
                    parent.actions.onError(error)
                }
            } else if !commit {
                field.stringValue = entry.name
            }

            if field.window?.firstResponder !== table {
                field.window?.makeFirstResponder(table)
            }
        }

        // MARK: Activation / bulk operations

        /// Exposed for `FinderTableView.keyDown` (same file).
        func trashSelection() {
            let urls = selectedEntries().map(\.url)
            guard !urls.isEmpty else { return }
            do {
                try parent.browser.trash(urls)
            } catch {
                parent.actions.onError(error)
            }
        }

        func duplicateSelection() {
            let urls = selectedEntries().map(\.url)
            guard !urls.isEmpty else { return }
            do {
                try parent.browser.duplicate(urls)
            } catch {
                parent.actions.onError(error)
            }
        }

        func activateSelection() {
            let selection = selectedEntries()
            guard !selection.isEmpty else { return }
            parent.actions.onActivate(selection)
        }

        func quickLookSelection() {
            let selection = selectedEntries()
            guard !selection.isEmpty else { return }
            parent.actions.onQuickLook(selection)
        }

        func showInfoSelection() {
            guard let first = selectedEntries().first else { return }
            parent.actions.onShowInfo(first)
        }

        func toggleHiddenFiles() {
            parent.actions.onToggleHiddenFiles()
        }

        @objc func doubleClicked(_: Any?) {
            guard let table else { return }
            let clicked = table.clickedRow
            var toActivate: [FinderEntry] = []
            if let entry = entry(at: clicked) {
                // Finder semantics: activating a row that is part of the
                // selection activates the whole selection.
                toActivate = table.selectedRowIndexes.contains(clicked)
                    ? selectedEntries()
                    : [entry]
            }
            guard !toActivate.isEmpty else { return }
            parent.actions.onActivate(toActivate)
        }

        // MARK: NSTableViewDataSource

        /// Without this the table probes `respondsToSelector`, finds nothing,
        /// and renders zero rows no matter how many entries the browser has.
        func numberOfRows(in _: NSTableView) -> Int {
            entries.count
        }

        // MARK: NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
            guard let entry = entry(at: row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("finder.fileCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FinderCellView) ?? FinderCellView()
            cell.identifier = identifier
            cell.configure(entry: entry, appearance: parent.appearance)
            return cell
        }

        func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
            FinderRowView()
        }

        func tableView(_: NSTableView, didAdd rowView: NSTableRowView, forRow _: Int) {
            (rowView as? FinderRowView)?.accent = parent.appearance.accent
        }

        func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
            parent.appearance.rowHeight
        }

        func tableView(_: NSTableView, typeSelectStringFor _: NSTableColumn?, row: Int) -> String? {
            entry(at: row)?.name
        }

        func tableViewSelectionDidChange(_: Notification) {
            guard !isSyncingSelection, let table else { return }
            parent.browser.selection = Set(table.selectedRowIndexes.compactMap { entry(at: $0)?.id })
        }

        // MARK: NSTableViewDataSource — drag source

        func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard let entry = entry(at: row) else { return nil }
            return entry.url as NSURL
        }

        // MARK: NSTableViewDelegate — drop destination

        func tableView(
            _: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation,
        ) -> NSDragOperation {
            pendingDrop = nil
            guard let urls = droppedFileURLs(from: info.draggingPasteboard), !urls.isEmpty else { return [] }
            guard let target = dropTarget(forRow: row, dropOperation: dropOperation) else { return [] }

            let targetURL = target.standardizedFileURL
            let sourceURLs = urls.map(\.standardizedFileURL)

            // Nothing to do: dropping onto itself, or everything already lives here.
            if sourceURLs.contains(targetURL) {
                return []
            }
            if sourceURLs.allSatisfy({ $0.deletingLastPathComponent() == targetURL }) {
                return []
            }

            let operation = resolveDropOperation(for: info, sources: sourceURLs, target: targetURL)
            pendingDrop = DropPlan(urls: sourceURLs, target: targetURL, isCopy: operation == .copy)
            return operation
        }

        func tableView(
            _: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation,
        ) -> Bool {
            defer { pendingDrop = nil }
            let plan = pendingDrop ?? makeDropPlan(for: info, row: row, dropOperation: dropOperation)
            guard let plan, !plan.urls.isEmpty else { return false }

            do {
                if plan.isCopy {
                    try parent.browser.copy(plan.urls, into: plan.target)
                } else {
                    try parent.browser.move(plan.urls, into: plan.target)
                }
            } catch {
                parent.actions.onError(error)
            }
            return true
        }

        private func makeDropPlan(for info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> DropPlan? {
            guard let urls = droppedFileURLs(from: info.draggingPasteboard), !urls.isEmpty,
                  let target = dropTarget(forRow: row, dropOperation: dropOperation)
            else { return nil }
            let targetURL = target.standardizedFileURL
            let sourceURLs = urls.map(\.standardizedFileURL)
            return DropPlan(
                urls: sourceURLs,
                target: targetURL,
                isCopy: resolveDropOperation(for: info, sources: sourceURLs, target: targetURL) == .copy,
            )
        }

        /// Drop target for a proposed row/operation: a directory row receives the
        /// drop itself, everything else targets the whole table (`browser.currentURL`).
        private func dropTarget(forRow row: Int, dropOperation: NSTableView.DropOperation) -> URL? {
            guard let table else { return nil }
            if dropOperation == .on, let entry = entry(at: row), entry.isDirectory {
                return entry.url
            }
            table.setDropRow(-1, dropOperation: .on)
            return parent.browser.currentURL
        }

        private func resolveDropOperation(
            for info: NSDraggingInfo,
            sources: [URL],
            target: URL,
        ) -> NSDragOperation {
            // ⌥ forces a copy; a source on another volume can't be moved.
            if NSEvent.modifierFlags.contains(.option) || info.draggingSourceOperationMask == [.copy] {
                return .copy
            }
            if sources.contains(where: { !isSameVolume($0, target) }) {
                return .copy
            }
            return .move
        }

        private func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true],
            ) as? [URL]
        }

        private func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
            let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
            guard let left = try? lhs.resourceValues(forKeys: keys).volumeIdentifier as? NSObject,
                  let right = try? rhs.resourceValues(forKeys: keys).volumeIdentifier as? NSObject
            else { return true }
            return left == right
        }

        // MARK: NSTextFieldDelegate — inline rename

        func controlTextDidEndEditing(_: Notification) {
            finishRename(commit: !isCancellingRename)
        }

        func control(_ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape during editing: cancel, restore the old name, hand
                // focus back to the table.
                isCancellingRename = true
                control.window?.makeFirstResponder(table)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Scroll view

/// Forwards scroll events to the board behind the card when the file list
/// fits entirely in its visible height, so scrolling over a short list still
/// moves the board.
final class FinderScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if let documentView, documentView.frame.height <= contentView.bounds.height {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Table

/// `NSTableView` behaviour that can't live in the delegate: focus reporting,
/// keyboard shortcuts, and the right-click context menu bracket.
final class FinderTableView: NSTableView {
    weak var coordinator: FinderFileListView.Coordinator?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        coordinator?.parent.actions.onListMouseDown()
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            coordinator?.parent.actions.onFocusChanged(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            coordinator?.parent.actions.onFocusChanged(false)
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard let coordinator else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) {
            // ⌘⇧. — toggle hidden files (app-wide; all cards reload)
            if modifiers.contains(.shift), event.charactersIgnoringModifiers == "." {
                coordinator.toggleHiddenFiles()
                return
            }
            switch event.keyCode {
            case 126: // ⌘↑ — navigate to the parent directory
                coordinator.parent.actions.onGoUp()
                return
            case 125: // ⌘↓ — activate selection
                coordinator.activateSelection()
                return
            case 51: // ⌘⌫ — move selection to trash
                coordinator.trashSelection()
                return
            case 2: // ⌘D — duplicate selection
                coordinator.duplicateSelection()
                return
            default:
                break
            }
            switch event.charactersIgnoringModifiers {
            case "i": // ⌘I — show info (Finder Get Info) on the selection
                coordinator.showInfoSelection()
                return
            case "o": // ⌘O — activate selection
                coordinator.activateSelection()
                return
            case "a": // ⌘A — select all
                selectAll(nil)
                return
            case "[": // ⌘[ — go back in history
                coordinator.parent.browser.goBack()
                return
            case "]": // ⌘] — go forward in history
                coordinator.parent.browser.goForward()
                return
            default:
                break
            }
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 49: // Space — Quick Look on the selection
            coordinator.quickLookSelection()
            return
        case 36, 76: // Return / numpad Enter — rename the single selected row
            if selectedRowIndexes.count == 1, let entry = coordinator.entry(at: selectedRowIndexes.first!) {
                coordinator.beginRename(entry)
            }
            return
        case 53: // Escape — clear selection, or fall through to the panel handler
            if !selectedRowIndexes.isEmpty {
                deselectAll(nil)
                return
            }
            super.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: QLPreviewPanel control

    /// The Quick Look panel finds its controller through the responder chain.
    /// Accept control so the card's controller drives the panel.
    override func acceptsPreviewPanelControl(_: QLPreviewPanel) -> Bool {
        coordinator?.parent.quickLook != nil
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = coordinator?.parent.quickLook
        panel.delegate = coordinator?.parent.quickLook
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        // `previewPanelDidClose` may be suppressed once the delegate is nil'd,
        // so resume auto-hide here too — it's idempotent and the panel is
        // closing either way.
        coordinator?.parent.actions.onQuickLookClosed()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let coordinator else {
            super.rightMouseDown(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let entries: [FinderEntry]
        if coordinator.entry(at: row) != nil {
            // Finder semantics: right-clicking an unselected row selects it
            // alone; the menu covers the clicked row plus current selection.
            if !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            entries = coordinator.selectedEntries()
        } else {
            entries = [] // blank area
        }

        let menu = coordinator.parent.actions.contextMenu(entries, coordinator.parent.commands)
        guard !menu.items.isEmpty else { return }

        // Bracket the popup with the panel's menu-suppression flag (same
        // pattern as NSContextMenuModifier.swift's ContextMenuCatcher.popMenu).
        NSContextMenuModifier.menuGeneration += 1
        let generation = NSContextMenuModifier.menuGeneration
        NSContextMenuModifier.isShowingMenu = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard generation == NSContextMenuModifier.menuGeneration else { return }
            NSContextMenuModifier.isShowingMenu = false
            NSContextMenuModifier.lastMenuDismissAt = Date()
        }
    }

    // MARK: Drag session reporting

    override func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        super.draggingSession(session, willBeginAt: screenPoint)
        coordinator?.parent.actions.onDragSessionChanged(true)
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
        coordinator?.parent.actions.onDragSessionChanged(false)
    }
}

// MARK: - Row view

/// Draws the row selection as a rounded accent rectangle instead of the
/// system blue; dimmed when the window is not key.
final class FinderRowView: NSTableRowView {
    var accent: NSColor?

    override func drawSelection(in _: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 0)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (accent ?? .controlAccentColor)
            .withAlphaComponent(isEmphasized ? 0.22 : 0.14)
            .setFill()
        path.fill()
    }
}

// MARK: - Cell view

/// One row: 16pt file icon, truncating-middle name, trailing modified date.
/// The name field is non-editable by default; the coordinator flips it
/// editable for the inline rename.
final class FinderCellView: NSTableCellView {
    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let dateField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        imageView = iconView
        textField = nameField
        iconView.isEditable = false

        for subview in [iconView, nameField, dateField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.wraps = false
        dateField.usesSingleLineMode = true
        dateField.lineBreakMode = .byTruncatingTail

        // The name yields when space runs out; the date keeps its width.
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: dateField.leadingAnchor, constant: -8),

            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("FinderCellView is created in code only")
    }

    func configure(entry: FinderEntry, appearance: FinderListAppearance) {
        iconView.image = FileIconCache.shared.icon(for: entry)
        nameField.stringValue = entry.name
        nameField.font = appearance.nameFont
        nameField.textColor = appearance.primaryText
        dateField.stringValue = entry.modifiedAt.map(\.homeDisplayFormat) ?? ""
        dateField.font = appearance.metaFont
        dateField.textColor = appearance.secondaryText
    }
}
