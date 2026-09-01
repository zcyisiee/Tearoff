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
    /// Card that just received a dropped image — pulses its border so the
    /// append is discoverable. Cleared shortly after the drop.
    @State private var droppedFlashID: UUID?

    // Folder delete confirmation
    @State private var deletingFolderName: String?
    @State private var showDeleteFolderConfirm = false
    @FocusState private var isSearchFieldFocused: Bool
    @FocusState private var isFolderFieldFocused: Bool
    @FocusState private var isNoteRenameFocused: Bool

    private var trimmedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Derived data

    /// Notes for the active tab (All → every note; folder tab → that folder only).
    private var boardNotes: [Note] {
        frozenOrder(
            noteStore.sortedNotes(noteStore.filteredNotes, by: appSettings.sortBy, ascending: appSettings.sortAscending),
        )
    }

    /// While a card is being edited in place, keep the visible order frozen at
    /// the pre-edit arrangement so save-triggered date bumps can't reshuffle
    /// the list under the user's cursor.
    private func frozenOrder(_ sorted: [Note]) -> [Note] {
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

    /// All folders sorted by path — tab bar entries.
    private var allFolders: [Folder] {
        noteStore.sortedFolders(noteStore.folders, by: .name, ascending: true)
    }

    /// Sections for the collapsible-sections layout: one per folder with notes,
    /// plus a root section. Empty folders are hidden to keep the board scannable.
    private var sections: [(folder: String?, notes: [Note])] {
        var result: [(String?, [Note])] = []
        let names = allFolders.map(\.name)
        for name in names {
            let notes = noteStore.notes.filter { $0.folder == name }
            if !notes.isEmpty {
                result.append(
                    (name, frozenOrder(noteStore.sortedNotes(notes, by: appSettings.sortBy, ascending: appSettings.sortAscending))),
                )
            }
        }
        let root = noteStore.notes.filter(\.folder.isEmpty)
        if !root.isEmpty {
            result.append(
                (nil, frozenOrder(noteStore.sortedNotes(root, by: appSettings.sortBy, ascending: appSettings.sortAscending))),
            )
        }
        return result
    }

    private var isEmpty: Bool {
        boardNotes.isEmpty && childFolders.isEmpty && !folderRename.isCreating
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
        var id: String { "content-\(note.id)" }
        let note: Note
        let snippet: AttributedString
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
        .onReceive(NotificationCenter.default.publisher(for: .panelPinStateChanged)) { _ in
            isPanelPinned = PanelSettings.shared.isPanelPinned
        }
        .onReceive(NotificationCenter.default.publisher(for: .editorCloseRequested)) { _ in
            closeEditor()
        }
        .onChange(of: noteStore.inlineEditingNoteID) { _, editingID in
            if editingID != nil {
                if editOrderSnapshot == nil {
                    editOrderSnapshot = boardNotes.map(\.id)
                }
            } else {
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
            let prefix = folderName + "/"
            let count = noteStore.notes.count(where: { $0.folder == folderName || $0.folder.hasPrefix(prefix) })
            if count > 0 {
                Text(l10n.t("alert.deleteFolder.withNotes", displayName, "\(count)"))
            } else {
                Text(l10n.t("alert.deleteFolder.empty", displayName))
            }
        }
        .onChange(of: noteStore.pendingNewFolder) { _, pending in
            guard pending else { return }
            noteStore.pendingNewFolder = false
            startCreatingFolder()
        }
        .onChange(of: noteStore.pendingRenameNote) { _, note in
            guard let note else { return }
            // A brand-new note opens expanded and ready to type — SideNotes-style.
            noteStore.pendingRenameNote = nil
            openEditorWithoutCard { noteStore.openNote(note) }
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
            HStack(spacing: DesignToken.Space.sm) {
                tabBar
                Spacer()
                HeaderIconButton(systemName: "magnifyingglass", help: l10n["common.search"]) {
                    isSearching = true
                    isSearchFieldFocused = true
                }
                HeaderIconButton(systemName: "folder.badge.plus", help: l10n["common.newFolder"]) {
                    startCreatingFolder()
                }
                HeaderIconButton(systemName: "square.and.pencil", help: l10n["common.newNote"]) {
                    createNote()
                }
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
        }
    }

    /// Folder tab strip + trash. Current tab is accent-tinted.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignToken.Space.xs) {
                tabButton(
                    title: l10n["home.title"],
                    icon: "tray.full",
                    isActive: noteStore.selectedFolder == nil,
                ) {
                    noteStore.navigateToHome()
                }

                ForEach(allFolders) { folder in
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
                                onDelete: {
                                    deletingFolderName = folder.name
                                    showDeleteFolderConfirm = true
                                },
                            )
                        }
                    }
                }

                if folderRename.isCreating {
                    tabFolderEditor(
                        iconColor: DesignToken.accent,
                        fill: DesignToken.surfaceInset,
                        labelColor: DesignToken.bodyText,
                    )
                }
            }
            .padding(.vertical, 1)
        }
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
            .contentShape(Rectangle())
            .onTapGesture { handleBackgroundTap() }
            .coordinateSpace(name: BoardCardSpace.name)
            .overlay(alignment: .topLeading) {
                BoardDragReplica(session: dragSession)
            }
            .animation(.easeInOut(duration: 0.2), value: noteStore.rootSwitchToken)
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

        if noteID == noteStore.inlineEditingNoteID,
           let note = noteStore.notes.first(where: { $0.id == noteID }) {
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
        while base.hasSuffix("\n") { base.removeLast() }
        let newContent = base.isEmpty ? markdown + "\n" : base + "\n\n" + markdown + "\n"
        noteStore.updateContent(for: note.id, content: newContent)

        withAnimation(.easeInOut(duration: 0.18)) {
            droppedFlashID = note.id
        }
        Task {
            try? await Task.sleep(for: .seconds(1.0))
            withAnimation(.easeInOut(duration: 0.4)) {
                if droppedFlashID == note.id { droppedFlashID = nil }
            }
        }
    }

    /// Tabs layout: subfolder chips (inside a folder), then the note grid.
    private var tabsBoard: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            if !childFolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignToken.Space.xs) {
                        ForEach(childFolders) { folder in
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
                            .nsContextMenu {
                                NoteListMenus.folderMenu(
                                    folder: folder,
                                    noteStore: noteStore,
                                    l10n: l10n,
                                    onRename: { startRenamingFolder(folder.name) },
                                    onDelete: {
                                        deletingFolderName = folder.name
                                        showDeleteFolderConfirm = true
                                    },
                                )
                            }
                        }
                    }
                }
            }

            if isEmpty {
                EmptyStateView(
                    icon: "note.text",
                    title: l10n["noteList.empty.title"],
                    subtitle: l10n["noteList.empty.subtitle"],
                )
                .padding(.top, DesignToken.Space.xl)
            } else {
                noteGrid(boardNotes)
            }
        }
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
                                Text("\(section.notes.count)")
                                    .font(DesignToken.Typography.caption)
                                    .foregroundStyle(DesignToken.mutedSoft)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if !collapsedSections.contains(key) {
                            noteGrid(section.notes)
                        }
                    }
                }
            }
        }
    }

    /// Vertical card stream — SideNotes-style single column, card width fills
    /// the panel minus the shared horizontal padding.
    private func noteGrid(_ notes: [Note]) -> some View {
        LazyVStack(spacing: DesignToken.Space.lg) {
            ForEach(notes) { note in
                if noteRename.renamingNoteID == note.id {
                    boardRenameCard(for: note)
                } else {
                    card(for: note, in: notes)
                }
            }
        }
    }

    private func card(for note: Note, in visible: [Note]) -> some View {
        BoardNoteCard(
            note: note,
            isSelected: noteStore.selection.contains(.note(note.id)),
            isEditing: noteStore.inlineEditingNoteID == note.id,
            isDragging: dragSession.noteID == note.id,
            hoverEnabled: dragSession.noteID == nil,
            isDropped: droppedFlashID == note.id,
            layout: cardLayout,
            onTap: { flags in handleCardTap(note, flags: flags, visible: visible) },
            onTitleAreaTap: { flags in handleTitleAreaTap(note, flags: flags, visible: visible) },
            onPinToggle: { noteStore.togglePin(on: note) },
            onToggleTask: { lineIndex in
                noteStore.toggleTask(at: lineIndex, on: note)
            },
            onContentChanged: { id, newContent in
                noteStore.updateContent(for: id, content: newContent)
            },
            onDragTick: { location, start in
                handleDragTick(note, location: location, start: start, visible: visible)
            },
            onDragEnded: { handleDragEnd() },
        )
        .nsContextMenu {
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

    /// Finder-style click semantics for the card body: plain clicks never open
    /// the in-place editor — the body is reserved for task toggles (task rows
    /// carry their own buttons) and plain clicks only clear an active
    /// selection. A quick second plain click is classified as a double click
    /// and opens the full editor; ⌘-click toggles the card's selection,
    /// ⇧-click selects the range to the anchor. The in-place editor opens from
    /// the title row's trailing area (`handleTitleAreaTap`).
    private func handleCardTap(_ note: Note, flags: NSEvent.ModifierFlags, visible: [Note]) {
        let mods = flags.intersection([.command, .shift])
        if mods.isEmpty, consumeDoubleClick(on: note.id) {
            openEditorFromCard(note)
            return
        }
        let order = visible.map { NoteStore.SelectableID.note($0.id) }
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
    private func handleTitleAreaTap(_ note: Note, flags: NSEvent.ModifierFlags, visible: [Note]) {
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

    /// Manual double-click classification: a second plain tap on the same card
    /// inside the window counts as a double click. Capped below the system
    /// double-click interval so quick toggle-clicks on the title area don't
    /// turn into editor opens. Keeps single taps instant — no count-2 gesture
    /// waiting out a multi-tap window.
    private var doubleClickWindow: TimeInterval {
        min(NSEvent.doubleClickInterval, 0.3)
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
        if noteStore.inlineEditingNoteID != nil {
            noteStore.endInlineEdit()
        }
        if !noteStore.selection.isEmpty {
            noteStore.clearSelection()
        }
    }

    // MARK: Drag Reorder

    /// Live reorder while press-dragging: whichever visible card the pointer
    /// is over becomes the insertion point (upper half = above, lower half =
    /// below). `reorderNote` commits immediately, so cards shuffle under the
    /// cursor as it crosses neighbors — SideNotes-style. The dragged card
    /// itself hides in its slot while the floating replica follows the
    /// pointer, so these commits can never disturb the card in hand.
    private func handleDragTick(_ note: Note, location: CGPoint, start: CGPoint, visible: [Note]) {
        if dragSession.noteID != note.id {
            // First tick of the gesture: capture where inside the card the
            // pointer grabbed and lift a replica under it.
            guard let frame = cardLayout.frames[note.id] else { return }
            installDragMouseUpMonitor()
            withAnimation(.easeOut(duration: 0.12)) {
                dragSession.begin(
                    note: note,
                    grabOffset: CGSize(width: start.x - frame.minX, height: start.y - frame.minY),
                    size: frame.size,
                    pointer: location,
                )
            }
            lastReorder = nil
        }
        dragSession.move(to: location)

        for target in visible where target.id != note.id {
            guard let frame = cardLayout.frames[target.id], frame.contains(location) else { continue }
            let above = location.y < frame.midY
            if lastReorder?.target != target.id || lastReorder?.above != above {
                withAnimation(.snappy(duration: 0.22)) {
                    noteStore.reorderNote(
                        note.id,
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
        guard let noteID = dragSession.noteID else { return }
        // The whole drag persisted nothing to disk — commit once here.
        try? SidecarStore.shared.save()
        // Drop frames of notes that left the visible set while dragging.
        let known = Set(noteStore.notes.map(\.id))
        cardLayout.frames = cardLayout.frames.filter { known.contains($0.key) }
        cardLayout.viewportFrames = cardLayout.viewportFrames.filter { known.contains($0.key) }

        // Settle: the replica glides from under the pointer into the
        // committed slot, then crossfades back into the real card.
        if let slot = cardLayout.frames[noteID] {
            withAnimation(.easeInOut(duration: 0.18)) {
                dragSession.move(
                    to: CGPoint(
                        x: slot.minX + dragSession.grabOffset.width,
                        y: slot.minY + dragSession.grabOffset.height,
                    )
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard dragSession.noteID == noteID else { return }
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
        noteStore.folders.filter(\.isTopLevel)
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
        folderRename.renamingFolderName != nil
            ? folderRename.isRenameConflicting(siblings: allFolders)
            : folderRename.isCreateConflicting(siblings: topLevelFolders)
    }

    private func commitFolderEditor() {
        if let name = folderRename.renamingFolderName {
            folderRename.commitRename(name, noteStore: noteStore, siblings: allFolders)
        } else {
            folderRename.commitCreate(
                parent: noteStore.selectedFolder?.name ?? "",
                noteStore: noteStore,
                siblings: topLevelFolders,
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
        if let name = folderRename.renamingFolderName {
            folderRename.commitOrCancelRename(name, noteStore: noteStore, siblings: allFolders)
        } else {
            folderRename.commitOrCancelCreate(
                parent: noteStore.selectedFolder?.name ?? "",
                noteStore: noteStore,
                siblings: topLevelFolders,
            )
        }
    }

    // MARK: - Actions

    private func createNote() {
        let folder = noteStore.selectedFolder?.name ?? ""
        let note = noteStore.createNote(in: folder)
        openEditorWithoutCard { noteStore.openNote(note) }
    }

    private func startCreatingFolder() {
        folderRename.beginCreate()
        DispatchQueue.main.async { isFolderFieldFocused = true }
    }

    private func startRenamingNote(_ note: Note) {
        noteRename.beginRename(note)
        DispatchQueue.main.async { isNoteRenameFocused = true }
    }

    private func startRenamingFolder(_ name: String) {
        folderRename.beginRename(folderName: name)
        DispatchQueue.main.async { isFolderFieldFocused = true }
    }

    private func dismissSearch() {
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
