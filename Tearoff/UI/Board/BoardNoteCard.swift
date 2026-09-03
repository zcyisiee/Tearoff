import AppKit
import SwiftUI

// MARK: - BoardCardSpace

/// Named coordinate space spanning the board's scroll content. Cards report
/// their frames in this space so the drag-reorder can hit-test which card the
/// pointer is over.
enum BoardCardSpace {
    static let name = "boardCards"
}

/// Named coordinate space anchored at the board's content container — OUTSIDE
/// the scroll view. Card frames measured here are viewport-relative (scroll
/// offset included), which is what the card→editor morph needs to know where
/// the tapped card sits on screen.
enum BoardViewportSpace {
    static let name = "boardViewport"
}

// MARK: - BoardCardLayout

/// Live card frames in `BoardCardSpace`, written by each card as it lays out.
/// Deliberately a plain class rather than `@Observable`: frame writes happen
/// on every layout pass (reorders, edits, window resizes) and must never
/// invalidate the board body. Only the drag logic reads this — from gesture
/// callbacks, which run outside observation tracking.
final class BoardCardLayout {
    var frames: [UUID: CGRect] = [:]
    /// The same cards measured in `BoardViewportSpace` (scroll-adjusted,
    /// viewport-relative) — the start/target frame for the editor morph.
    var viewportFrames: [UUID: CGRect] = [:]
}

// MARK: - BoardDragSession

/// State of an in-flight card drag. Observed by the floating replica leaf
/// only, so per-tick `pointer` writes re-render that one small view — never
/// the whole board.
@Observable
final class BoardDragSession {
    /// The board item being dragged — note or Finder card (`nil` = no active drag).
    private(set) var item: BoardItem?
    /// Where inside the card the pointer grabbed, in `BoardCardSpace`.
    private(set) var grabOffset: CGSize = .zero
    /// Captured card size — keeps the replica at the source card's footprint.
    private(set) var size: CGSize = .zero
    /// Current pointer position in `BoardCardSpace`.
    private(set) var pointer: CGPoint?

    var itemID: UUID? {
        item?.id
    }

    /// Note id when dragging a note, nil for Finder cards (kept for callers
    /// that only care about notes).
    var noteID: UUID? {
        item?.note?.id
    }

    func begin(item: BoardItem, grabOffset: CGSize, size: CGSize, pointer: CGPoint) {
        self.item = item
        self.grabOffset = grabOffset
        self.size = size
        self.pointer = pointer
    }

    func move(to point: CGPoint) {
        pointer = point
    }

    func end() {
        item = nil
        pointer = nil
    }
}

// MARK: - BoardNoteCard

/// Card in the note board: identity-colored title, structured markdown preview
/// (accent headings, tappable task circles), and meta row on a near-solid card
/// floating on the desktop (SideNotes-style; a note's identity color tints the
/// whole card). Single click on the blank area trailing the title toggles the
/// in-place rich editor (open when collapsed, collapse when open); body clicks
/// stay reserved for task toggles; a quick second click on the card is
/// classified as a double click by the board and opens the full editor;
/// ⌘/⇧-click multi-selects; press-drag live-reorders the card stream; context
/// menu reuses the shared note menu.
///
/// Dragging never moves this view directly. The board hides the source card in
/// its slot and floats a replica (`BoardDragReplica`) that follows the pointer
/// with pure gesture math, so live reorders can shuffle the list freely
/// without ever making the dragged card flash, jump, or trail the cursor.
struct BoardNoteCard: View {
    @Environment(L10n.self) private var l10n
    @Environment(AppSettings.self) private var appSettings
    @Environment(NoteStore.self) private var noteStore
    let note: Note
    var isSelected: Bool = false
    /// True when the title text is clicked/selected on this card.
    var isTitleSelected: Bool = false
    /// True while this card is expanded into its in-place editor.
    var isEditing: Bool = false
    /// True when this card was just created and should focus/select the title on mount.
    var isNewlyCreated: Bool = false
    /// True while this card is the source of an active drag: the card hides in
    /// its slot (keeping the height) while the floating replica carries the
    /// visuals.
    var isDragging: Bool = false
    /// True for the pointer-following drag replica: same face, no gestures,
    /// no hit testing.
    var isReplica: Bool = false
    /// False while any drag is in flight — the pointer sweeps neighbors that
    /// shouldn't light up with hover effects mid-drag.
    var hoverEnabled: Bool = true
    /// Brief acknowledgment after an image was dropped onto this card — the
    /// border pulses in the accent color so the append is discoverable.
    var isDropped: Bool = false
    /// Board-wide frame registry the drag hit-test reads.
    var layout: BoardCardLayout?
    /// Plain single click (modifiers included for ⌘/⇧ multi-select routing).
    var onTap: (NSEvent.ModifierFlags) -> Void
    /// Single or double click on the card title text: single click selects,
    /// double click enters inline rename.
    var onTitleTap: (() -> Void)?
    /// Single click on the blank area trailing the title row — the dedicated
    /// toggle for the in-place editor, so body clicks can stay reserved for
    /// task toggles (modifiers included for ⌘/⇧ multi-select routing).
    var onTitleAreaTap: ((NSEvent.ModifierFlags) -> Void)?
    var onPinToggle: (() -> Void)?
    /// Direct checkbox tap on a preview task row (source line index).
    var onToggleTask: ((Int) -> Void)?
    /// Rich-editor content changes while editing in place.
    var onContentChanged: ((UUID, String) -> Void)?
    /// Press-drag tick (≥8pt movement): (pointer, press start) in
    /// `BoardCardSpace`. The card itself stays stateless; the board owns the
    /// drag session.
    var onDragTick: ((CGPoint, CGPoint) -> Void)?
    /// Drag released.
    var onDragEnded: (() -> Void)?

