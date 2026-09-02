import AppKit
import QuickLookUI
import SwiftUI

// MARK: - Icon view layout

/// Lays the icon grid out flow-style with 64pt icons. Computes a column count
/// from the available width (so the grid reflows as the card resizes) and
/// distributes the row width evenly across the columns, leaving a comfortable
/// gutter. Directories-first / name ordering is inherited from the browser's
/// own `enumerate` — this layout only positions items.
final class FinderIconFlowLayout: NSCollectionViewFlowLayout {
    static let iconSize: CGFloat = 64
    static let backdropPad: CGFloat = 4 // selected-icon highlight extends 4pt past the icon
    static let topPadding: CGFloat = 8
    static let spacing: CGFloat = 16 // gutter between items and rows
    static let labelHeight: CGFloat = 30 // two 12pt label lines
    static let bottomPadding: CGFloat = 10
    /// Drives the column count; the actual item width expands to fill the row.
    static let nominalWidth: CGFloat = 84
    static let horizontalPad: CGFloat = 10

    var itemHeight: CGFloat = FinderIconFlowLayout.topPadding
        + FinderIconFlowLayout.backdropPad * 2 + FinderIconFlowLayout.iconSize
        + 6 + FinderIconFlowLayout.labelHeight + FinderIconFlowLayout.bottomPadding

    override func prepare() {
        super.prepare()
        scrollDirection = .vertical

        guard let collectionView else { return }
        let available = max(
            collectionView.bounds.width - FinderIconFlowLayout.horizontalPad * 2,
            FinderIconFlowLayout.nominalWidth,
        )

        let fit = (available + FinderIconFlowLayout.spacing)
            / (FinderIconFlowLayout.nominalWidth + FinderIconFlowLayout.spacing)
        let columns = max(1, Int(fit))
        let itemWidth = (available - FinderIconFlowLayout.spacing * CGFloat(columns - 1))
            / CGFloat(columns)

        itemSize = NSSize(width: itemWidth, height: itemHeight)
        minimumInteritemSpacing = FinderIconFlowLayout.spacing
        minimumLineSpacing = FinderIconFlowLayout.spacing
        sectionInset = NSEdgeInsets(
            top: FinderIconFlowLayout.topPadding,
            left: FinderIconFlowLayout.horizontalPad,
            bottom: FinderIconFlowLayout.bottomPadding,
            right: FinderIconFlowLayout.horizontalPad,
        )
    }
}

// MARK: - Appearance / commands / actions (shared with the list)

// The icon list reuses `FinderListAppearance`, `FinderListCommands`, and
// `FinderListActions` so a card's two view modes expose identical interaction
// semantics to the menus and the board-level shortcut registry.

// MARK: - Item

/// Rounded highlight drawn behind the selected icon.
final class FinderIconBackdrop: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_: NSRect) {
        guard fillColor != .clear else { return }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
}

