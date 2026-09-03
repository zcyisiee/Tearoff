import Cocoa
import OSLog
import SwiftUI

// MARK: - NoteBoardView

/// Single-surface board — replaces the old home → list → editor drill-down.
/// Folder tabs (or collapsible sections) over a grid of note cards; clicking a
/// card expands it in place into the full editor. Trash remains its own page.
struct NoteBoardView: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(AppSettings.self) var appSettings
    @Environment(L10n.self) var l10n

    @State private var noteRename = NoteRenameCoordinator()
    @State private var folderRename = FolderRenameCoordinator()
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var collapsedSections: Set<String> = []
    /// Active press-drag: the dragged card hides in its slot while the
    /// floating replica (`BoardDragReplica`) follows the pointer. Observed by
    /// the replica leaf only, so per-tick pointer updates never re-render the
    /// board.
    @State private var dragSession = BoardDragSession()
    /// Live card frames in `BoardCardSpace`, reported by each card — lets the
    /// drag-reorder hit-test which card the pointer is over. Plain class on
    /// purpose: frame writes must not invalidate the board body.
    @State private var cardLayout = BoardCardLayout()
    /// Last committed drag insertion (target + side), so pointer ticks inside
    /// an already-satisfied region don't re-fire the reorder.
    @State private var lastReorder: (target: UUID, above: Bool)?
    /// Mirror of `PanelSettings.isPanelPinned` (plain class — observe via notification).
    @State private var isPanelPinned = PanelSettings.shared.isPanelPinned
    /// Visible-note order captured when a card enters in-place editing. The
    /// debounced save bumps `modifiedAt` every pause, which would otherwise
    /// jump the editing card around under dateModified sorting.
    @State private var editOrderSnapshot: [UUID]?
    /// Card→editor morph: which note's card the editor grows out of (nil →
    /// no card origin; the editor still grows, from a subtle inset).
    @State private var editorMorphOrigin: UUID?
    /// 0 = editor box at its card, 1 = natural full frame. Animated with the
    /// shared morph spring on open and close. Starts at 0 so the very first
    /// editor session (any open path) also grows in.
    @State private var editorMorphProgress: CGFloat = 0
    /// Bumped on every editor open/close so a pending close-completion can
    /// detect that a new session started and abort.
    @State private var editorMorphGeneration = 0
    /// Last plain tap (note + time) for manual double-click classification —
    /// keeps single taps instant instead of waiting out a multi-tap window.
    @State private var lastCardTap: (id: UUID, at: Date)?
    /// Last title tap (note + time) for card title double-click classification.
    @State private var lastTitleTap: (id: UUID, at: Date)?
    /// Finder card currently being renamed in place (board-owned, like note
    /// rename) — `FinderCardView` shows the title editor when set.
    @State private var renamingFinderCardID: UUID?
    @State private var renamingFinderCardDraft: String = ""
    /// Card that just received a dropped image — pulses its border so the
    /// append is discoverable. Cleared shortly after the drop.
    @State private var droppedFlashID: UUID?
    /// Note that was just newly created — its card inline editor will focus and select the title on mount.
    @State private var newlyCreatedNoteID: UUID?
    /// Target note to scroll into view.
    @State private var scrollToNoteID: UUID?

    // Folder delete confirmation
    @State private var deletingFolderName: String?
    @State private var showDeleteFolderConfirm = false
    /// Folder that still contains notes — the in-panel move-vs-trash choice
    /// overlay is presented for it instead of the plain confirm alert.
    @State private var deleteFolderFlow: PendingFolderDelete?
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isFolderFieldFocused: Bool
    @FocusState private var isNoteRenameFocused: Bool

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Derived data

    /// Board entries for the active tab (All → every note + Finder card;
    /// folder tab → those in that folder only), interleaved by the shared
    /// board ordering.
    private var boardItems: [BoardItem] {
        frozenOrder(
            noteStore.sortedBoardItems(
                notes: noteStore.filteredNotes,
                finderCards: noteStore.filteredFinderCards,
                by: appSettings.sortBy,
                ascending: appSettings.sortAscending,
            ),
        )
    }

    /// While a card is being edited in place, keep the visible order frozen at
    /// the pre-edit arrangement so save-triggered date bumps can't reshuffle
    /// the list under the user's cursor.
    private func frozenOrder(_ sorted: [BoardItem]) -> [BoardItem] {
        guard let snapshot = editOrderSnapshot else { return sorted }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        var result = snapshot.compactMap { byID[$0] }
        let snapshotted = Set(snapshot)
        result.append(contentsOf: sorted.filter { !snapshotted.contains($0.id) })
        return result
    }

    private var childFolders: [Folder] {
        guard let parent = noteStore.selectedFolder?.name else { return [] }
        return noteStore.sortedFolders(
            noteStore.childFolders(of: parent),
            by: appSettings.sortBy,
            ascending: appSettings.sortAscending,
        )
    }

    /// Every folder path, used by the collapsible-sections layout.
    private var allFolders: [Folder] {
        noteStore.sortedFolders(noteStore.folders, by: .name, ascending: true)
    }

    /// Sections for the collapsible-sections layout: one per folder with
    /// notes or Finder cards, plus a root section. Empty folders are hidden
    /// to keep the board scannable.
    private var sections: [(folder: String?, items: [BoardItem])] {
        var result: [(String?, [BoardItem])] = []
        let names = allFolders.map(\.name)
        for name in names {
            let notes = noteStore.notes.filter { $0.folder == name }
            let cards = noteStore.finderCards.filter { $0.folder == name }
            if !notes.isEmpty || !cards.isEmpty {
                result.append(
                    (name, frozenOrder(noteStore.sortedBoardItems(notes: notes, finderCards: cards, by: appSettings.sortBy, ascending: appSettings.sortAscending))),
                )
            }
        }
        let rootNotes = noteStore.notes.filter(\.folder.isEmpty)
        let rootCards = noteStore.finderCards.filter(\.folder.isEmpty)
        if !rootNotes.isEmpty || !rootCards.isEmpty {
            result.append(
                (nil, frozenOrder(noteStore.sortedBoardItems(notes: rootNotes, finderCards: rootCards, by: appSettings.sortBy, ascending: appSettings.sortAscending))),
            )
        }
        return result
    }

    private var isEmpty: Bool {
        boardItems.isEmpty && childFolders.isEmpty && !folderRename.isCreating
    }

    // MARK: Search

    private func applyTagFilter(_ notes: [Note]) -> [Note] {
        guard !noteStore.activeTagFilter.isEmpty else { return notes }
        return notes.filter { !Set($0.tags).isDisjoint(with: noteStore.activeTagFilter) }
    }

    private var titleMatches: [Note] {
        guard !trimmedQuery.isEmpty else { return [] }
        return applyTagFilter(noteStore.notes
            .filter { $0.title.range(of: trimmedQuery, options: .caseInsensitive) != nil })
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private var contentMatches: [ContentMatch] {
        guard !trimmedQuery.isEmpty else { return [] }
        return applyTagFilter(noteStore.notes)
            .compactMap { note -> ContentMatch? in
                guard let snippet = Self.buildSnippet(content: note.content, query: trimmedQuery) else {
                    return nil
                }
                return ContentMatch(note: note, snippet: snippet)
            }
            .sorted { $0.note.modifiedAt > $1.note.modifiedAt }
    }

    private struct ContentMatch: Identifiable {
        var id: String {
            "content-\(note.id)"
        }

        let note: Note
        let snippet: AttributedString
    }

    /// Folder pending deletion with its live descendant note count.
    private struct PendingFolderDelete {
        let folderName: String
        let noteCount: Int
    }

    private var hasAnyResults: Bool {
        !titleMatches.isEmpty || !contentMatches.isEmpty
    }

    private var allNotesSorted: [Note] {
        var seen = Set<UUID>()
        return applyTagFilter(noteStore.notes)
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .filter { seen.insert($0.id).inserted }
    }

    // MARK: Body

    var body: some View {
        PageLayout(headerHidden: noteStore.selectedNote != nil) {
            header
        } content: {
            // Root pages stay mounted while the full editor is open: the
            // board's scroll position and live card frames survive, so the
            // editor can grow out of (and shrink back into) the tapped card.
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    if noteStore.awaitingRootChoice {
                        pickerRows
                    } else if noteStore.showSettings {
                        BoardSettingsView()
                    } else if isSearching {
                        searchResultsList
                    } else {
                        boardContent
                    }

                    if let note = noteStore.selectedNote {
                        ExpandedNoteEditor(note: note, onRequestClose: closeEditor)
                            .modifier(EditorCardMorph(
                                progress: editorMorphProgress,
                                originNoteID: editorMorphOrigin,
                                cardLayout: cardLayout,
                                containerSize: geo.size,
                            ))
                            .transition(.identity)
                            .onAppear {
                                withAnimation(DesignToken.Motion.morph) {
                                    editorMorphProgress = 1
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .coordinateSpace(name: BoardViewportSpace.name)
            }
        }
        .moveConflictAlerts(noteStore: noteStore, l10n: l10n)
        .overlay {
            if let flow = deleteFolderFlow {
                DeleteFolderSheet(
                    folderName: flow.folderName,
                    noteCount: flow.noteCount,
                    noteStore: noteStore,
                    l10n: l10n,
                    onCancel: { deleteFolderFlow = nil },
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelPinStateChanged)) { _ in
            isPanelPinned = PanelSettings.shared.isPanelPinned
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorCloseRequested)) { _ in
            closeEditor()
        }
        .onChange(of: noteStore.inlineEditingNoteID) { _, editingID in
            if editingID != nil {
                if editOrderSnapshot == nil {
                    editOrderSnapshot = boardItems.map(\.id)
                }
            } else {
                newlyCreatedNoteID = nil
                editOrderSnapshot = nil
            }
        }
        .alert(
            l10n["alert.deleteFolder.title"],
            isPresented: $showDeleteFolderConfirm,
            presenting: deletingFolderName,
        ) { folderName in
            Button(l10n["common.cancel"], role: .cancel) {}
            Button(l10n["common.delete"], role: .destructive) {
                noteStore.trashFolder(folderName)
            }
        } message: { folderName in
            let displayName = (folderName as NSString).lastPathComponent
            Text(l10n.t("alert.deleteFolder.empty", displayName))
        }
        .onChange(of: noteStore.pendingNewFolder) { _, pending in
            guard pending else { return }
            noteStore.pendingNewFolder = false
            startCreatingFolder()
        }
        .onChange(of: noteStore.pendingNewNote) { _, pending in
            guard pending else { return }
            noteStore.pendingNewNote = false
            if noteStore.selectedNote != nil {
                closeEditor()
            }
            createNote()
        }
        .onChange(of: noteStore.pendingSearchOnHome) { _, pending in
            guard pending else { return }
            noteStore.pendingSearchOnHome = false
            isSearching = true
            DispatchQueue.main.async { isSearchFieldFocused = true }
        }
        .onAppear {
            if noteStore.pendingSearchOnHome {
                noteStore.pendingSearchOnHome = false
                isSearching = true
                DispatchQueue.main.async { isSearchFieldFocused = true }
            }
            if noteStore.pendingNewNote {
                noteStore.pendingNewNote = false
                if noteStore.selectedNote != nil {
                    closeEditor()
                }
                createNote()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if noteStore.awaitingRootChoice {
            VStack(spacing: 2) {
                Label(l10n["picker.chooseStorageLocation"], systemImage: "folder")
                    .font(DesignToken.Typography.heading)
                Text(l10n["menu.storageTemporary"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        } else if noteStore.showSettings {
            HStack(spacing: DesignToken.Space.sm) {
                HeaderIconButton(systemName: "chevron.left", help: l10n["common.back"]) {
                    noteStore.showSettings = false
                }
                Text(l10n["settings.board.title"])
                    .font(DesignToken.Typography.heading)
                    .foregroundStyle(DesignToken.bodyStrong)
                Spacer()
            }
        } else if isSearching {
            HStack(spacing: DesignToken.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignToken.muted)

                TextField(l10n["search.placeholder"], text: $searchQuery)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)

                Button(action: dismissSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DesignToken.muted)
                }
                .buttonStyle(.borderless)
                .help(l10n["search.close"])
            }
            .onExitCommand { dismissSearch() }
        } else {
            tabBar
                .animation(.easeInOut(duration: 0.22), value: topLevelFolders.count)
                .animation(.easeInOut(duration: 0.22), value: folderRename.isCreating)
        }
    }

    /// Folder tabs. Top-level only — nested folders have a chip row on the
    /// board. Tabs wrap onto new lines as they fill the pill; the header grows
    /// instead of hiding extras behind a horizontal scroll. The action cluster
    /// rides the flow as a trailing dock so wrapped rows use the full width
    /// and the pill keeps a single compact row when everything fits.
    private var tabBar: some View {
        FlowLayout(spacing: DesignToken.Space.xs, lineSpacing: 6, minRowHeight: 28, trailingDock: true) {
            tabButton(
                title: l10n["home.title"],
                icon: "tray.full",
                isActive: noteStore.selectedFolder == nil,
            ) {
                noteStore.navigateToHome()
            }

            ForEach(topLevelFolders) { folder in
                if folderRename.renamingFolderName == folder.name {
                    let isActive = noteStore.selectedFolder?.name == folder.name
                    tabFolderEditor(
                        iconColor: isActive
                            ? DesignToken.onAccent
                            : (folder.color?.color ?? DesignToken.muted),
                        fill: isActive
                            ? (folder.color?.color ?? DesignToken.accent)
                            : DesignToken.surfaceInset,
                        labelColor: isActive ? DesignToken.onAccent : DesignToken.bodyText,
                    )
                } else {
                    tabButton(
                        title: (folder.name as NSString).lastPathComponent,
                        icon: "folder.fill",
                        isActive: noteStore.selectedFolder?.name == folder.name,
                        iconColor: folder.color?.color,
                    ) {
                        noteStore.navigateToFolder(folder)
                    }
                    .nsContextMenu {
                        NoteListMenus.folderMenu(
                            folder: folder,
                            noteStore: noteStore,
                            l10n: l10n,
                            onRename: { startRenamingFolder(folder.name) },
                            onDelete: { requestDeleteFolder(folder) },
                        )
                    }
                }
            }

            // Header strip hosts the editor on home, and in sections
            // layout (no chip row). Nested creates in tabs live in the
            // chip row instead.
            if showsHeaderCreateEditor {
                tabFolderEditor(
                    iconColor: DesignToken.accent,
                    fill: DesignToken.surfaceInset,
                    labelColor: DesignToken.bodyText,
                )
            }

            headerActions
        }
    }

    /// Trailing action cluster docked to the right edge of the tab flow.
    /// Leading padding bumps the tab-to-button gap from the flow's item
    /// spacing (xs) up to the header rhythm (sm).
    private var headerActions: some View {
        HStack(spacing: DesignToken.Space.sm) {
            HeaderIconButton(systemName: "magnifyingglass", help: l10n["common.search"]) {
                isSearching = true
                isSearchFieldFocused = true
            }
            HeaderIconButton(systemName: "folder.badge.plus", help: l10n["common.newFolder"]) {
                startCreatingFolder()
            }
            HeaderIconButton(systemName: "square.and.pencil", help: l10n["common.newNote"]) {
                if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                    createFinderCard()
                } else {
                    createNote()
                }
            }
            .nsContextMenu { newItemsMenu() }
            HeaderIconButton(systemName: "gearshape", help: l10n["settings.board.title"]) {
                noteStore.showSettings = true
            }
            HeaderIconButton(
                systemName: isPanelPinned ? "pin.fill" : "pin",
                help: isPanelPinned ? l10n["panel.unlock"] : l10n["panel.lock"],
                tint: isPanelPinned ? DesignToken.accent : nil,
            ) {
                let settings = PanelSettings.shared
                settings.isPanelPinned.toggle()
                if !settings.isPanelPinned {
                    // Unlock + collapse in one gesture: the lit button is
                    // the "leave locked mode" affordance.
                    AppDelegate.shared?.panelController?.hidePanel()
                }
            }
        }
        .padding(.leading, DesignToken.Space.xs)
    }

    private func tabButton(
        title: String,
        icon: String,
        isActive: Bool,
        iconColor: Color? = nil,
        action: @escaping () -> Void,
    ) -> some View {
        let fill = isActive ? (iconColor ?? DesignToken.accent) : DesignToken.ink.opacity(0)
        let labelColor = isActive ? DesignToken.onAccent : DesignToken.muted
        let glyphColor = isActive ? DesignToken.onAccent : (iconColor ?? DesignToken.muted)
        return Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(glyphColor)
                Text(title)
                    .font(DesignToken.Typography.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(labelColor)
            }
            .padding(.horizontal, DesignToken.Space.sm + 2)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Board Content

    private var boardContent: some View {
        GeometryReader { geo in
            ScrollView {
                ScrollViewReader { scrollProxy in
                    VStack(spacing: 0) {
                        if appSettings.boardLayout == .tabs {
                            tabsBoard
                        } else {
                            sectionsBoard
                        }
                    }
                    .padding(.horizontal, DesignToken.Space.lg)
                    .padding(.vertical, DesignToken.Space.md)
                    .padding(.bottom, 44) // clearance for the floating selection toolbar
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    // Clicking any blank area (card gaps, margins) dismisses the
                    // in-place card editor and an active selection — Finder-style.
                    // Right-click on the same gaps opens the new-note/new-card menu;
                    // cards sit above and their own context menus win.
                    .contentShape(Rectangle())
                    .onTapGesture { handleBackgroundTap() }
                    .nsContextMenu(isEnabled: noteStore.selectedNote == nil) { newItemsMenu() }
                    .coordinateSpace(name: BoardCardSpace.name)
                    .overlay(alignment: .topLeading) {
                        BoardDragReplica(session: dragSession)
                    }
                    .animation(.easeInOut(duration: 0.2), value: noteStore.rootSwitchToken)
                    .onChange(of: scrollToNoteID) { _, targetID in
                        guard let targetID else { return }
                        scrollToNoteID = nil
                        DispatchQueue.main.async {
                            withAnimation(DesignToken.Motion.morph) {
                                scrollProxy.scrollTo(targetID, anchor: .top)
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                SelectionToolbar()
                    .padding(.bottom, DesignToken.Space.md)
            }
        }
        // Same frame as the enclosing BoardViewportSpace, and below the
        // expanded editor in the ZStack — board-level image drops hit-test
        // cards, while a full editor session keeps its own drop overlay on top.
        .overlay {
            BoardImageDropOverlay { url, viewportPoint in
                handleBoardImageDrop(url: url, viewportPoint: viewportPoint)
            }
        }
    }

    // MARK: Board image drops

    /// Image dropped onto the board at `viewportPoint` (in
    /// `BoardViewportSpace`): the card under the point wins. An in-place
    /// editing card receives the insert through its live editor; any other
    /// card gets the reference appended to its content plus a border pulse.
    private func handleBoardImageDrop(url: URL, viewportPoint: CGPoint) {
        guard let (noteID, _) = cardLayout.viewportFrames.first(where: { $0.value.contains(viewportPoint) })
        else { return }

        // Only notes accept image drops — Finder cards are file browsers.
        guard noteStore.finderCards.first(where: { $0.id == noteID }) == nil else { return }

        if noteID == noteStore.inlineEditingNoteID,
           let note = noteStore.notes.first(where: { $0.id == noteID })
        {
            // Route into the mounted inline editor — appending behind its back
            // would be lost on its next debounced flush.
            MarkdownEditorView.insertDroppedImageFile(url, for: note)
            return
        }
        guard let note = noteStore.notes.first(where: { $0.id == noteID }) else { return }

        guard let data = try? Data(contentsOf: url),
              let result = try? FileStorage.saveImage(
                  data: data,
                  ext: url.pathExtension.lowercased(),
                  forNote: note,
                  preferredName: url.lastPathComponent,
              )
        else { return }
        let alt = MarkdownEditorView.dropImageAlt(for: url)
        let markdown = alt.isEmpty
            ? result.markdown
            : "![\(alt)](\(result.relativePath))"

        var base = note.content
        while base.hasSuffix("\n") {
            base.removeLast()
        }
        let newContent = base.isEmpty ? markdown + "\n" : base + "\n\n" + markdown + "\n"
        noteStore.updateContent(for: note.id, content: newContent)

        withAnimation(.easeInOut(duration: 0.18)) {
            droppedFlashID = note.id
        }
        Task {
            try? await Task.sleep(for: .seconds(1.0))
            withAnimation(.easeInOut(duration: 0.4)) {
                if droppedFlashID == note.id {
                    droppedFlashID = nil
                }
            }
        }
    }

    /// The chip row stays visible while creating a nested folder even when
    /// there are no children yet — that's where the inline editor mounts.
    private var showsChildFolderChips: Bool {
        if !childFolders.isEmpty {
            return true
        }
        if let name = folderRename.renamingFolderName {
            return childFolders.contains { $0.name == name }
        }
        return folderRename.isCreating && noteStore.selectedFolder != nil
    }

    /// Tabs layout: subfolder chips (inside a folder), then the board card
    /// stream (notes + Finder cards).
    private var tabsBoard: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            if showsChildFolderChips {
                childFolderChipRow
            }

            if isEmpty {
                EmptyStateView(
                    icon: "note.text",
                    title: l10n["noteList.empty.title"],
                    subtitle: l10n["noteList.empty.subtitle"],
                )
                .padding(.top, DesignToken.Space.xl)
            } else {
                itemGrid(boardItems)
            }
        }
    }

    /// Subfolder chips inside a folder — wrap with the board width instead of
    /// scrolling sideways. Also hosts the nested create/rename editor.
    private var childFolderChipRow: some View {
        FlowLayout(spacing: DesignToken.Space.xs, lineSpacing: 6) {
            ForEach(childFolders) { folder in
                if folderRename.renamingFolderName == folder.name {
                    tabFolderEditor(
                        iconColor: folder.color?.color ?? DesignToken.accent,
                        fill: DesignToken.surfaceInset,
                        labelColor: DesignToken.bodyText,
                    )
                } else {
                    Button {
                        noteStore.navigateToSubfolder(folder)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(folder.color?.color ?? DesignToken.accent)
                            Text(folder.displayName)
                                .font(DesignToken.Typography.caption)
                                .foregroundStyle(DesignToken.bodyText)
                                .lineLimit(1)
                            Text("\(folder.noteCount)")
                                .font(DesignToken.Typography.caption)
                                .foregroundStyle(DesignToken.mutedSoft)
                        }
                        .padding(.horizontal, DesignToken.Space.sm)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DesignToken.surfaceInset))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .nsContextMenu(isEnabled: noteStore.selectedNote == nil) {
                        NoteListMenus.folderMenu(
                            folder: folder,
                            noteStore: noteStore,
                            l10n: l10n,
                            onRename: { startRenamingFolder(folder.name) },
                            onDelete: { requestDeleteFolder(folder) },
                        )
                    }
                }
            }

            if showsChipCreateEditor {
                tabFolderEditor(
                    iconColor: DesignToken.accent,
                    fill: DesignToken.surfaceInset,
                    labelColor: DesignToken.bodyText,
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.22), value: childFolders.count)
        .animation(.easeInOut(duration: 0.22), value: folderRename.isCreating)
    }

    /// Sections layout: every folder as a collapsible header over its note cards.
    private var sectionsBoard: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.md) {
            if sections.isEmpty {
                EmptyStateView(
                    icon: "note.text",
                    title: l10n["noteList.empty.title"],
                    subtitle: l10n["noteList.empty.subtitle"],
                )
                .padding(.top, DesignToken.Space.xl)
            } else {
                ForEach(sections, id: \.folder) { section in
                    let key = section.folder ?? "__root__"
                    VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if collapsedSections.contains(key) {
                                    collapsedSections.remove(key)
                                } else {
                                    collapsedSections.insert(key)
                                }
                            }
                        } label: {
                            HStack(spacing: DesignToken.Space.xs) {
                                Image(systemName: collapsedSections.contains(key) ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(DesignToken.mutedSoft)
                                Text(section.folder.map { ($0 as NSString).lastPathComponent } ?? l10n["common.root"])
                                    .font(DesignToken.Typography.sectionHeader)
                                    .tracking(0.6)
                                    .foregroundStyle(DesignToken.muted)
                                Text("\(section.items.count)")
                                    .font(DesignToken.Typography.caption)
                                    .foregroundStyle(DesignToken.mutedSoft)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !collapsedSections.contains(key) {
                            itemGrid(section.items)
                        }
                    }
                }
            }
        }
    }

    /// Vertical card stream — SideNotes-style single column, card width fills
    /// the panel minus the shared horizontal padding. One stream for notes and
    /// Finder cards.
    private func itemGrid(_ items: [BoardItem]) -> some View {
        LazyVStack(spacing: DesignToken.Space.lg) {
            ForEach(items) { item in
                Group {
                    switch item {
                    case let .note(note):
                        if noteRename.renamingNoteID == note.id {
                            boardRenameCard(for: note)
                        } else {
                            card(for: note, in: items)
                        }
                    case let .finder(card):
                        finderCard(for: card, in: items)
                    }
                }
                .id(item.id)
            }
        }
    }

    /// Notes-only thin wrapper kept for the search results list — search stays
    /// notes-only by design, so Finder cards never appear there.
    private func noteGrid(_ notes: [Note]) -> some View {
        itemGrid(notes.map(BoardItem.note))
    }

    private func card(for note: Note, in visible: [BoardItem]) -> some View {
        BoardNoteCard(
            note: note,
            isSelected: noteStore.selection.contains(.note(note.id)),
            isTitleSelected: noteStore.selectedTitleNoteID == note.id,
            isEditing: noteStore.inlineEditingNoteID == note.id,
            isNewlyCreated: newlyCreatedNoteID == note.id,
            isDragging: dragSession.noteID == note.id,
            hoverEnabled: dragSession.noteID == nil,
            isDropped: droppedFlashID == note.id,
            layout: cardLayout,
            onTap: { flags in handleCardTap(note, flags: flags, visible: visible) },
            onTitleTap: { handleTitleTap(note) },
            onTitleAreaTap: { flags in handleTitleAreaTap(note, flags: flags, visible: visible) },
            onPinToggle: { noteStore.togglePin(on: note) },
            onToggleTask: { lineIndex in
                noteStore.toggleTask(at: lineIndex, on: note)
            },
            onContentChanged: { id, newContent in
                noteStore.updateContent(for: id, content: newContent)
            },
            onDragTick: { location, start in
                handleDragTick(.note(note), location: location, start: start, visible: visible)
            },
            onDragEnded: { handleDragEnd() },
        )
        .nsContextMenu(isEnabled: noteStore.selectedNote == nil) {
            if noteStore.selection.contains(.note(note.id)), noteStore.selection.count > 1 {
                NoteListMenus.selectionMenu(noteStore: noteStore, l10n: l10n)
            } else {
                NoteListMenus.noteMenu(
                    note: note,
                    noteStore: noteStore,
                    l10n: l10n,
                    onRename: { startRenamingNote(note) },
                    onSetColor: { color in
                        noteStore.setNoteColor(color, on: note)
                    },
                )
            }
        }
    }

    /// Finder card slot in the board stream — mirrors `card(for:in:)`.
    /// Frame feedback, selection chrome, drag, rename, and the file drag-out
    /// auto-hide suspension are owned by `FinderCardView` itself; the board
    /// only wires callbacks to shared state.
    private func finderCard(for card: FinderCard, in visible: [BoardItem]) -> some View {
        FinderCardView(
            card: card,
            isSelected: noteStore.selection.contains(.finderCard(card.id)),
            isDragging: dragSession.itemID == card.id,
            hoverEnabled: dragSession.itemID == nil,
            layout: cardLayout,
            isRenamingTitle: renamingFinderCardID == card.id,
            titleDraft: renamingFinderCardID == card.id ? $renamingFinderCardDraft : nil,
            onTap: { flags in
                handleFinderCardTap(card, flags: flags, visible: visible)
            },
            onPinToggle: { noteStore.togglePin(on: card) },
            onDragTick: { location, start in
                handleDragTick(.finder(card), location: location, start: start, visible: visible)
            },
            onDragEnded: { handleDragEnd() },
            onRenameCommit: { title in
                noteStore.renameFinderCard(card, to: title)
                renamingFinderCardID = nil
                renamingFinderCardDraft = ""
            },
            onRenameCancel: {
                renamingFinderCardID = nil
                renamingFinderCardDraft = ""
            },
            onFileDragSessionChanged: { active in
                if active {
                    AppDelegate.shared?.panelController?.suspendAutoHide()
                } else {
                    AppDelegate.shared?.panelController?.resumeAutoHide(treatAsMouseExit: true)
                }
            },
        )
        .nsContextMenu(isEnabled: noteStore.selectedNote == nil) {
            if noteStore.selection.contains(.finderCard(card.id)), noteStore.selection.count > 1 {
                NoteListMenus.selectionMenu(noteStore: noteStore, l10n: l10n)
            } else {
                FinderCardMenus.cardMenu(card: card, noteStore: noteStore, l10n: l10n, onRename: {
                    commitFinderCardRenameIfActive()
                    renamingFinderCardID = card.id
                    renamingFinderCardDraft = card.title ?? card.displayTitle
                })
            }
        }
    }

    /// Reveal the Finder card's current directory in Finder. No-op when the
    /// card has no favourites / current URL yet.
    private func revealFinderCard(_ card: FinderCard) {
        let urls = [card.currentURL].compactMap(\.self)
        guard !urls.isEmpty else { return }
        FinderCardBrowser.revealInFinder(urls)
    }

    private func commitFinderCardRenameIfActive() {
        guard let cardID = renamingFinderCardID else { return }
        if let card = noteStore.finderCards.first(where: { $0.id == cardID }) {
            noteStore.renameFinderCard(card, to: renamingFinderCardDraft)
        }
        renamingFinderCardID = nil
        renamingFinderCardDraft = ""
    }

    /// Finder-style click semantics for the Finder card's body: the body is
    /// mostly the AppKit file list which consumes its own clicks, so this
    /// fires for chrome only. A quick second plain click reveals the card's
    /// directory in Finder; ⌘-click toggles the card's selection, ⇧-click
    /// selects the range to the anchor; a plain click clears an active
    /// selection.
    private func handleFinderCardTap(_ card: FinderCard, flags: NSEvent.ModifierFlags, visible: [BoardItem]) {
        if renamingFinderCardID != card.id {
            commitFinderCardRenameIfActive()
        }
        resignFinderListFocus()
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        let mods = flags.intersection([.command, .shift])
        if mods.isEmpty, consumeDoubleClick(on: card.id) {
            revealFinderCard(card)
            return
        }
        let order = visible.map(\.selectableID)
        if mods.contains(.command) {
            noteStore.handleSelectionClick(
                on: .finderCard(card.id),
                isShift: false,
                isCommand: true,
                visibleOrder: order,
            )
        } else if mods.contains(.shift) {
            noteStore.handleSelectionClick(
                on: .finderCard(card.id),
                isShift: true,
                isCommand: false,
                visibleOrder: order,
            )
        } else if !noteStore.selection.isEmpty {
            noteStore.clearSelection()
        }
    }

    /// Finder-style click semantics for the card body: plain clicks never open
    /// the in-place editor — the body is reserved for task toggles (task rows
    /// carry their own buttons) and plain clicks only clear an active
    /// selection. A quick second plain click is classified as a double click
    /// and opens the full editor; ⌘-click toggles the card's selection,
    /// ⇧-click selects the range to the anchor. The in-place editor opens from
    /// the title row's trailing area (`handleTitleAreaTap`).
    private func handleCardTap(_ note: Note, flags: NSEvent.ModifierFlags, visible: [BoardItem]) {
        commitFinderCardRenameIfActive()
        resignFinderListFocus()
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        let mods = flags.intersection([.command, .shift])
        if mods.isEmpty, consumeDoubleClick(on: note.id) {
            openEditorFromCard(note)
            return
        }
        let order = visible.map(\.selectableID)
        if mods.contains(.command) {
            noteStore.handleSelectionClick(
                on: .note(note.id),
                isShift: false,
                isCommand: true,
                visibleOrder: order,
            )
        } else if mods.contains(.shift) {
            noteStore.handleSelectionClick(
                on: .note(note.id),
                isShift: true,
                isCommand: false,
                visibleOrder: order,
            )
        } else if !noteStore.selection.isEmpty {
            noteStore.clearSelection()
        }
        // Plain body clicks stop here on purpose: edit intent is expressed by
        // clicking the blank area trailing the title.
    }

    /// Single click on the blank area trailing a card's title — the dedicated
    /// temporary-edit toggle: collapse the editor if this card is editing,
    /// otherwise expand into it. A quick second click counts as a double click
    /// and morphs straight from the editing card into the full editor.
    /// Modifier clicks fall through to the Finder-style selection semantics
    /// (⌘ toggles, ⇧ ranges), and an active selection is cleared first,
    /// matching a plain body click.
    private func handleTitleAreaTap(_ note: Note, flags: NSEvent.ModifierFlags, visible: [BoardItem]) {
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        if !flags.intersection([.command, .shift]).isEmpty {
            handleCardTap(note, flags: flags, visible: visible)
        } else if consumeDoubleClick(on: note.id) {
            openEditorFromCard(note)
        } else if !noteStore.selection.isEmpty {
            noteStore.clearSelection()
        } else if noteStore.inlineEditingNoteID == note.id {
            noteStore.endInlineEdit()
        } else {
            noteStore.beginInlineEdit(note)
        }
    }

    /// Handles clicks on a card's title text:
    /// - First click selects the title (visual highlight) without opening editor or inline editing.
    /// - Second click within doubleClickWindow (or while selected) enters inline renaming.
    private func handleTitleTap(_ note: Note) {
        resignFinderListFocus()
        let now = Date()
        let clickCount = NSApp.currentEvent?.clickCount ?? 1
        let isDoubleClick = clickCount >= 2
            || (lastTitleTap?.id == note.id && now.timeIntervalSince(lastTitleTap!.at) < doubleClickWindow)
            || noteStore.selectedTitleNoteID == note.id

        if isDoubleClick {
            lastTitleTap = nil
            noteStore.selectedTitleNoteID = nil
            startRenamingNote(note)
            return
        }

        lastTitleTap = (note.id, now)
        noteStore.selectedTitleNoteID = note.id
    }

    /// Double-click classification window matching the system setting.
    private var doubleClickWindow: TimeInterval {
        NSEvent.doubleClickInterval
    }

    /// Records a plain tap; returns true when it completes a double click.
    private func consumeDoubleClick(on noteID: UUID) -> Bool {
        let now = Date()
        if let last = lastCardTap, last.id == noteID, now.timeIntervalSince(last.at) < doubleClickWindow {
            lastCardTap = nil
            return true
        }
        lastCardTap = (noteID, now)
        return false
    }

    // MARK: Editor morph

    /// Open the full editor, growing its box out of `note`'s card. Works from
    /// both the collapsed card and the in-place editing card — the frame is
    /// read live from the board, so a card still mid-growth hands its current
    /// frame to the editor and the two animations chain seamlessly.
    private func openEditorFromCard(_ note: Note) {
        // nil (→ inset fallback) when the card somehow never reported a frame.
        editorMorphOrigin = cardLayout.viewportFrames[note.id] != nil ? note.id : nil
        editorMorphProgress = 0
        noteStore.openNote(note)
    }

    /// Open the full editor without a card origin (search result, brand-new
    /// note) — it grows in from a subtle inset of its full frame so every
    /// entry into the editor speaks the same expansion language.
    private func openEditorWithoutCard(_ open: () -> Void) {
        editorMorphOrigin = nil
        editorMorphProgress = 0
        open()
    }

    /// Close the full editor by shrinking its box back into the card it came
    /// from; the editor is dropped once the morph has settled. The board never
    /// unmounted, so the card is exactly where the user left it.
    private func closeEditor() {
        guard noteStore.selectedNote != nil else { return }
        editorMorphGeneration += 1
        let generation = editorMorphGeneration
        withAnimation(DesignToken.Motion.morph) {
            editorMorphProgress = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + DesignToken.Motion.morphDuration) {
            guard editorMorphGeneration == generation else { return }
            editorMorphOrigin = nil
            noteStore.closeNote()
        }
    }

    /// Click on any blank board area (card gaps, margins): exit the in-place
    /// editor, then clear a multi-selection. Cards and buttons consume their
    /// own taps, so this only fires for genuinely empty space.
    private func handleBackgroundTap() {
        lastCardTap = nil
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        if noteStore.inlineEditingNoteID != nil {
            noteStore.endInlineEdit()
        }
        commitFinderCardRenameIfActive()
        resignFinderListFocus()
        if !noteStore.selection.isEmpty {
            noteStore.clearSelection()
        }
    }

    /// A click on card chrome or blank board area hands keyboard focus back to
    /// the board: a Finder list that kept first responder would otherwise keep
    /// swallowing ↑/↓/Return and ⌘⇧N after the user moved on.
    private func resignFinderListFocus() {
        guard noteStore.focusedFinderCardID != nil else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    // MARK: Drag Reorder

    /// Live reorder while press-dragging: whichever visible card the pointer
    /// is over becomes the insertion point (upper half = above, lower half =
    /// below). `reorderBoardItem` commits immediately, so cards shuffle under
    /// the cursor as it crosses neighbors — SideNotes-style. The dragged card
    /// itself hides in its slot while the floating replica follows the
    /// pointer, so these commits can never disturb the card in hand. Works
    /// for both notes and Finder cards via the shared `BoardItem` space.
    private func handleDragTick(_ item: BoardItem, location: CGPoint, start: CGPoint, visible: [BoardItem]) {
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        if dragSession.itemID != item.id {
            // First tick of the gesture: capture where inside the card the
            // pointer grabbed and lift a replica under it.
            guard let frame = cardLayout.frames[item.id] else { return }
            installDragMouseUpMonitor()
            withAnimation(.easeOut(duration: 0.12)) {
                dragSession.begin(
                    item: item,
                    grabOffset: CGSize(width: start.x - frame.minX, height: start.y - frame.minY),
                    size: frame.size,
                    pointer: location,
                )
            }
            lastReorder = nil
        }
        dragSession.move(to: location)

        for target in visible where target.id != item.id {
            guard let frame = cardLayout.frames[target.id], frame.contains(location) else { continue }
            let above = location.y < frame.midY
            if lastReorder?.target != target.id || lastReorder?.above != above {
                withAnimation(.snappy(duration: 0.22)) {
                    noteStore.reorderBoardItem(
                        item.id,
                        dropTargetID: target.id,
                        above: above,
                        in: visible,
                        persist: false, // saved once when the drag ends
                    )
                }
                lastReorder = (target.id, above)
            }
            return
        }
    }

    private func handleDragEnd() {
        removeDragMouseUpMonitor()
        lastReorder = nil
        guard let itemID = dragSession.itemID else { return }
        // The whole drag persisted nothing to disk — commit once here.
        try? SidecarStore.shared.save()
        // Drop frames of cards that left the visible set while dragging.
        let known = Set(noteStore.notes.map(\.id)).union(noteStore.finderCards.map(\.id))
        cardLayout.frames = cardLayout.frames.filter { known.contains($0.key) }
        cardLayout.viewportFrames = cardLayout.viewportFrames.filter { known.contains($0.key) }

        // Settle: the replica glides from under the pointer into the
        // committed slot, then crossfades back into the real card.
        if let slot = cardLayout.frames[itemID] {
            withAnimation(.easeInOut(duration: 0.18)) {
                dragSession.move(
                    to: CGPoint(
                        x: slot.minX + dragSession.grabOffset.width,
                        y: slot.minY + dragSession.grabOffset.height,
                    ),
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard dragSession.itemID == itemID else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    dragSession.end()
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                dragSession.end()
            }
        }
    }

    // MARK: Drag mouse-up backstop

    /// If the lazy list reclaims the source card mid-drag, the gesture's
    /// `.onEnded` never fires and the drag session would leak (card stays
    /// hidden). This local monitor watches the physical mouse-up instead; if
    /// the session is still alive shortly after release — past the settle
    /// animation — it closes the drag.
    @State private var dragMouseUpMonitor: Any?

    private func installDragMouseUpMonitor() {
        guard dragMouseUpMonitor == nil else { return }
        dragMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            removeDragMouseUpMonitor()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if dragSession.noteID != nil {
                    handleDragEnd()
                }
            }
            return event
        }
    }

    private func removeDragMouseUpMonitor() {
        guard let monitor = dragMouseUpMonitor else { return }
        NSEvent.removeMonitor(monitor)
        dragMouseUpMonitor = nil
    }

    /// Rename-in-place card: a small editor shaped like a board card.
    private func boardRenameCard(for note: Note) -> some View {
        InlineRenameEditor(
            icon: "doc.text",
            placeholder: l10n["common.noteTitlePlaceholder"],
            text: $noteRename.text,
            isFocused: $isNoteRenameFocused,
            isConflicting: noteRename.isConflicting(in: noteStore),
            iconWidth: 20,
            onCommit: { noteRename.commit(note: note, noteStore: noteStore) },
            onCancel: { noteRename.cancel(noteStore: noteStore) },
            onFocusLost: { noteRename.commitOrCancel(note: note, noteStore: noteStore) },
        )
        .padding(DesignToken.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .fill(DesignToken.solidCard),
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .strokeBorder(DesignToken.accent, lineWidth: 1.5)
        }
    }

    // MARK: - Storage Picker (in-card mode)

    private var pickerRows: some View {
        VStack(spacing: 0) {
            ForEach(StorageSettings.shared.storageRoots) { root in
                Button {
                    AppDelegate.shared?.switchRoot(to: root, temporary: true, dismissPicker: true)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(DesignToken.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root.displayName)
                                .font(DesignToken.Typography.body)
                                .foregroundStyle(DesignToken.ink)
                            Text(root.url.path(percentEncoded: false))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(DesignToken.muted)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignToken.Space.lg)
        .padding(.vertical, DesignToken.Space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Search Results

    private var searchResultsList: some View {
        VStack(spacing: 0) {
            TagFilterBar()

            ScrollView {
                VStack(spacing: 0) {
                    if trimmedQuery.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            let header = noteStore.activeTagFilter.isEmpty
                                ? l10n["search.recentNotes"]
                                : l10n["search.tagged"]
                            sectionHeader(header)
                            if allNotesSorted.isEmpty {
                                emptySearchPlaceholder(
                                    icon: "tag",
                                    message: l10n["search.noTagged"],
                                )
                            } else {
                                noteGrid(allNotesSorted)
                                    .padding(.horizontal, DesignToken.Space.lg)
                                    .padding(.bottom, DesignToken.Space.md)
                            }
                        }
                    } else if !hasAnyResults {
                        emptySearchPlaceholder(
                            icon: "doc.questionmark",
                            message: l10n["search.noResults"],
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if !titleMatches.isEmpty {
                                sectionHeader(l10n["search.titles"])
                                noteGrid(titleMatches)
                                    .padding(.horizontal, DesignToken.Space.lg)
                                    .padding(.bottom, DesignToken.Space.sm)
                            }

                            if !contentMatches.isEmpty {
                                sectionHeader(l10n["search.content"])
                                VStack(spacing: 0) {
                                    ForEach(contentMatches) { match in
                                        contentResultRow(note: match.note, snippet: match.snippet)
                                    }
                                }
                                .padding(.horizontal, DesignToken.Space.lg)
                                .padding(.bottom, DesignToken.Space.md)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { handleBackgroundTap() }
                .coordinateSpace(name: BoardCardSpace.name)
                .overlay(alignment: .topLeading) {
                    BoardDragReplica(session: dragSession)
                }
            }
        }
    }

    private func emptySearchPlaceholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Spacer().frame(height: 40)
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(DesignToken.mutedSoft)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(DesignToken.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(DesignToken.Typography.sectionHeader)
            .tracking(0.6)
            .foregroundStyle(DesignToken.muted)
            .textCase(.uppercase)
            .padding(.horizontal, DesignToken.Space.lg)
            .padding(.top, 10)
            .padding(.bottom, DesignToken.Space.xs)
    }

    /// Build an attributed snippet with ~40 chars of context around the first match, highlighted in bold amber.
    static func buildSnippet(content: String, query: String) -> AttributedString? {
        guard let range = content.range(of: query, options: .caseInsensitive) else {
            return nil
        }

        let contextChars = 40
        let snippetLower = content.index(
            range.lowerBound,
            offsetBy: -contextChars,
            limitedBy: content.startIndex,
        ) ?? content.startIndex
        let snippetUpper = content.index(
            range.upperBound,
            offsetBy: contextChars,
            limitedBy: content.endIndex,
        ) ?? content.endIndex

        var snippetText = String(content[snippetLower ..< snippetUpper])
            .replacingOccurrences(of: "\n", with: " ")

        if snippetLower > content.startIndex {
            snippetText = "…" + snippetText
        }
        if snippetUpper < content.endIndex {
            snippetText += "…"
        }

        var attributed = AttributedString(snippetText)
        attributed.foregroundColor = DesignToken.muted
        attributed.font = DesignToken.Typography.caption
        if let attrRange = attributed.range(of: query, options: .caseInsensitive) {
            attributed[attrRange].font = DesignToken.Typography.caption.bold()
            attributed[attrRange].foregroundColor = DesignToken.accent
        }
        return attributed
    }

    private func contentResultRow(note: Note, snippet: AttributedString) -> some View {
        Button {
            dismissSearch()
            openEditorWithoutCard { noteStore.openNoteFromSearch(note) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(DesignToken.muted)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                        .font(DesignToken.Typography.body)
                        .foregroundStyle(DesignToken.ink)
                        .lineLimit(1)

                    Text(snippet)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Inline Folder Editor

    private var topLevelFolders: [Folder] {
        noteStore.sortedFolders(noteStore.folders.filter(\.isTopLevel), by: .name, ascending: true)
    }

    /// Header tab strip shows the create field on home, or whenever the chip
    /// row isn't on screen (sections layout).
    private var showsHeaderCreateEditor: Bool {
        folderRename.isCreating && (noteStore.selectedFolder == nil || appSettings.boardLayout != .tabs)
    }

    /// Nested create field — only in the tabs-layout chip row inside a folder.
    private var showsChipCreateEditor: Bool {
        folderRename.isCreating && noteStore.selectedFolder != nil && appSettings.boardLayout == .tabs
    }

    /// Folders the new folder's name must not clash with — those sharing its
    /// parent: top-level on home, the current folder's children when nested.
    private var createConflictSiblings: [Folder] {
        guard let parent = noteStore.selectedFolder?.name else { return topLevelFolders }
        return noteStore.childFolders(of: parent)
    }

    /// Folders the renamed folder's name must not clash with — those sharing
    /// its parent. Never `allFolders`: that would wrongly flag unrelated
    /// nested names elsewhere in the tree.
    private func renameConflictSiblings(for folderName: String) -> [Folder] {
        let parent = (folderName as NSString).deletingLastPathComponent
        let parentPath = parent == "." ? "" : parent
        return noteStore.childFolders(of: parentPath)
    }

    /// Compact tab-shaped field used for in-place rename and new-folder create
    /// in the header strip — same height as a folder tab, not a list row.
    private func tabFolderEditor(iconColor: Color, fill: Color, labelColor: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconColor)
            TextField(l10n["common.folderNamePlaceholder"], text: folderEditorText)
                .textFieldStyle(.plain)
                .font(DesignToken.Typography.callout)
                .foregroundStyle(labelColor)
                .focused($isFolderFieldFocused)
                .onSubmit(commitFolderEditor)
                .frame(minWidth: 56, maxWidth: 140)
                .overlay(alignment: .trailing) {
                    Text(l10n["common.nameTaken"])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DesignToken.error)
                        .opacity(folderEditorIsConflicting ? 1 : 0)
                }
        }
        .padding(.horizontal, DesignToken.Space.sm + 2)
        .padding(.vertical, 4)
        .background(Capsule().fill(fill))
        .onExitCommand(perform: cancelFolderEditor)
        .onChange(of: isFolderFieldFocused) { _, focused in
            if !focused {
                focusLostFolderEditor()
            }
        }
    }

    private var folderEditorText: Binding<String> {
        folderRename.renamingFolderName != nil
            ? $folderRename.renameText
            : $folderRename.creationText
    }

    private var folderEditorIsConflicting: Bool {
        if let name = folderRename.renamingFolderName {
            return folderRename.isRenameConflicting(siblings: renameConflictSiblings(for: name))
        }
        return folderRename.isCreateConflicting(siblings: createConflictSiblings)
    }

    private func commitFolderEditor() {
        if let name = folderRename.renamingFolderName {
            folderRename.commitRename(name, noteStore: noteStore, siblings: renameConflictSiblings(for: name))
        } else {
            folderRename.commitCreate(
                parent: noteStore.selectedFolder?.name ?? "",
                noteStore: noteStore,
                siblings: createConflictSiblings,
            )
        }
    }

    private func cancelFolderEditor() {
        if folderRename.renamingFolderName != nil {
            folderRename.cancelRename()
        } else {
            folderRename.cancelCreate()
        }
    }

    private func focusLostFolderEditor() {
        // The field was just inserted and may never have stably focused — a
        // blur inside the grace window is layout noise, not the user clicking
        // away. Re-assert focus instead of cancelling the create/rename.
        if folderRename.shouldIgnoreFocusLoss {
            DispatchQueue.main.async { isFolderFieldFocused = true }
            return
        }
        if let name = folderRename.renamingFolderName {
            folderRename.commitOrCancelRename(name, noteStore: noteStore, siblings: renameConflictSiblings(for: name))
        } else {
            folderRename.commitOrCancelCreate(
                parent: noteStore.selectedFolder?.name ?? "",
                noteStore: noteStore,
                siblings: createConflictSiblings,
            )
        }
    }

    // MARK: - Actions

    private func createNote() {
        if isSearching {
            dismissSearch()
        }
        if let folder = noteStore.selectedFolder?.name {
            collapsedSections.remove(folder)
        } else {
            collapsedSections.remove("__root__")
        }
        let folder = noteStore.selectedFolder?.name ?? ""
        let note = noteStore.createNote(in: folder)
        newlyCreatedNoteID = note.id
        noteStore.beginInlineEdit(note)
        scrollToNoteID = note.id
    }

    /// Folder delete entry point, shared by the tab-bar and chip-row context
    /// menus: an empty tree keeps the plain confirm alert, a folder with notes
    /// gets the in-panel move-vs-trash choice instead.
    private func requestDeleteFolder(_ folder: Folder) {
        let prefix = folder.name + "/"
        let count = noteStore.notes.count(where: { $0.folder == folder.name || $0.folder.hasPrefix(prefix) })
        if count == 0 {
            deletingFolderName = folder.name
            showDeleteFolderConfirm = true
        } else {
            deleteFolderFlow = PendingFolderDelete(folderName: folder.name, noteCount: count)
        }
    }

    /// New Finder card in the current folder, selected and ready to rename
    /// from its card menu (no scroll needed — creation is user-triggered).
    private func createFinderCard() {
        if isSearching {
            dismissSearch()
        }
        if let folder = noteStore.selectedFolder?.name {
            collapsedSections.remove(folder)
        } else {
            collapsedSections.remove("__root__")
        }
        commitFinderCardRenameIfActive()
        let card = noteStore.createFinderCard(in: noteStore.selectedFolder?.name ?? "")
        renamingFinderCardID = nil
        renamingFinderCardDraft = ""
        noteStore.replaceSelection(with: .finderCard(card.id))
    }

    /// Right-click menu shared by the header "+" button and the blank board
    /// area: new note / new Finder card.
    private func newItemsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addActionItem(title: l10n["common.newNote"], icon: "square.and.pencil") {
            createNote()
        }
        menu.addActionItem(title: l10n["finder.card.new"], icon: "rectangle.stack.badge.plus") {
            createFinderCard()
        }
        return menu
    }

    private func startCreatingFolder() {
        folderRename.beginCreate()
        DispatchQueue.main.async { isFolderFieldFocused = true }
    }

    private func startRenamingNote(_ note: Note) {
        if noteStore.inlineEditingNoteID == note.id {
            noteStore.endInlineEdit()
        }
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        noteRename.beginRename(note)
        DispatchQueue.main.async { isNoteRenameFocused = true }
    }

    private func startRenamingFolder(_ name: String) {
        folderRename.beginRename(folderName: name)
        DispatchQueue.main.async { isFolderFieldFocused = true }
    }

    private func dismissSearch() {
        noteStore.selectedTitleNoteID = nil
        lastTitleTap = nil
        isSearchFieldFocused = false
        isSearching = false
        searchQuery = ""
        noteStore.clearTagFilter()
        if let returnFolder = noteStore.searchReturnFolder {
            noteStore.searchReturnFolder = nil
            noteStore.navigateToFolder(returnFolder)
        }
    }
}

// MARK: - Editor card morph

/// Grows the full editor's rounded box out of a note card (and shrinks it
/// back on close): `progress` 0 = the card's live frame in the content
/// coordinate space, 1 = the editor's natural full frame. Real frame
/// interpolation — layout, not a scale transform — so text keeps its natural
/// size while the growing box reveals it, the same "small rounded box becomes
/// a big rounded box" language as the in-place card editor, on the same
/// spring. Without a card origin the editor grows from a subtle inset of its
/// full frame so every entry into the editor looks alike.
private struct EditorCardMorph: ViewModifier {
    /// 0 = at the card, 1 = natural. Animated via `DesignToken.Motion.morph`.
    var progress: CGFloat
    /// The note whose card the editor morphs from (nil → inset fallback).
    let originNoteID: UUID?
    /// Live board card frames — read per animation tick, so the shrink target
    /// tracks the card even if the board reordered while editing.
    let cardLayout: BoardCardLayout
    let containerSize: CGSize

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // Clamp the spring's slight overshoot so the box never pokes outside
        // the panel or dips below full transparency.
        let t = min(max(progress, 0), 1)
        let full = CGRect(origin: .zero, size: containerSize)
        let card = originNoteID.flatMap { cardLayout.viewportFrames[$0] }
            ?? full.insetBy(dx: containerSize.width * 0.05, dy: containerSize.height * 0.06)
        let frame = CGRect.interpolate(from: card, to: full, t: t)
        return content
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.midX - containerSize.width / 2, y: frame.minY)
            .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.card))
            .opacity(Double(t))
    }
}

private extension CGRect {
    static func interpolate(from start: CGRect, to end: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * t,
            y: start.minY + (end.minY - start.minY) * t,
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t,
        )
    }
}
