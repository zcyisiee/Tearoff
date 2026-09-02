import AppKit
import OSLog
import SwiftUI

/// Finder card on the board: identity-colored title over a mini file browser —
/// a favourites chip bar, a breadcrumb strip, the AppKit file list, and a meta
/// row. Chrome mirrors `BoardNoteCard` (fill, border, pin, tap/drag/hover) so
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
    var onTap: (NSEvent.ModifierFlags) -> Void
    var onTitleAreaTap: ((NSEvent.ModifierFlags) -> Void)?
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
    @State private var isHovered = false
    @State private var isResizeHovered = false
    @State private var resizeOriginHeight: CGFloat?
    @State private var titleDraft = ""
    @State private var errorMessage: String?
    @State private var persistDebouncer = Debouncer(delay: 1.0)

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

    /// Shared visuals: title row + card body on the tinted card, pin chrome,
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
            titleRow
            favouritesBar
            fileList
            if browser.currentURL != nil {
                FinderPathBar(browser: browser) { handleError($0) }
            }
            footerRow
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
        .onChange(of: isRenamingTitle) { _, renaming in
            if renaming {
                titleDraft = card.title ?? ""
            }
        }
    }

    /// Drag-replica body: the same face with a static, non-interactive
    /// placeholder body (plain chips + a list-shaped block). The browser is
    /// never mounted and the registry never sees this card.
    private var replicaContent: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
            titleRow

            if card.favorites.isEmpty {
                Text(l10n["finder.empty.noFavorites"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            } else {
                HStack(spacing: DesignToken.Space.xs) {
                    ForEach(card.favorites.prefix(4)) { favorite in
                        chipLabel(favorite, isSelected: favorite.id == card.selectedFavoriteID)
                    }
                }
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

    // MARK: - Title row

    private var titleRow: some View {
        HStack(spacing: 0) {
            if isRenamingTitle {
                TextField(card.displayTitle, text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(appSettings.boardTitleFont)
                    .foregroundStyle(accentColor)
                    .onSubmit {
                        onRenameCommit?(titleDraft)
                    }
                    .onExitCommand {
                        onRenameCancel?()
                    }
            } else {
                HStack(spacing: DesignToken.Space.xs) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accentColor)

                    Text(card.displayTitle)
                        .font(appSettings.boardTitleFont)
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                }

                titleEditToggleArea
            }

            viewModeToggle
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Blank area filling the title row's trailing space — the board's
    /// temporary-edit switch (same contract as `BoardNoteCard`).
    private var titleEditToggleArea: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onTitleAreaTap?(NSApp.currentEvent?.modifierFlags ?? [])
            }
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

    // MARK: - Pin chrome

    @ViewBuilder
    private var pinChrome: some View {
        if card.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.top, DesignToken.Space.xs)
                .padding(.trailing, DesignToken.Space.xs)
                .padding(2)
                .help(l10n["note.pinned"])
        } else if isHovered, let onPinToggle {
            Button(action: onPinToggle) {
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

    // MARK: - Favourites bar

    private var favouritesBar: some View {
        HStack(spacing: DesignToken.Space.xs) {
            if card.favorites.isEmpty {
                favoritesEmptyHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignToken.Space.xs) {
                        ForEach(card.favorites) { favorite in
                            favoriteChip(favorite)
                        }
                    }
                }
                addFavoriteButton
            }
        }
        // The bar's empty trailing area doubles as the "add favourite" drop
        // target (⌘-drops anywhere add directories); chips handle their own
        // transfer drops (inner targets win).
        .dropDestination(for: URL.self) { urls, _ in
            addFavoriteDrops(urls)
            return true
        }
    }

    private func favoriteChip(_ favorite: FinderFavorite) -> some View {
        Button {
            noteStore.selectFavorite(id: favorite.id, in: card)
        } label: {
            chipLabel(favorite, isSelected: favorite.id == card.selectedFavoriteID)
        }
        .buttonStyle(.plain)
        .nsContextMenu {
            FinderCardMenus.favoriteMenu(
                favorite: favorite,
                card: card,
                noteStore: noteStore,
                l10n: l10n,
            )
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleChipDrop(urls, into: favorite)
            return true
        }
    }

    private func chipLabel(_ favorite: FinderFavorite, isSelected: Bool) -> some View {
        HStack(spacing: DesignToken.Space.xs) {
            Image(systemName: "folder")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(isSelected ? DesignToken.onAccent : accentColor)

            Text(favorite.displayName)
                .font(DesignToken.Typography.caption)
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

    private var favoritesEmptyHint: some View {
        HStack(spacing: DesignToken.Space.xs) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(DesignToken.mutedSoft)

            Text(l10n["finder.empty.noFavorites"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)
                .lineLimit(1)

            Spacer(minLength: 0)

            addFavoriteButton
        }
        .frame(maxWidth: .infinity)
    }

    private var addFavoriteButton: some View {
        Button {
            showAddFavoritePanel()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DesignToken.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n["finder.favorite.add"])
    }

    private func showAddFavoritePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.directoryURL = browser.currentURL
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                _ = noteStore.addFavorite(url, to: card)
            }
        }
    }

    private func addFavoriteDrops(_ urls: [URL]) {
        for url in urls where Self.isDirectory(url) {
            _ = noteStore.addFavorite(url, to: card)
        }
    }

    /// Chip drop: ⌘ adds the dropped folders as favourites, otherwise the
    /// items transfer into the favourite's directory (⌥ copies, plain moves).
    private func handleChipDrop(_ urls: [URL], into favorite: FinderFavorite) {
        if NSEvent.modifierFlags.contains(.command) {
            for url in urls where Self.isDirectory(url) {
                _ = noteStore.addFavorite(url, to: card)
            }
            return
        }
        do {
            if NSEvent.modifierFlags.contains(.option) {
                try browser.copy(urls, into: favorite.url)
            } else {
                try browser.move(urls, into: favorite.url)
            }
        } catch {
            handleError(error)
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
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
                )
            } else {
                FinderFileListView(
                    browser: browser,
                    appearance: appearance,
                    actions: makeActions(),
                    commands: commands,
                )
            }
        }
        .frame(height: card.listHeight ?? 240)
        .frame(maxWidth: .infinity)
        .background(DesignToken.surfaceInset.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        .overlay { fileListOverlay }
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

    /// Centered overlay states over the list area: nothing selected, load
    /// errors, or an empty directory.
    @ViewBuilder
    private var fileListOverlay: some View {
        if card.selectedFavorite == nil {
            overlayState(icon: "folder.badge.plus", text: l10n["finder.empty.selectFavorite"])
        } else if let loadError = browser.loadError {
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
                )
            },
            onDragSessionChanged: { active in
                onFileDragSessionChanged?(active)
            },
            onError: { error in
                handleError(error)
            },
        )
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: DesignToken.Space.xs) {
            if let errorMessage {
                Text(errorMessage)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.error)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(l10n.t("finder.itemCount", "\(browser.totalCount)"))
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            }

            Spacer(minLength: 0)

            Text(card.folder.isEmpty ? l10n["common.root"] : (card.folder as NSString).lastPathComponent)
                .font(appSettings.boardMetaFont)
                .foregroundStyle(DesignToken.mutedSoft)
                .lineLimit(1)
                .truncationMode(.middle)
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
            guard let current = store.finderCards.first(where: { $0.id == cardID }) else { return }
            let storedPath: String? = {
                guard let url else { return nil }
                let path = url.standardizedFileURL.path
                let home = current.selectedFavorite?.url.standardizedFileURL.path
                return path == home ? nil : path
            }()
            store.setCurrentPath(storedPath, for: current, persist: false)
            persistDebouncer.call {
                store.saveSidecar()
            }
        }

        browser.navigate(to: card.currentURL, recordsHistory: false)
        browser.startWatching()
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
    private func syncBrowserWithURL() {
        let target = card.currentURL?.standardizedFileURL
        guard target?.path != browser.currentURL?.standardizedFileURL.path else { return }
        browser.navigate(to: target, recordsHistory: false)
    }

    private func reportFrame(_ geo: GeometryProxy) {
        layout?.frames[card.id] = geo.frame(in: .named(BoardCardSpace.name))
        layout?.viewportFrames[card.id] = geo.frame(in: .named(BoardViewportSpace.name))
    }

    // MARK: - Errors

    private func handleError(_ error: Error) {
        let message = error.localizedDescription
        Log.finder.error("Finder card operation failed: \(message, privacy: .public)")
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