/// One grid cell: a 64pt icon with a centred, up-to-two-line, middle-truncating
/// name underneath. Selection is drawn as a rounded backdrop behind the icon
/// plus a highlighted label (Finder convention). The name field starts
/// non-editable; the coordinator flips it editable for inline rename.
final class FinderIconItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("finder.iconItem")

    fileprivate(set) var entry: FinderEntry?
    private var appearance: FinderListAppearance?

    let iconView = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    private let backdrop = FinderIconBackdrop()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root

        for subview in [backdrop, iconView, nameField] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isEditable = false

        nameField.font = .systemFont(ofSize: 12)
        nameField.textColor = .labelColor
        nameField.alignment = .center
        nameField.usesSingleLineMode = false
        nameField.maximumNumberOfLines = 2
        nameField.cell?.wraps = true
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.isEditable = false
        nameField.isBezeled = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.backgroundColor = .clear

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: root.topAnchor, constant: FinderIconFlowLayout.topPadding),
            backdrop.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            backdrop.widthAnchor.constraint(equalToConstant: FinderIconFlowLayout.backdropPad * 2 + FinderIconFlowLayout.iconSize),
            backdrop.heightAnchor.constraint(equalToConstant: FinderIconFlowLayout.backdropPad * 2 + FinderIconFlowLayout.iconSize),

            iconView.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FinderIconFlowLayout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: FinderIconFlowLayout.iconSize),

            nameField.topAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: 6),
            nameField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nameField.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 2),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -2),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
            nameField.heightAnchor.constraint(equalToConstant: FinderIconFlowLayout.labelHeight),
        ])
    }

    func configure(entry: FinderEntry, appearance: FinderListAppearance) {
        self.entry = entry
        self.appearance = appearance
        iconView.image = FileIconCache.shared.icon(for: entry, size: FinderIconFlowLayout.iconSize)
        nameField.stringValue = entry.name
        nameField.font = appearance.nameFont
        nameField.textColor = appearance.primaryText
        refreshSelection()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        entry = nil
        appearance = nil
        // Clear any lingering rename state so a recycled cell starts clean.
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.delegate = nil
        nameField.usesSingleLineMode = false
        nameField.drawsBackground = false
        nameField.textColor = .labelColor
        backdrop.fillColor = .clear
    }

    /// Re-applies the selection visual from the current `isSelected` state.
    func refreshSelection() {
        let accent = appearance?.accent ?? .controlAccentColor
        if isSelected {
            backdrop.fillColor = accent.withAlphaComponent(0.25)
            nameField.backgroundColor = accent
            nameField.textColor = .white
            nameField.drawsBackground = true
        } else {
            backdrop.fillColor = .clear
            nameField.backgroundColor = .clear
            nameField.textColor = appearance?.primaryText ?? .labelColor
            nameField.drawsBackground = false
        }
    }
}

// MARK: - View

/// The Finder-card file browser in icon-grid form: an `NSCollectionView` with
/// a 64pt icon flow layout, rubber-band multi-selection, full keyboard
/// handling, inline rename, drag & drop, and the card's shared context menu —
/// mirroring `FinderFileListView` so both view modes behave identically. It is
/// wrapped in the scroll view the card embeds, so a short list passes scroll
/// events through to the board.
struct FinderIconListView: NSViewRepresentable {
    let browser: FinderCardBrowser
    let appearance: FinderListAppearance
    let actions: FinderListActions
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

        let collection = FinderIconCollectionView()
        collection.coordinator = context.coordinator
        collection.collectionViewLayout = FinderIconFlowLayout()
        collection.backgroundColors = [NSColor.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.focusRingType = .none
        collection.register(FinderIconItem.self, forItemWithIdentifier: FinderIconItem.reuseIdentifier)
        collection.registerForDraggedTypes([.fileURL])
        collection.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        collection.setDraggingSourceOperationMask([.move, .copy], forLocal: true)

        collection.delegate = context.coordinator
        collection.dataSource = context.coordinator

        let rubberBand = RubberBandView(frame: .zero)
        rubberBand.isHidden = true
        collection.addSubview(rubberBand)

        collection.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentSize.width, 1), height: 0)
        collection.autoresizingMask = [.width]
        scrollView.documentView = collection

        context.coordinator.attach(scrollView: scrollView, collection: collection, rubberBand: rubberBand)
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