    @State private var isHovered = false

    private var title: String {
        note.title.isEmpty ? L10n.shared["common.untitled"] : note.title
    }

    /// Identity color drives the accent tiers; uncolored notes fall back to
    /// the theme accent.
    private var accentColor: Color {
        note.color?.strip ?? DesignToken.accent
    }

    var body: some View {
        if isReplica {
            replicaBody
        } else {
            interactiveBody
        }
    }

    /// Shared visuals: title / preview / meta row on the tinted card, pin
    /// chrome, border. Used verbatim by the list card and the drag replica;
    /// depth (rest shadow / drag lift) is layered on by each consumer.
    private var cardFace: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs + 2) {
            HStack(spacing: 0) {
                titleView

                titleEditToggleArea
            }
            // Hug the title's height. The drag replica is laid out by a
            // board-content overlay that proposes the full content height,
            // and the vertically flexible Color in `titleEditToggleArea`
            // would otherwise absorb it, inflating the replica to the whole
            // board's height.
            .fixedSize(horizontal: false, vertical: true)

            if isEditing {
                inlineEditor
                    .transition(.opacity)
            } else {
                preview
                    .transition(.opacity)
            }

            HStack(spacing: DesignToken.Space.xs) {
                TagDotsView(tags: note.tags)

                Text(note.folder.isEmpty ? L10n.shared["common.root"] : (note.folder as NSString).lastPathComponent)
                    .font(appSettings.boardMetaFont)
                    .foregroundStyle(DesignToken.mutedSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Text(note.modifiedAt.homeDisplayFormat)
                    .font(appSettings.boardMetaFont)
                    .foregroundStyle(DesignToken.mutedSoft)
            }
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
                .strokeBorder(borderColor, lineWidth: isSelected || isDragging || isDropped ? 1.5 : 1)
        }
    }

    private var interactiveBody: some View {
        cardFace
            .background {
                // Frame feedback into the board-wide registry. Plain class
                // writes — no SwiftUI invalidation, no re-render storms.
                GeometryReader { geo in
                    Color.clear
                        .onAppear { reportFrame(geo) }
                        .onChange(of: geo.frame(in: .named(BoardCardSpace.name))) { _, new in
                            layout?.frames[note.id] = new
                        }
                }
            }
            // Rest-tier depth, constant across hover/selection: on the
            // translucent panel a boosted shadow reads as a misaligned
            // frosted ring around the card (top-hugging, sagging at the
            // bottom). The border alone carries hover/selected feedback;
            // the drag lift lives on the replica.
            .shadow(color: DesignToken.ink.opacity(0.08), radius: 6, y: 2)
            // Hidden in-slot while the replica carries the visuals; the
            // reserved frame keeps the layout stable for live reorders.
            .opacity(isDragging ? 0 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.card))
            // Instant single tap — double clicks are classified by the board
            // from tap timing (see NoteBoardView), so unlike a declared
            // count-2 gesture there is no multi-tap window to wait out and
            // the card responds on the click itself. Buttons inside (task
            // circles, pin) keep precedence over these gestures.
            .onTapGesture {
                onTap(NSApp.currentEvent?.modifierFlags ?? [])
            }
            // Press-drag (≥8pt) reorders the card stream. The 8pt threshold keeps
            // plain clicks editing; mouse click-drags never scroll on macOS, so
            // there is no contention with the enclosing ScrollView. Reading the
            // gesture in the board's coordinate space keeps `value.location` the
            // absolute board pointer — correct across this card's own slot
            // changes mid-drag.
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
            .help(title)
    }

    private var replicaBody: some View {
        cardFace
            .allowsHitTesting(false)
    }

    private func reportFrame(_ geo: GeometryProxy) {
        layout?.frames[note.id] = geo.frame(in: .named(BoardCardSpace.name))
        layout?.viewportFrames[note.id] = geo.frame(in: .named(BoardViewportSpace.name))
    }

    // MARK: Preview

    private static let previewBlockLimit = 6

    private var previewBlocks: [CardPreviewBlock] {
        NoteThumbnailRenderer.structuredPreview(
            for: note,
            maxLines: Self.previewBlockLimit,
            fontSize: appSettings.boardFontSize,
        )
    }

    /// SideNotes-style preview: identity-colored headings tiered by size,
    /// tappable task circles, body text at the board font size.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(previewBlocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            // Fade the last visible block into the card so truncation
            // reads as a preview, not a hard cut.
            if previewBlocks.count >= Self.previewBlockLimit {
                LinearGradient(
                    stops: [
                        .init(color: cardFill.opacity(0), location: 0),
                        .init(color: cardFill, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom,
                )
                .frame(height: 16)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: CardPreviewBlock) -> some View {
        switch block.kind {
        case let .heading(level, text):
            Text(text)
                .font(level == 2 ? appSettings.boardHeadingFont : appSettings.boardSubheadingFont)
                .foregroundStyle(level == 2 ? accentColor : accentColor.opacity(0.72))
                .lineLimit(1)
                .padding(.top, 2)

        case let .task(lineIndex, isChecked, text):
            taskRow(lineIndex: lineIndex, isChecked: isChecked, text: text)

        case let .bullet(text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(appSettings.boardBodyFont)
                    .foregroundStyle(DesignToken.mutedSoft)
                Text(text)
                    .font(appSettings.boardBodyFont)
                    .foregroundStyle(DesignToken.bodyText)
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DesignToken.hairline)
                    .frame(width: 2)
                Text(text)
                    .font(appSettings.boardBodyFont.italic())
                    .foregroundStyle(DesignToken.muted)
            }

        case let .code(text):
            Text(text)
                .font(.system(size: appSettings.boardFontSize - 1, design: .monospaced))
                .foregroundStyle(DesignToken.muted)

        case let .image(path):
            CardImageThumbnail(
                url: FileStorage.imageURL(forRelativePath: path, folder: note.folder),
            )

        case let .text(text):
            Text(text)
                .font(appSettings.boardBodyFont)
                .foregroundStyle(DesignToken.bodyText)
        }
    }

    /// Outlined circle + same-color check when done (SideNotes Daily-Tasks
    /// look). Tapping toggles the markdown marker without entering edit mode.
    private func taskRow(lineIndex: Int, isChecked: Bool, text: AttributedString) -> some View {
        Button {
            onToggleTask?(lineIndex)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                ZStack {
                    Circle()
                        .strokeBorder(isChecked ? accentColor : DesignToken.mutedSoft.opacity(0.55), lineWidth: 1.4)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(accentColor)
                    }
                }
                .frame(width: 15, height: 15)
                .padding(.top, 2)

                Text(text)
                    .font(appSettings.boardBodyFont)
                    .foregroundStyle(isChecked ? DesignToken.mutedSoft : DesignToken.bodyText)
                    .strikethrough(isChecked)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: In-place editor

    /// The note's rich editor embedded in the card. `MarkdownEditorView`
    /// flushes its debounced save on disappearance, so collapsing the card
    /// can't lose keystrokes. The leading "# Title" line only stays in the
    /// body during a newly created note's naming session (`focusTitleOnAppear`
    /// needs it in the text to select the title); existing notes strip it —
    /// the card's title row already shows the title.
    private var inlineEditor: some View {
        MarkdownEditorView(
            noteID: note.id,
            noteTitle: note.title,
            noteFolder: note.folder,
            initialContent: note.content,
            onContentChanged: { id, newContent in
                onContentChanged?(id, newContent)
            },
            showsHeadingLineInBody: isNewlyCreated,
            focusTitleOnAppear: isNewlyCreated,
        )
        .frame(height: 280)
        .frame(maxWidth: .infinity)
    }

    // MARK: Title

    /// Card title text with dedicated tap handling and selection styling.
    /// Single click selects the title; double click enters inline rename.
    private var titleView: some View {
        Text(title)
            .font(appSettings.boardTitleFont)
            .foregroundStyle(accentColor)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                if isTitleSelected {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.xs)
                        .fill(accentColor.opacity(0.18))
                }
            }
            .overlay {
                if isTitleSelected {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.xs)
                        .strokeBorder(accentColor.opacity(0.45), lineWidth: 1)
                }
            }
            .padding(.leading, -4)
            .contentShape(Rectangle())
            .onTapGesture {
                onTitleTap?()
            }
    }

    // MARK: Title edit toggle

    /// Blank area filling the title row's trailing space — the explicit
    /// temporary-edit switch. Single click expands the card into its in-place
    /// editor (or collapses it when already editing), which keeps plain body
    /// clicks readable as task toggles. A quick second click is classified by
    /// the board as a double click and opens the full editor directly. The pin
    /// chrome overlays this corner and keeps its own button precedence.
    private var titleEditToggleArea: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onTitleAreaTap?(NSApp.currentEvent?.modifierFlags ?? [])
            }
    }

    // MARK: Pin chrome

    @ViewBuilder
    private var pinChrome: some View {
        if note.pinned {
            // Pinned state is a button too — clicking again unpins (previously
            // this branch was a static image, so a pinned note could never be
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

    /// Pin/unpin through the store's live note — the `note` prop is a value
    /// snapshot and may be stale by click time.
    private func togglePin() {
        guard let current = noteStore.notes.first(where: { $0.id == note.id }) else { return }
        noteStore.togglePin(on: current)
    }

    // MARK: Fill / border

    private var borderColor: Color {
        if isDropped {
            return accentColor
        }
        if isSelected || isDragging {
            return accentColor
        }
        if isHovered {
            return note.color?.strip ?? DesignToken.hairline
        }
        return note.color != nil ? DesignToken.clearBorder : DesignToken.hairlineSoft
    }

    /// Identity color fills the entire card; uncolored cards are near-solid
    /// white/dark so they float on the desktop with only the wallpaper
    /// showing through the gaps.
    private var cardFill: Color {
        if let color = note.color {
            return color.cardTint
        }
        return DesignToken.solidCard
    }
}

// MARK: - CardImageThumbnail

/// Card-width, height-capped image thumbnail for standalone `![alt](path)`
/// preview blocks. Decodes off the main thread through the shared downsample
/// cache — a placeholder fills the slot until the frame lands, and a failed
/// decode keeps it (missing file reads as an empty slot, not a broken glyph).
/// Shared-`assets` references across cards hit the same cache entry.
private struct CardImageThumbnail: View {
    static let height: CGFloat = 120

    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignToken.hairlineSoft.opacity(0.5))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignToken.mutedSoft)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            let decoded = await ImageDecodingCache.shared.imageAsync(
                at: url,
                maxDimension: ImageDecodingCache.cardMaxDimension,
            )
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                image = decoded
            }
        }
    }
}

