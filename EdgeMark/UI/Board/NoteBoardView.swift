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
        noteStore.sortedNotes(noteStore.filteredNotes, by: appSettings.sortBy, ascending: appSettings.sortAscending)
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
                result.append((name, noteStore.sortedNotes(notes, by: appSettings.sortBy, ascending: appSettings.sortAscending)))
            }
        }
        let root = noteStore.notes.filter(\.folder.isEmpty)
        if !root.isEmpty {
            result.append((nil, noteStore.sortedNotes(root, by: appSettings.sortBy, ascending: appSettings.sortAscending)))
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
        PageLayout {
            header
        } content: {
            VStack(spacing: 0) {
                if let note = noteStore.selectedNote {
                    ExpandedNoteEditor(note: note)
                } else if noteStore.awaitingRootChoice {
                    pickerRows
                } else if isSearching {
                    searchResultsList
                } else {
                    boardContent
                }
            }
        }
        .moveConflictAlerts(noteStore: noteStore, l10n: l10n)
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
            noteStore.openNote(note)
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
        if noteStore.selectedNote != nil {
            // ExpandedNoteEditor renders its own header inside the content area.
            Text("")
                .frame(height: 0)
        } else if noteStore.awaitingRootChoice {
            VStack(spacing: 2) {
                Label(l10n["picker.chooseStorageLocation"], systemImage: "folder")
                    .font(DesignToken.Typography.heading)
                Text(l10n["menu.storageTemporary"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
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
                    tabButton(
                        title: (folder.name as NSString).lastPathComponent,
                        icon: "folder.fill",
                        isActive: noteStore.selectedFolder?.name == folder.name,
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

                if folderRename.isCreating || folderRename.renamingFolderName != nil {
                    inlineFolderEditor
                        .frame(width: 150)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func tabButton(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(DesignToken.Typography.callout)
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? DesignToken.onAccent : DesignToken.muted)
            .padding(.horizontal, DesignToken.Space.sm + 2)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? DesignToken.accent : DesignToken.ink.opacity(0)),
            )
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
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                .animation(.easeInOut(duration: 0.2), value: noteStore.rootSwitchToken)
            }
        }
    }

    /// Tabs layout: subfolder chips (inside a folder), inline folder editor, then the note grid.
    private var tabsBoard: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            if folderRename.isCreating && noteStore.selectedFolder == nil {
                inlineFolderEditor
            }

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

            if folderRename.renamingFolderName != nil {
                inlineFolderEditor
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

    private func noteGrid(_ notes: [Note]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: DesignToken.Space.sm)],
            spacing: DesignToken.Space.sm,
        ) {
            ForEach(notes) { note in
                if noteRename.renamingNoteID == note.id {
                    boardRenameCard(for: note)
                } else {
                    BoardNoteCard(note: note) {
                        noteStore.openNote(note)
                    }
                    .nsContextMenu {
                        NoteListMenus.noteMenu(
                            note: note,
                            noteStore: noteStore,
                            l10n: l10n,
                            onRename: { startRenamingNote(note) },
                        )
                    }
                }
            }
        }
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
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                .fill(DesignToken.surfaceCard),
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
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
            noteStore.openNoteFromSearch(note)
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

    private var inlineFolderEditor: some View {
        InlineRenameEditor(
            icon: "folder.fill",
            iconColor: DesignToken.accent,
            placeholder: l10n["common.folderNamePlaceholder"],
            text: folderRename.renamingFolderName != nil ? $folderRename.renameText : $folderRename.creationText,
            isFocused: $isFolderFieldFocused,
            isConflicting: folderRename.renamingFolderName != nil
                ? folderRename.isRenameConflicting(siblings: allFolders)
                : folderRename.isCreateConflicting(siblings: topLevelFolders),
            iconWidth: 20,
            onCommit: {
                if let name = folderRename.renamingFolderName {
                    folderRename.commitRename(name, noteStore: noteStore, siblings: allFolders)
                } else {
                    folderRename.commitCreate(parent: noteStore.selectedFolder?.name ?? "", noteStore: noteStore, siblings: topLevelFolders)
                }
            },
            onCancel: {
                if folderRename.renamingFolderName != nil {
                    folderRename.cancelRename()
                } else {
                    folderRename.cancelCreate()
                }
            },
            onFocusLost: {
                if let name = folderRename.renamingFolderName {
                    folderRename.commitOrCancelRename(name, noteStore: noteStore, siblings: allFolders)
                } else {
                    folderRename.commitOrCancelCreate(parent: noteStore.selectedFolder?.name ?? "", noteStore: noteStore, siblings: topLevelFolders)
                }
            },
        )
    }

    // MARK: - Actions

    private func createNote() {
        let folder = noteStore.selectedFolder?.name ?? ""
        let note = noteStore.createNote(in: folder)
        noteStore.openNote(note)
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