extension FinderIconListView {
    /// Bridges the icon grid and the card: snapshots the browser's entries for
    /// item lookups, mirrors selection both ways, and implements the delegate
    /// behaviours — keyboard activation, inline rename, drag & drop, context
    /// menu, and rubber-band selection.
    ///
    /// `@MainActor` — the AppKit collection-view delegate/data-source protocols
    /// are annotated `NS_SWIFT_UI_ACTOR`, so their implementations must run on
    /// the main actor.
    @MainActor
    final class Coordinator: NSObject,
        NSCollectionViewDataSource,
        NSCollectionViewDelegate,
        NSCollectionViewDelegateFlowLayout,
        NSTextFieldDelegate
    {
        fileprivate(set) var parent: FinderIconListView

        /// Snapshot of `parent.browser.entries` for item lookups between reloads.
        private(set) var entries: [FinderEntry] = []

        private var lastAppearance: FinderListAppearance?
        /// Guards against feedback loops while pushing selection into the grid.
        private var isSyncingSelection = false

        /// Rename asked for an entry whose item doesn't exist yet (e.g. a folder
        /// created right before the enumeration landed). Started on the next
        /// reload pass once the item shows up.
        private var pendingRenameID: String?

        private weak var scrollView: FinderScrollView?
        private weak var collection: FinderIconCollectionView?
        private weak var rubberBandView: RubberBandView?
        private weak var renamingField: NSTextField?
        private var renamingEntry: FinderEntry?
        private var isCancellingRename = false

        /// Index paths the rubber band started with (⌘/⇧-drag extends them).
        private var rubberBandBaseSelection: Set<IndexPath> = []

        /// Drop plan resolved during `validateDrop`, consumed by `acceptDrop`.
        private struct DropPlan {
            var urls: [URL]
            var target: URL
            var isCopy: Bool
        }

        private var pendingDrop: DropPlan?

        init(_ parent: FinderIconListView) {
            self.parent = parent
        }

        // MARK: Lifecycle

        func attach(scrollView: FinderScrollView, collection: FinderIconCollectionView, rubberBand: RubberBandView) {
            self.scrollView = scrollView
            self.collection = collection
            rubberBandView = rubberBand
        }

        func registerCommands() {
            parent.commands.beginRename = { [weak self] entry in
                self?.beginRename(entry)
            }
            parent.commands.selectAll = { [weak self] in
                self?.selectAll()
            }
            parent.commands.clearSelection = { [weak self] in
                self?.clearSelectionCommands() ?? false
            }
            parent.commands.selectedEntries = { [weak self] in
                self?.selectedEntries() ?? []
            }
            parent.commands.focus = { [weak self] in
                guard let self, let collection else { return }
                collection.window?.makeFirstResponder(collection)
            }
        }

        func teardown() {
            renamingField?.delegate = nil
            collection?.delegate = nil
            collection?.dataSource = nil
            collection = nil
            scrollView = nil
            rubberBandView = nil
            renamingField = nil
            renamingEntry = nil
            pendingDrop = nil
        }

        // MARK: Sync

        /// Called from `makeNSView` / `updateNSView`. Re-renders items when the
        /// browser's entries or the appearance changed, and mirrors external
        /// selection changes into the grid.
        func sync() {
            guard let collection else { return }

            if lastAppearance != parent.appearance {
                lastAppearance = parent.appearance
                collection.reloadData()
                reloadSelection()
            }

            if entries != parent.browser.entries {
                entries = parent.browser.entries
                isSyncingSelection = true
                collection.reloadData()
                isSyncingSelection = false
                reloadSelection()
                startPendingRenameIfNeeded()
            } else {
                syncSelection()
            }

            bringRubberBandToFront()
        }

        /// Re-applies `browser.selection` to the grid and prunes selection ids
        /// that no longer correspond to an item.
        private func reloadSelection() {
            guard let collection else { return }
            let paths = Set(
                entries.indices
                    .filter { parent.browser.selection.contains(entries[$0].id) }
                    .map { IndexPath(item: $0, section: 0) },
            )
            isSyncingSelection = true
            collection.selectItems(at: paths, scrollPosition: [])
            isSyncingSelection = false
            parent.browser.selection = Set(
                entries.enumerated().compactMap { _, entry in
                    parent.browser.selection.contains(entry.id) ? entry.id : nil
                },
            )
            refreshVisibleItemAppearances()
        }

        /// External selection change (e.g. the card selected items programmatically).
        private func syncSelection() {
            guard let collection else { return }
            let gridSelection = Set(
                collection.selectionIndexPaths.compactMap { entry(at: $0.item)?.id },
            )
            guard gridSelection != parent.browser.selection else { return }
            let paths = Set(
                entries.indices
                    .filter { parent.browser.selection.contains(entries[$0].id) }
                    .map { IndexPath(item: $0, section: 0) },
            )
            isSyncingSelection = true
            collection.selectItems(at: paths, scrollPosition: [])
            isSyncingSelection = false
            refreshVisibleItemAppearances()
        }

        // MARK: Item helpers

        func entry(at item: Int) -> FinderEntry? {
            item >= 0 && item < entries.count ? entries[item] : nil
        }

        func selectedEntries() -> [FinderEntry] {
            guard let collection else { return [] }
            return collection.selectionIndexPaths
                .sorted { $0.item < $1.item }
                .compactMap { entry(at: $0.item) }
        }

        // MARK: Commands

        func selectAll() {
            guard let collection else { return }
            let all = Set((0 ..< entries.count).map { IndexPath(item: $0, section: 0) })
            isSyncingSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            collection.selectItems(at: all, scrollPosition: [])
            isSyncingSelection = false
            if !all.isEmpty {
                parent.browser.selection = Set(entries.map(\.id))
            }
            refreshVisibleItemAppearances()
        }

        /// Clears the grid selection. Returns true if something was cleared.
        @discardableResult
        func clearSelectionCommands() -> Bool {
            guard let collection, !collection.selectionIndexPaths.isEmpty else { return false }
            isSyncingSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            isSyncingSelection = false
            parent.browser.selection = []
            refreshVisibleItemAppearances()
            return true
        }

        /// Replaces the grid selection with exactly `indexPaths` (right-click
        /// select-alone, type-select).
        func replaceSelection(with indexPaths: [IndexPath]) {
            guard let collection else { return }
            isSyncingSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            collection.selectItems(at: Set(indexPaths), scrollPosition: [])
            isSyncingSelection = false
            parent.browser.selection = Set(indexPaths.compactMap { entry(at: $0.item)?.id })
            refreshVisibleItemAppearances()
        }

        /// Begins inline rename. Tolerates being called before the item exists —
        /// the rename starts on the next reload pass (⌘⇧N flow).
        func beginRename(_ entry: FinderEntry) {
            guard let collection else {
                pendingRenameID = entry.id
                return
            }
            guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
                pendingRenameID = entry.id
                return
            }
            let indexPath = IndexPath(item: index, section: 0)
            collection.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
            collection.layoutSubtreeIfNeeded()
            guard let item = collection.item(at: indexPath) as? FinderIconItem else {
                pendingRenameID = entry.id
                return
            }
            startRename(item: item, entry: entry)
        }