// MARK: - BoardDragReplica

/// Floating replica of the dragged card, mounted in the board overlay so it
/// renders above every list card. Its position is pure pointer math
/// (`pointer − grabOffset`) with zero layout feedback, so live reorders can
/// shuffle the list freely without ever making the dragged card flash, jump,
/// or trail behind the pointer.
struct BoardDragReplica: View {
    let session: BoardDragSession

    var body: some View {
        if let item = session.item, let pointer = session.pointer {
            Group {
                switch item {
                case let .note(note):
                    BoardNoteCard(
                        note: note,
                        isSelected: false,
                        isEditing: false,
                        isDragging: true,
                        isReplica: true,
                        onTap: { _ in },
                    )
                case let .finder(card):
                    FinderCardView(
                        card: card,
                        isDragging: true,
                        isReplica: true,
                        onTap: { _ in },
                    )
                }
            }
            // Pin to the captured source footprint. The board-content
            // overlay proposes its full height to the replica, and the
            // replica's natural height can also diverge from the slot (an
            // in-place editing card swaps its 280pt editor for the
            // preview), so the ghost must be capped and its content
            // clipped to the card.
            .frame(
                width: session.size.width,
                height: session.size.height,
                alignment: .topLeading,
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.card))
            // Drag lift, applied outside the clip so the soft shadow keeps
            // its edges.
            .shadow(color: DesignToken.ink.opacity(0.20), radius: 14, y: 6)
            .scaleEffect(1.015)
            .offset(
                x: pointer.x - session.grabOffset.width,
                y: pointer.y - session.grabOffset.height,
            )
            .allowsHitTesting(false)
            .transition(.opacity)
            .onDisappear {
                // Board content unmounted mid-drag (e.g. keyboard navigation):
                // release the session so the card can't stay hidden and the
                // in-memory reorder reaches disk.
                if session.noteID != nil {
                    session.end()
                    try? SidecarStore.shared.save()
                }
            }
        }
    }
}

private extension DesignToken {
    /// Hairline that reads on tinted cards — reuse the soft line at reduced
    /// prominence via the card's own color family.
    static var clearBorder: Color {
        Color.primary.opacity(0.12)
    }
}
