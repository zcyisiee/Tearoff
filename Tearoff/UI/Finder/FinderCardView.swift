import AppKit
import OSLog
import SwiftUI

/// Finder card on the board: identity-colored title over a mini file browser —
/// a wrapping favourites chip bar, the AppKit file list, and a breadcrumb
/// strip. Chrome mirrors `BoardNoteCard` (fill, border, pin, tap/drag/hover) so
/// the two card kinds read as siblings on the same board: single click selects
/// via the board, press-drag live-reorders, and the drag replica renders this
/// same face. The browser engine lives in `@State` and is registered with
/// `FinderBrowserRegistry` while mounted, so panel-level shortcuts can reach it.
struct FinderCardView: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(AppSettings.self) private var appSettings
    @Environment(L10n.self) private var l10n

    let card: FinderCard
    var isSelected: Bool = false
    /// True while this card is the source of an active board drag: the card
    /// hides in its slot while the floating replica carries the visuals.
    var isDragging: Bool = false
    /// True for the pointer-following drag replica: same face, static body,
    /// no gestures, no hit testing, no browser.
    var isReplica: Bool = false
    /// False while any drag is in flight — hover effects stay off mid-drag.
    var hoverEnabled: Bool = true
    /// Board-wide frame registry the drag hit-test reads.
    var layout: BoardCardLayout?
    /// Card is being renamed in place (board-owned state, like note rename).
    var isRenamingTitle: Bool = false
    var titleDraft: Binding<String>?
    var onTap: (NSEvent.ModifierFlags) -> Void
    var onPinToggle: (() -> Void)?
    /// Press-drag tick (≥8pt movement): (pointer, press start) in
    /// `BoardCardSpace`; the board owns the drag session.
    var onDragTick: ((CGPoint, CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onRenameCommit: ((String) -> Void)?
    var onRenameCancel: (() -> Void)?
    /// Called with true while a file drag-out session is in flight (board →
    /// panel suspends auto-hide).
    var onFileDragSessionChanged: ((Bool) -> Void)?

    @State private var browser = FinderCardBrowser()
    @State private var commands = FinderListCommands()
    @State private var quickLookController = FinderQuickLookController()
    @State private var isHovered = false
    @State private var isResizeHovered = false
    @State private var resizeOriginHeight: CGFloat?
    @State private var internalTitleDraft = ""
    @FocusState private var isTitleFocused: Bool
    @State private var isCancelled = false

    private var currentDraft: Binding<String> {
        titleDraft ?? $internalTitleDraft
    }

    @State private var errorMessage: String?
    @State private var persistDebouncer = Debouncer(delay: 1.0)
    /// Last left-click inside the embedded file list or path bar. SwiftUI tap
    /// gestures on the card still fire over those regions; taps arriving right
    /// after such a click are list interactions, not chrome taps, and must not
    /// reach the board's tap handling (double-click "reveal in Finder", focus
    /// resignation).
    @State private var lastEmbeddedInteraction = Date.distantPast

    /// Identity color drives the accent tiers; uncolored cards fall back to
    /// the theme accent.
    private var accentColor: Color {
        card.color?.strip ?? DesignToken.accent
    }

    var body: some View {
        if isReplica {
            cardFace {
                replicaContent
            }
        } else {
            interactiveBody
        }
    }

    // MARK: - Card chrome

    /// Shared visuals: header row + card body on the tinted card, pin chrome,
    /// border. Used verbatim by the interactive card and the drag replica.
    private func cardFace(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            content()
        }
        .padding(.horizontal, DesignToken.Space.lg)
        .padding(.vertical, DesignToken.Space.md + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .fill(cardFill)
        }
        .overlay(alignment: .topTrailing) {
            pinChrome
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .strokeBorder(borderColor, lineWidth: isSelected || isDragging ? 1.5 : 1)
        }
    }

    private var interactiveBody: some View {
        cardFace {
            headerRow
            if card.currentURL == nil {
                emptyStateContent
            } else {
                fileList
                FinderPathBar(
                    browser: browser,
                    onError: { handleError($0) },
                    onInteraction: { lastEmbeddedInteraction = Date() },
                )
            }
        }
        .background {
            // Frame feedback into the board-wide registry. Plain class
            // writes — no SwiftUI invalidation, no re-render storms.
            GeometryReader { geo in
                Color.clear
                    .onAppear { reportFrame(geo) }
                    .onChange(of: geo.frame(in: .named(BoardCardSpace.name))) { _, new in
                        layout?.frames[card.id] = new
                    }
            }
        }
        // Rest-tier depth, constant across hover/selection (same reasoning as
        // BoardNoteCard — the border alone carries hover/selected feedback).
        .shadow(color: DesignToken.ink.opacity(0.08), radius: 6, y: 2)
        .opacity(isDragging ? 0 : 1)
        .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.card))
        .overlay(alignment: .bottom) {
            if !isDragging {
                resizeHandle
            }
        }
        .onTapGesture {
            // Clicks inside the embedded file list / path bar surface here too
            // (gesture recognizers see events AppKit content also consumed).
            // Skip those — the list handles its own clicks, and forwarding
            // them would misclassify a folder double-click as the chrome
            // double-click that reveals the directory in Finder.
            guard Date().timeIntervalSince(lastEmbeddedInteraction) > 0.35 else { return }
            onTap(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named(BoardCardSpace.name))
                .onChanged { value in
                    onDragTick?(value.location, value.startLocation)
                }
                .onEnded { _ in
                    onDragEnded?()
                },
        )
        .onHover { hovering in
            guard hoverEnabled, !isDragging else {
                if isHovered {
                    isHovered = false
                }
                return
            }
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onAppear { mountBrowser() }
        .onDisappear { unmountBrowser() }
        .onChange(of: card.selectedFavoriteID) { _, _ in
            syncBrowserWithURL()
        }
        .onChange(of: card.currentPath) { _, _ in
            syncBrowserWithURL()
        }
        .onChange(of: card.sortKey) { _, _ in
            syncBrowserSort()
        }
        .onChange(of: card.sortAscending) { _, _ in
            syncBrowserSort()
        }
        .onChange(of: isRenamingTitle) { _, renaming in
            if renaming {
                isCancelled = false
                currentDraft.wrappedValue = card.title ?? card.displayTitle
                DispatchQueue.main.async {
                    isTitleFocused = true
                }
            } else {
                isTitleFocused = false
            }
        }
        .onAppear {
            if isRenamingTitle {
                isCancelled = false
                currentDraft.wrappedValue = card.title ?? card.displayTitle
                DispatchQueue.main.async {
                    isTitleFocused = true
                }
            }
        }
    }

    /// Drag-replica body: the same face with a static, non-interactive
    /// placeholder body (plain chips + a list-shaped block). The browser is
    /// never mounted and the registry never sees this card.
    private var replicaContent: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            headerRow

            if card.favorites.isEmpty {
                Text(l10n["finder.empty.noFavorites"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            }

            Rectangle()
                .fill(DesignToken.surfaceInset.opacity(0.5))
                .frame(height: card.listHeight ?? 240)
                .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        }
    }

    private var cardFill: Color {
        if let color = card.color {
            return color.cardTint
        }
        return DesignToken.solidCard
    }

    private var borderColor: Color {
        if isSelected || isDragging {
            return accentColor
        }
        if isHovered {
            return card.color?.strip ?? DesignToken.hairline
        }
        return card.color != nil ? DesignToken.clearBorder : DesignToken.hairlineSoft
    }

    // MARK: - Header row

    private func commitRename() {
        guard isRenamingTitle, !isCancelled else { return }
        onRenameCommit?(currentDraft.wrappedValue)
    }

    private func cancelRename() {
        onRenameCancel?()
    }

    /// Top row of the card: the wrapping favourite chips on the left and the
    /// header controls (view toggle / sort / ⋯) on the right, so the controls
    /// stay visible no matter how many chips wrap. A card being renamed swaps
    /// the chips for a slim title field at the title's old position; a card
    /// with no favourites shows only the right-aligned controls.
    private var headerRow: some View {
        HStack(alignment: .top, spacing: 0) {
            if isRenamingTitle {
                TextField(card.displayTitle, text: currentDraft)
                    .textFieldStyle(.plain)
                    .font(appSettings.boardTitleFont)
                    .foregroundStyle(accentColor)
                    .focused($isTitleFocused)
                    .onSubmit {
                        commitRename()
                    }
                    .onExitCommand {
                        isCancelled = true
                        cancelRename()
                    }
                    .onChange(of: isTitleFocused) { _, focused in
                        if focused {
                            DispatchQueue.main.async {
                                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                            }
                        } else if isRenamingTitle, !isCancelled {
                            commitRename()
                        }
                    }
            } else if !card.favorites.isEmpty {
                favoritesBar
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            headerControls
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Switches the embedded file list between its icon grid and list view.
    /// A single small toggle; the full header layout is reworked in a later
    /// task, so this only needs to be usable.
    private var viewModeToggle: some View {
        Button {
            let next: FinderCardViewMode = card.viewMode == .icon ? .list : .icon
            noteStore.setFinderCardViewMode(next, for: card.id)
        } label: {
            Image(systemName: card.viewMode == .icon ? "list.bullet" : "square.grid.2x2")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignToken.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, DesignToken.Space.xs)
        .help(card.viewMode == .icon ? l10n["finder.viewMode.list"] : l10n["finder.viewMode.icon"])
    }

    /// Trailing header controls: the view toggle, the sort menu, and the "⋯"
    /// menu.
    private var headerControls: some View {
        HStack(spacing: DesignToken.Space.xs) {
            viewModeToggle
            sortMenuButton
            headerMenuButton
        }
    }

    /// Header sort button — pops the sort column/direction menu at the cursor.
    private var sortMenuButton: some View {
        Button {
            showSortMenu()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignToken.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, DesignToken.Space.xs)
        .help(l10n["finder.sort.menu"])
    }

    private func showSortMenu() {
        let menu = FinderCardMenus.sortMenu(card: card, l10n: l10n) { key, ascending in
            changeSort(key: key, ascending: ascending)
        }
        NSContextMenuModifier.isShowingMenu = true
        menu.popUpAtScreenPoint(NSEvent.mouseLocation)
        NSContextMenuModifier.isShowingMenu = false
        NSContextMenuModifier.lastMenuDismissAt = Date()
    }

    /// Persists a new sort column/direction. The browser re-syncs (and reloads)
    /// through `syncBrowserSort()` when the card's `sortKey` / `sortAscending`
    /// change lands from the store.
    private func changeSort(key: FinderSortKey, ascending: Bool) {
        guard key != card.sortKey || ascending != card.sortAscending else { return }
        noteStore.setFinderCardSort(key: key, ascending: ascending, for: card.id)
    }

    /// The header's "⋯" button — pops the card's header menu at the cursor.
    private var headerMenuButton: some View {
        Button {
            showHeaderMenu()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignToken.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n["finder.header.menu"])
    }

    private func showHeaderMenu() {
        let menu = FinderCardMenus.headerMenu(
            card: card,
            noteStore: noteStore,
            browser: browser,
            l10n: l10n,
            onError: { handleError($0) },
        )
        NSContextMenuModifier.isShowingMenu = true
        menu.popUpAtScreenPoint(NSEvent.mouseLocation)
        NSContextMenuModifier.isShowingMenu = false
        NSContextMenuModifier.lastMenuDismissAt = Date()
    }

    // MARK: - Pin chrome

    @ViewBuilder
    private var pinChrome: some View {
        if card.pinned {
            // Pinned state is a button too — clicking again unpins (previously
            // this branch was a static image, so a pinned card could never be
            // unpinned from its own pin icon).
            Button(action: togglePin) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .padding(.top, DesignToken.Space.xs)
            .padding(.trailing, DesignToken.Space.xs)
            .help(l10n["note.unpin"])
        } else if isHovered {
            Button(action: togglePin) {
                Image(systemName: "pin")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignToken.mutedSoft)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .padding(.top, DesignToken.Space.xs)
            .padding(.trailing, DesignToken.Space.xs)
            .help(l10n["note.pin"])
        }
    }

    /// Pin/unpin through the store's live card — the `card` prop is a value
    /// snapshot and may be stale by click time.
    private func togglePin() {
        guard let current = noteStore.finderCards.first(where: { $0.id == card.id }) else { return }
        noteStore.togglePin(on: current)
    }

    // MARK: - Favourites bar

    /// Wrapping row of favourite-folder chips on the card's top row. Shown for
    /// any non-empty favourite set — a single favourite renders as the
    /// selected chip, since the removed title no longer names the current
    /// folder. Clicking a chip switches the card's home folder;
    /// right-clicking offers reveal / remove.
    @ViewBuilder
    private var favoritesBar: some View {
        if !card.favorites.isEmpty {
            FavoritesFlowLayout(spacing: DesignToken.Space.xs) {
                ForEach(card.favorites) { favorite in
                    Button {
                        selectFavorite(favorite)
                    } label: {
                        chipLabel(favorite, isSelected: favorite.id == card.selectedFavoriteID)
                    }
                    .buttonStyle(.plain)
                    .nsContextMenu {
                        FinderCardMenus.favoriteMenu(
                            favorite: favorite,
                            card: card,
                            noteStore: noteStore,
                            browser: browser,
                            l10n: l10n,
                            onError: { handleError($0) },
                        )
                    }
                }
            }
        }
    }

    /// Switch the card's home folder through the store's live card (the `card`
    /// prop is a value snapshot). The browser follows via
    /// `onChange(of: card.selectedFavoriteID)` → `syncBrowserWithURL`.
    private func selectFavorite(_ favorite: FinderFavorite) {
        guard let current = noteStore.finderCards.first(where: { $0.id == card.id }) else { return }
        noteStore.selectFavorite(id: favorite.id, in: current)
    }

    /// Chip visuals shared by the favourites bar and the drag replica. The
    /// font size is a per-card setting (`chipFontSize`, default 11).
    private func chipLabel(_ favorite: FinderFavorite, isSelected: Bool) -> some View {
        let fontSize = CGFloat(card.chipFontSize ?? 11)
        return HStack(spacing: DesignToken.Space.xs) {
            Image(systemName: "folder")
                .font(.system(size: max(fontSize - 2, 7), weight: .medium))
                .foregroundStyle(isSelected ? DesignToken.onAccent : accentColor)

            Text(favorite.displayName)
                .font(.system(size: fontSize))
                .foregroundStyle(isSelected ? DesignToken.onAccent : DesignToken.bodyText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 110, alignment: .leading)
        }
        .padding(.horizontal, DesignToken.Space.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(isSelected ? accentColor : DesignToken.surfaceInset))
        .contentShape(Capsule())
    }

    // MARK: - Empty state

    /// Guided empty state shown when the card has no current directory yet
    /// (no favourite selected): a primary "Choose Folder…" button and a row
    /// of common quick-access folders. Replaces the usual file list so a
    /// fresh card invites its first folder instead of showing an empty grid.
    private var emptyStateContent: some View {
        VStack(spacing: DesignToken.Space.md) {
            Spacer(minLength: 0)

            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(DesignToken.mutedSoft)

            Text(l10n["finder.empty.noFavorites"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)

            Button {
                presentFolderPicker()
            } label: {
                Label(l10n["finder.empty.chooseFolder"], systemImage: "folder.badge.plus")
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.onAccent)
                    .padding(.horizontal, DesignToken.Space.md)
                    .padding(.vertical, DesignToken.Space.sm)
                    .background(Capsule().fill(accentColor))
            }
            .buttonStyle(.plain)

            quickAccessRow

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: card.listHeight ?? 240)
        .background(DesignToken.surfaceInset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
    }

    /// A row of one-tap folder shortcuts (Desktop / Documents / Downloads /
    /// Home). Each adds and selects the folder as a favourite, same as the
    /// picker.
    private var quickAccessRow: some View {
        HStack(spacing: DesignToken.Space.sm) {
            ForEach(quickAccessLocations) { location in
                Button {
                    addFavoriteAndSelect(location.url)
                } label: {
                    VStack(spacing: DesignToken.Space.xs) {
                        Image(systemName: location.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(accentColor)

                        Text(location.title)
                            .font(DesignToken.Typography.caption)
                            .foregroundStyle(DesignToken.bodyText)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 54)
                    .padding(.vertical, DesignToken.Space.sm)
                    .background {
                        RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                            .fill(DesignToken.surfaceInset.opacity(0.7))
                    }
                    .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
                }
                .buttonStyle(.plain)
                .help(location.title)
            }
        }
    }

    /// Common folders offered in the empty state. Resolved via the user's
    /// search paths; directories that don't exist yet are filtered out.
    private var quickAccessLocations: [QuickAccessLocation] {
        let fileManager = FileManager.default
        let candidates: [(icon: String, titleKey: String, url: URL?)] = [
            ("desktopcomputer", "finder.empty.desktop", fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first),
            ("doc.on.doc", "finder.empty.documents", fileManager.urls(for: .documentDirectory, in: .userDomainMask).first),
            ("arrow.down.circle", "finder.empty.downloads", fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first),
            ("house", "finder.empty.home", fileManager.homeDirectoryForCurrentUser),
        ]
        return candidates.compactMap { candidate in
            guard let url = candidate.url, fileManager.fileExists(atPath: url.path) else { return nil }
            return QuickAccessLocation(icon: candidate.icon, title: l10n[candidate.titleKey], url: url)
        }
    }

    /// Adds a folder as a favourite and selects it — the empty state's entry
    /// point that clears the placeholder once `currentURL` resolves. Navigates
    /// the browser directly so the list fills in with no "empty folder" flash.
    private func addFavoriteAndSelect(_ url: URL) {
        guard let favorite = noteStore.addFavorite(url, to: card) else { return }
        let browser = browser
        Task { @MainActor in
            browser.navigate(to: favorite.url, recordsHistory: false)
        }
    }

    /// Presents the folder picker for the empty state's primary button.
    /// `addFavorite` already selects a newly added (or re-added) favourite, so
    /// picking a folder immediately shows its contents in the card.
    private func presentFolderPicker() {
        FinderCardMenus.presentFolderPicker(
            card: card,
            noteStore: noteStore,
            directoryURL: card.currentURL,
            allowsMultipleSelection: false,
        )
    }

    /// A one-tap folder shortcut shown in the empty state.
    private struct QuickAccessLocation: Identifiable {
        let icon: String
        let title: String
        let url: URL
        var id: String {
            url.path
        }
    }

    // MARK: - File list

    private var fileList: some View {
        Group {
            if card.viewMode == .icon {
                FinderIconListView(
                    browser: browser,
                    appearance: appearance,
                    actions: makeActions(),
                    commands: commands,
                    quickLook: quickLookController,
                    iconSize: CGFloat(card.iconSize ?? 64),
                )
            } else {
                FinderFileListView(
                    browser: browser,
                    appearance: appearance,
                    actions: makeActions(),
                    commands: commands,
                    quickLook: quickLookController,
                )
            }
        }
        .frame(height: card.listHeight ?? 240)
        .frame(maxWidth: .infinity)
        .background(DesignToken.surfaceInset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        .overlay { fileListOverlay }
        .overlay(alignment: .bottom) { errorBanner }
    }

    private var appearance: FinderListAppearance {
        FinderListAppearance(
            accent: NSColor(accentColor),
            primaryText: NSColor(DesignToken.bodyText),
            secondaryText: NSColor(DesignToken.mutedSoft),
            nameFont: .systemFont(ofSize: 12),
            metaFont: .systemFont(ofSize: 11),
            rowHeight: 22,
        )
    }

    /// Centered overlay states over the list area: load errors or an empty
    /// directory. The no-selection case is handled by `emptyStateContent`.
    @ViewBuilder
    private var fileListOverlay: some View {
        if let loadError = browser.loadError {
            switch loadError {
            case .notFound:
                overlayState(icon: "questionmark.folder", text: l10n["finder.error.notFound"])
            case .notReadable:
                overlayState(icon: "lock", text: l10n["finder.error.notReadable"])
            case let .other(message):
                overlayState(icon: "exclamationmark.triangle", text: message)
            }
        } else if !browser.isLoading, browser.entries.isEmpty {
            overlayState(icon: "folder", text: l10n["finder.empty.folder"])
        }
    }

    private func overlayState(icon: String, text: String) -> some View {
        VStack(spacing: DesignToken.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(DesignToken.mutedSoft)
            Text(text)
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func makeActions() -> FinderListActions {
        let store = noteStore
        let cardID = card.id
        return FinderListActions(
            onFocusChanged: { focused in
                store.focusedFinderCardID = focused
                    ? cardID
                    : (store.focusedFinderCardID == cardID ? nil : store.focusedFinderCardID)
            },
            onActivate: { entries in
                // Directory → navigate inside the card; anything else opens.
                if entries.count == 1, entries[0].isDirectory {
                    browser.navigate(to: entries[0].url)
                } else {
                    FinderCardBrowser.open(entries.map(\.url))
                }
            },
            onGoUp: {
                browser.goUp()
            },
            contextMenu: { entries, commands in
                FinderCardMenus.fileMenu(
                    entries: entries,
                    browser: browser,
                    commands: commands,
                    l10n: l10n,
                    onError: { handleError($0) },
                    onQuickLook: { urls in
                        showQuickLook(urls)
                    },
                    onGetInfo: { entry in
                        FinderSystemBridge.presentGetInfo(for: entry.url)
                    },
                )
            },
            onDragSessionChanged: { active in
                onFileDragSessionChanged?(active)
            },
            onListMouseDown: {
                lastEmbeddedInteraction = Date()
            },
            onQuickLook: { entries in
                showQuickLook(entries.map(\.url))
            },
            onShowInfo: { entry in
                FinderSystemBridge.presentGetInfo(for: entry.url)
            },
            onToggleHiddenFiles: {
                appSettings.showHiddenFiles.toggle()
            },
            onQuickLookClosed: {
                AppDelegate.shared?.panelController?.resumeAutoHide(treatAsMouseExit: true)
            },
            onError: { error in
                handleError(error)
            },
        )
    }

    // MARK: - Quick Look

    /// Opens Quick Look on `urls`, suspending the panel's auto-hide for the
    /// panel's lifetime and resuming it on close.
    private func showQuickLook(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        AppDelegate.shared?.panelController?.suspendAutoHide()
        quickLookController.show(urls) {
            AppDelegate.shared?.panelController?.resumeAutoHide(treatAsMouseExit: true)
        }
    }

    // MARK: - Error banner

    /// Transient operation-error banner pinned to the file list's bottom edge
    /// (the old footer row carried this; the footer itself was removed to keep
    /// the card lean). Auto-clears via `handleError`'s 3-second timer.
    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.error)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, DesignToken.Space.sm)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(DesignToken.solidCard)
                }
                .overlay {
                    Capsule().strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
                }
                .padding(DesignToken.Space.sm)
        }
    }

    // MARK: - Resize handle

    /// Bottom-edge drag handle for resizing the embedded file list. An
    /// invisible 8pt hot zone with a subtle grabber line that brightens on
    /// hover (`NSCursor.resizeUpDown`). Live drags update memory only
    /// (`persist: false`); the 1s debouncer flushes to disk when the gesture
    /// ends, so the card's own reorder drag (`minimumDistance: 8`) never
    /// steals the gesture when a drag starts on the handle.
    private var resizeHandle: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Capsule()
                .fill(isResizeHovered ? accentColor : DesignToken.hairlineSoft)
                .frame(width: 36, height: 3)
                .padding(.bottom, 2.5)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering, !isResizeHovered {
                NSCursor.resizeUpDown.push()
            } else if !hovering, isResizeHovered {
                NSCursor.pop()
            }
            isResizeHovered = hovering
        }
        .onDisappear {
            if isResizeHovered {
                NSCursor.pop()
                isResizeHovered = false
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if resizeOriginHeight == nil {
                        resizeOriginHeight = card.listHeight.map { CGFloat($0) } ?? 240
                    }
                    let newHeight = max(200, (resizeOriginHeight ?? 240) + value.translation.height)
                    noteStore.setFinderCardListHeight(Double(newHeight), for: card.id, persist: false)
                }
                .onEnded { value in
                    let origin = resizeOriginHeight ?? (card.listHeight.map { CGFloat($0) } ?? 240)
                    let newHeight = max(200, origin + value.translation.height)
                    // Always pin memory to the final height (a fast flick back to
                    // the origin can leave a stale intermediate value), but only
                    // flush to disk when there was a net height change.
                    noteStore.setFinderCardListHeight(Double(newHeight), for: card.id, persist: false)
                    if abs(newHeight - origin) > 0.5 {
                        persistDebouncer.call {
                            noteStore.saveSidecar()
                        }
                    }
                    resizeOriginHeight = nil
                },
        )
    }

    // MARK: - Browser lifecycle & wiring

    private func mountBrowser() {
        FinderBrowserRegistry.shared.register(browser: browser, commands: commands, for: card.id)

        // The `card` prop is a value snapshot — always resolve the live card
        // from the store inside long-lived closures.
        let store = noteStore
        let cardID = card.id
        browser.onCurrentURLChanged = { url in
            Task { @MainActor in
                guard let current = store.finderCards.first(where: { $0.id == cardID }) else { return }
                let storedPath: String? = {
                    guard let url else { return nil }
                    let path = url.standardizedFileURL.path
                    let home = current.selectedFavorite?.url.standardizedFileURL.path
                    return path == home ? nil : path
                }()
                guard current.currentPath != storedPath else { return }
                store.setCurrentPath(storedPath, for: current, persist: false)
                persistDebouncer.call {
                    store.saveSidecar()
                }
            }
        }

        // Seed the browser's sort from the card before the initial enumerate,
        // so the first list is already in the card's order.
        browser.sortKey = card.sortKey
        browser.sortAscending = card.sortAscending

        Task { @MainActor in
            guard let live = store.finderCards.first(where: { $0.id == cardID }) else { return }
            browser.navigate(to: live.currentURL, recordsHistory: false)
            browser.startWatching()
        }
    }

    private func unmountBrowser() {
        browser.stopWatching()
        FinderBrowserRegistry.shared.unregister(card.id)
        if noteStore.focusedFinderCardID == card.id {
            noteStore.focusedFinderCardID = nil
        }
    }

    /// Store-driven navigation (`selectFavorite`, `removeFavorite`, …) lands
    /// here; compare standardized paths so the browser's own
    /// `onCurrentURLChanged` write-back can't loop.
    ///
    /// The navigation is deferred to the main actor instead of running inline
    /// from `.onChange`. `onChange` fires during SwiftUI's view-update phase;
    /// mutating the `@Observable` browser (and, through `onCurrentURLChanged`,
    /// the `@Observable` store) from inside that phase can re-invalidate the
    /// body mid-update and wedge the card — the reported "click a chip, card
    /// freezes" failure. The target is re-derived from the *live* card on the
    /// main actor (not the `card` value snapshot captured by `onChange`), so a
    /// fast burst of chip taps always settles on the last folder clicked, and
    /// the re-checked standardized-path guard turns duplicate deferred
    /// navigations from the same update cycle into no-ops.
    private func syncBrowserWithURL() {
        let store = noteStore
        let cardID = card.id
        let browser = browser
        Task { @MainActor in
            guard let live = store.finderCards.first(where: { $0.id == cardID }) else { return }
            let target = live.currentURL?.standardizedFileURL
            guard target?.path != browser.currentURL?.standardizedFileURL.path else { return }
            browser.navigate(to: target, recordsHistory: false)
        }
    }

    /// Re-applies the card's sort column/direction to the browser and reloads.
    /// Deferred to the main actor to avoid mutating @Observable state mid-update.
    private func syncBrowserSort() {
        let cardSortKey = card.sortKey
        let cardSortAscending = card.sortAscending
        let browser = browser
        Task { @MainActor in
            guard browser.sortKey != cardSortKey || browser.sortAscending != cardSortAscending else { return }
            browser.sortKey = cardSortKey
            browser.sortAscending = cardSortAscending
            browser.reload()
        }
    }

    private func reportFrame(_ geo: GeometryProxy) {
        layout?.frames[card.id] = geo.frame(in: .named(BoardCardSpace.name))
        layout?.viewportFrames[card.id] = geo.frame(in: .named(BoardViewportSpace.name))
    }

    // MARK: - Errors

    private func handleError(_ error: Error) {
        let message = error.localizedDescription
        Log.finder.error("Finder card operation failed: \(message, privacy: .public)")
        FileLog.shared.event("finder", "card operation failed: \(message)")
        errorMessage = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled, errorMessage == message {
                errorMessage = nil
            }
        }
    }
}

private extension DesignToken {
    /// Hairline that reads on tinted cards (same helper as BoardNoteCard).
    static var clearBorder: Color {
        Color.primary.opacity(0.12)
    }
}

// MARK: - Wrapping chip layout

/// Minimal wrapping HStack for the favourites bar: lays chips left-to-right,
/// starting a new row whenever the next chip would overflow the proposed
/// width. Rows are top-aligned and each row's height is its tallest chip.
private struct FavoritesFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let rows = layoutRows(proposal: proposal, subviews: subviews)
        var size = CGSize.zero
        for row in rows {
            size.width = max(size.width, row.width)
            size.height += row.height
        }
        if rows.count > 1 {
            size.height += spacing * CGFloat(rows.count - 1)
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let rows = layoutRows(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews,
        )
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size),
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = []
        var current = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