        private func startPendingRenameIfNeeded() {
            guard let pendingRenameID, let collection else { return }
            guard let index = entries.firstIndex(where: { $0.id == pendingRenameID }) else { return }
            let indexPath = IndexPath(item: index, section: 0)
            collection.scrollToItems(at: [indexPath], scrollPosition: .nearestVerticalEdge)
            collection.layoutSubtreeIfNeeded()
            guard let item = collection.item(at: indexPath) as? FinderIconItem else { return }
            self.pendingRenameID = nil
            startRename(item: item, entry: entries[index])
        }

        private func startRename(item: FinderIconItem, entry: FinderEntry) {
            guard let collection, let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            let field = item.nameField

            renamingEntry = entry
            renamingField = field
            field.isEditable = true
            field.isSelectable = true
            field.delegate = self
            // Single-line editing during rename (Finder shows one line); the field
            // returns to its two-line display when editing ends.
            field.usesSingleLineMode = true
            collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestVerticalEdge)
            collection.window?.makeFirstResponder(field)

            // Select the name without extension for files, the whole name for
            // folders — Finder convention.
            if let editor = field.currentEditor() {
                let text = field.stringValue
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
            field.isSelectable = false
            field.delegate = nil
            field.usesSingleLineMode = false
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

            refreshVisibleItemAppearances()
            if let collection, field.window?.firstResponder !== collection {
                field.window?.makeFirstResponder(collection)
            }
        }

        // MARK: Activation / bulk operations

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

        /// Activates the item at `index` on a double-click — Finder semantics:
        /// if the clicked item is part of the selection the whole selection is
        /// activated, otherwise just that item.
        func doubleClickActivate(at index: Int) {
            guard let collection, let entry = entry(at: index) else { return }
            let clickedIndex = IndexPath(item: index, section: 0)
            let toActivate = collection.selectionIndexPaths.contains(clickedIndex)
                ? selectedEntries()
                : [entry]
            guard !toActivate.isEmpty else { return }
            parent.actions.onActivate(toActivate)
        }

        // MARK: Type-select

        func typeSelectMatch(_ prefix: String) -> Int? {
            guard !prefix.isEmpty else { return nil }
            let lower = prefix.lowercased()
            for (index, entry) in entries.enumerated()
                where entry.name.lowercased().hasPrefix(lower)
            {
                return index
            }
            return nil
        }

        func selectToTypeSelect(_ index: Int) {
            guard let collection, entry(at: index) != nil else { return }
            replaceSelection(with: [IndexPath(item: index, section: 0)])
            collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestVerticalEdge)
        }

        // MARK: NSCollectionViewDataSource

        func numberOfSections(in _: NSCollectionView) -> Int {
            1
        }

        func collectionView(_: NSCollectionView, numberOfItemsInSection _: Int) -> Int {
            entries.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = (collectionView.makeItem(withIdentifier: FinderIconItem.reuseIdentifier, for: indexPath) as? FinderIconItem) ?? FinderIconItem()
            if let entry = entry(at: indexPath.item) {
                item.configure(entry: entry, appearance: parent.appearance)
            }
            return item
        }

        func collectionView(_: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let entry = entry(at: indexPath.item) else { return nil }
            return entry.url as NSURL
        }

        // MARK: NSCollectionViewDelegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt _: Set<IndexPath>) {
            guard !isSyncingSelection else { return }
            parent.browser.selection = Set(
                collectionView.selectionIndexPaths.compactMap { entry(at: $0.item)?.id },
            )
            refreshVisibleItemAppearances()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt _: Set<IndexPath>) {
            guard !isSyncingSelection else { return }
            parent.browser.selection = Set(
                collectionView.selectionIndexPaths.compactMap { entry(at: $0.item)?.id },
            )
            refreshVisibleItemAppearances()
        }

        func collectionView(
            _: NSCollectionView,
            draggingSession _: NSDraggingSession,
            willBeginAt _: NSPoint,
            forItemsAt _: Set<IndexPath>,
        ) {
            parent.actions.onDragSessionChanged(true)
        }

        func collectionView(
            _: NSCollectionView,
            draggingSession _: NSDraggingSession,
            endedAt _: NSPoint,
            dragOperation _: NSDragOperation,
        ) {
            parent.actions.onDragSessionChanged(false)
        }

        // MARK: NSCollectionViewDelegate — drop destination

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop info: NSDraggingInfo,
            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>,
        ) -> NSDragOperation {
            pendingDrop = nil
            guard let urls = droppedFileURLs(from: info.draggingPasteboard), !urls.isEmpty else { return [] }

            let point = collectionView.convert(info.draggingLocation, from: nil)
            let hitIndex = collectionView.indexPathForItem(at: point)

            let targetURL: URL
            if let hitIndex, let entry = entry(at: hitIndex.item), entry.isDirectory {
                // Dropping on a folder icon moves the items into that folder.
                targetURL = entry.url
                proposedIndexPath.pointee = hitIndex as NSIndexPath
                dropOperation.pointee = .on
            } else {
                // Dropping on empty space moves into the current directory.
                guard let current = parent.browser.currentURL else { return [] }
                targetURL = current
                dropOperation.pointee = .on
            }

            let target = targetURL.standardizedFileURL
            let sourceURLs = urls.map(\.standardizedFileURL)

            if sourceURLs.contains(target) {
                return []
            }
            if sourceURLs.allSatisfy({ $0.deletingLastPathComponent() == target }) {
                return []
            }

            let operation = resolveDropOperation(for: info, sources: sourceURLs, target: target)
            pendingDrop = DropPlan(urls: sourceURLs, target: target, isCopy: operation == .copy)
            return operation
        }

        func collectionView(
            _: NSCollectionView,
            acceptDrop info: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation,
        ) -> Bool {
            _ = indexPath
            _ = dropOperation
            defer { pendingDrop = nil }
            let plan = pendingDrop ?? makeDropPlan(from: info)
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

        private func makeDropPlan(from info: NSDraggingInfo) -> DropPlan? {
            guard let collection, let urls = droppedFileURLs(from: info.draggingPasteboard), !urls.isEmpty,
                  let current = parent.browser.currentURL
            else { return nil }
            let point = collection.convert(info.draggingLocation, from: nil)
            let hitIndex = collection.indexPathForItem(at: point)
            let targetURL = (hitIndex.flatMap { entry(at: $0.item) }?.isDirectory == true)
                ? (hitIndex.flatMap { entry(at: $0.item) }?.url ?? current)
                : current
            let target = targetURL.standardizedFileURL
            let sourceURLs = urls.map(\.standardizedFileURL)
            return DropPlan(
                urls: sourceURLs,
                target: target,
                isCopy: resolveDropOperation(for: info, sources: sourceURLs, target: target) == .copy,
            )
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

        // MARK: Rubber-band selection

        func beginRubberBand(at _: NSPoint) {
            guard let collection else { return }
            // ⌘/⇧-drag extends the existing selection; a plain drag replaces it.
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            rubberBandBaseSelection = (flags.contains(.command) || flags.contains(.shift))
                ? collection.selectionIndexPaths
                : []
        }

        func rubberBandDrag(with event: NSEvent, start: NSPoint) {
            guard let collection, let scrollView else { return }
            let viewportPoint = scrollView.contentView.convert(event.locationInWindow, from: nil)
            autoscrollIfNeeded(viewportPoint: viewportPoint)

            let contentPoint = collection.convert(event.locationInWindow, from: nil)
            let rect = Self.selectionRect(from: start, to: contentPoint)
            updateRubberBandSelection(rect: rect)
            showRubberBand(rect: rect)
        }

        func endRubberBand(at point: NSPoint, start: NSPoint) {
            guard let rubberBandView else { return }
            updateRubberBandSelection(rect: Self.selectionRect(from: start, to: point))
            rubberBandView.isHidden = true
            rubberBandBaseSelection = []
        }

        private func updateRubberBandSelection(rect: NSRect) {
            guard let collection, let layout = collection.collectionViewLayout else { return }
            var selected = rubberBandBaseSelection
            for index in 0 ..< entries.count {
                let indexPath = IndexPath(item: index, section: 0)
                guard let attrs = layout.layoutAttributesForItem(at: indexPath) else { continue }
                if attrs.frame.intersects(rect) {
                    selected.insert(indexPath)
                }
            }
            isSyncingSelection = true
            collection.deselectItems(at: collection.selectionIndexPaths)
            collection.selectItems(at: selected, scrollPosition: [])
            isSyncingSelection = false
            parent.browser.selection = Set(selected.compactMap { entry(at: $0.item)?.id })
            refreshVisibleItemAppearances()
        }

        private func autoscrollIfNeeded(viewportPoint: NSPoint) {
            guard let scrollView, let collection else { return }
            let visible = scrollView.contentView.bounds
            let threshold: CGFloat = 20
            let step: CGFloat = 18
            var dy: CGFloat = 0
            if viewportPoint.y < visible.minY + threshold {
                dy = -step
            } else if viewportPoint.y > visible.maxY - threshold {
                dy = step
            }
            guard dy != 0 else { return }
            var origin = scrollView.contentView.bounds.origin
            origin.y += dy
            let maxY = max(0, collection.frame.height - visible.height)
            origin.y = max(0, min(origin.y, maxY))
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func showRubberBand(rect: NSRect) {
            guard let rubberBandView else { return }
            rubberBandView.frame = rect
            rubberBandView.isHidden = false
        }

        private static func selectionRect(from a: NSPoint, to b: NSPoint) -> NSRect {
            NSRect(
                x: min(a.x, b.x),
                y: min(a.y, b.y),
                width: abs(a.x - b.x),
                height: abs(a.y - b.y),
            )
        }

        // MARK: Appearance refresh

        private func refreshVisibleItemAppearances() {
            guard let collection else { return }
            for item in collection.visibleItems() {
                (item as? FinderIconItem)?.refreshSelection()
            }
        }

        private func bringRubberBandToFront() {
            guard let collection, let rubberBandView else { return }
            // Always re-add on top: `reloadData` may drain non-item subviews, and
            // item subviews are re-added above it after each reload.
            collection.addSubview(rubberBandView, positioned: .above, relativeTo: nil)
        }

        // MARK: NSTextFieldDelegate — inline rename

        func controlTextDidEndEditing(_: Notification) {
            finishRename(commit: !isCancellingRename)
        }

        func control(_ control: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape during editing: cancel, restore the old name, hand
                // focus back to the grid.
                isCancellingRename = true
                control.window?.makeFirstResponder(collection)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Return during editing: commit by ending editing.
                control.window?.makeFirstResponder(collection)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Rubber band highlight

/// The translucent selection rectangle drawn while rubber-banding over empty
/// space. Lives in the collection view's content coordinate space so it scrolls
/// with the items.
final class RubberBandView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("RubberBandView is created in code only")
    }

    override func draw(_: NSRect) {
        let color = NSColor.selectedContentBackgroundColor
        color.withAlphaComponent(0.16).setFill()
        NSBezierPath(rect: bounds).fill()
        color.setStroke()
        let stroke = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        stroke.lineWidth = 1
        stroke.stroke()
    }
}

// MARK: - Collection view

/// `NSCollectionView` behaviour that can't live in the delegate: focus
/// reporting, keyboard shortcuts, the right-click context menu bracket, and
/// rubber-band mouse handling.
final class FinderIconCollectionView: NSCollectionView {
    weak var coordinator: FinderIconListView.Coordinator?

    fileprivate var isRubberBanding = false
    fileprivate var rubberBandStart = NSPoint.zero

    /// Accumulates typed characters for type-select.
    private var typeSelectBuffer = ""
    private var typeSelectTimestamp: TimeInterval = 0

    override var acceptsFirstResponder: Bool {
        true
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
                coordinator.selectAll()
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
        case 36, 76: // Return / numpad Enter — rename the single selected item
            if selectionIndexPaths.count == 1, let index = selectionIndexPaths.first,
               let entry = coordinator.entry(at: index.item)
            {
                coordinator.beginRename(entry)
            }
            return
        case 53: // Escape — clear selection, or fall through to the panel handler
            if !selectionIndexPaths.isEmpty {
                coordinator.clearSelectionCommands()
                return
            }
            super.keyDown(with: event)
            return
        default:
            break
        }

        // Type-select over printable characters (matching the list view).
        guard let chars = event.characters, !chars.isEmpty,
              !modifiers.contains(.option), !modifiers.contains(.control)
        else {
            super.keyDown(with: event)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - typeSelectTimestamp > 0.8 {
            typeSelectBuffer = ""
        }
        typeSelectTimestamp = now
        typeSelectBuffer += chars
        if let target = coordinator.typeSelectMatch(typeSelectBuffer) {
            coordinator.selectToTypeSelect(target)
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
        let clickedIndex = indexPathForItem(at: point)
        var entries: [FinderEntry] = []
        if clickedIndex.flatMap({ coordinator.entry(at: $0.item) }) != nil {
            // Finder semantics: right-clicking an unselected item selects it
            // alone; the menu covers the clicked item plus current selection.
            if let clickedIndex, !selectionIndexPaths.contains(clickedIndex) {
                coordinator.replaceSelection(with: [clickedIndex])
            }
            entries = coordinator.selectedEntries()
        } else {
            entries = [] // blank area
        }

        let menu = coordinator.parent.actions.contextMenu(entries, coordinator.parent.commands)
        guard !menu.items.isEmpty else { return }

        // Bracket the popup with the panel's menu-suppression flag (same
        // pattern as NSContextMenuModifier.ContextMenuCatcher.rightMouseDown).
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

    // MARK: Rubber-band mouse handling

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)

        // Double-click on an item activates it (Finder semantics — open a file
        // or navigate into a directory).
        if event.clickCount == 2, let clickedIndex = indexPathForItem(at: point) {
            coordinator.doubleClickActivate(at: clickedIndex.item)
            return
        }

        if indexPathForItem(at: point) != nil {
            // Item click — let AppKit handle ⌘ toggling and ⇧ ranges.
            super.mouseDown(with: event)
            return
        }
        // Blank area — start a rubber band.
        isRubberBanding = true
        rubberBandStart = point
        coordinator.beginRubberBand(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        if isRubberBanding {
            coordinator?.rubberBandDrag(with: event, start: rubberBandStart)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isRubberBanding {
            let point = convert(event.locationInWindow, from: nil)
            coordinator?.endRubberBand(at: point, start: rubberBandStart)
            isRubberBanding = false
            return
        }
        super.mouseUp(with: event)
    }
}
