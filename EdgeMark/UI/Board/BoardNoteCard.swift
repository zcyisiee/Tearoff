import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - BoardNoteCard

/// Card in the note board: light-rendered markdown thumbnail, title, and
/// meta row on a frosted glass pane floating over the vibrancy backdrop.
/// Single click expands the note (SideNotes-style in-place editing); ⌘/⇧-click
/// multi-selects; context menu reuses the shared note menu.
struct BoardNoteCard: View {
    @Environment(L10n.self) private var l10n
    @Environment(AppSettings.self) private var appSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let note: Note
    var isSelected: Bool = false
    var onOpen: (NSEvent.ModifierFlags) -> Void
    var onPinToggle: (() -> Void)?
    var onDragStart: (() -> Void)?
    /// Vertical drag-reorder: called with the drop target's id and whether the
    /// pointer landed on the card's upper half (insert above) or lower half.
    var onDrop: ((_ targetID: UUID, _ above: Bool) -> Void)?

    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var cardHeight: CGFloat = 0

    private var title: String {
        note.title.isEmpty ? L10n.shared["common.untitled"] : note.title
    }

    private var usesTint: Bool {
        appSettings.noteColorDisplay == .tint && note.color != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            Text(title)
                .font(DesignToken.Typography.callout.weight(.semibold))
                .foregroundStyle(DesignToken.bodyStrong)
                .lineLimit(1)

            Text(NoteThumbnailRenderer.attributedPreview(for: note, maxLines: 6))
                .font(DesignTokenFont.thumbnail)
                .foregroundStyle(DesignToken.bodyText)
                .lineLimit(6)
                .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 76, alignment: .topLeading)
                .overlay(alignment: .bottom) {
                    // Fade the last visible line into the card so truncation
                    // reads as a preview, not a hard cut.
                    if isSummaryClipped {
                        LinearGradient(
                            stops: [
                                .init(color: cardFill.opacity(0), location: 0),
                                .init(color: cardFill, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom,
                        )
                        .frame(height: 14)
                        .allowsHitTesting(false)
                    }
                }

            HStack(spacing: DesignToken.Space.xs) {
                TagDotsView(tags: note.tags)

                Text(note.folder.isEmpty ? L10n.shared["common.root"] : (note.folder as NSString).lastPathComponent)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Text(note.modifiedAt.homeDisplayFormat)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            }
        }
        .padding(.leading, usesTint ? DesignToken.Space.sm + 2 : DesignToken.Space.sm + 5)
        .padding(.trailing, DesignToken.Space.sm + 2)
        .padding(.vertical, DesignToken.Space.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                .fill(cardFill)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { cardHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, new in cardHeight = new }
            },
        )
        .overlay {
            if usesTint {
                // Tint mode: saturated leading edge keeps the color readable.
                RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                    .fill(note.color?.strip ?? .clear)
                    .frame(width: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
            } else if let color = note.color {
                // Strip mode: narrow color bar on the card's left edge.
                RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                    .fill(color.strip)
                    .frame(width: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
            }
        }
        .overlay(alignment: .topTrailing) {
            pinChrome
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                .strokeBorder(borderColor, lineWidth: isSelected || isDropTarget ? 1.5 : 1)
        }
        .shadow(
            color: DesignToken.ink.opacity(isHovered ? 0.10 : 0.05),
            radius: isHovered ? 6 : 3,
            y: 1,
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        .onTapGesture {
            // Modifier flags come from the live click event — ⌘/⇧ route into
            // Finder-style multi-select instead of opening the note.
            onOpen(NSApp.currentEvent?.modifierFlags ?? [])
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .onDrag {
            onDragStart?()
            return NSItemProvider(object: note.id.uuidString as NSString)
        }
        .onDrop(
            of: [UTType.text],
            delegate: CardDropDelegate(
                targetID: note.id,
                cardHeight: cardHeight,
                isTargeted: $isDropTarget,
                onDrop: { onDrop?($0, $1) },
            ),
        )
        .help(title)
    }

    // MARK: Pin chrome

    @ViewBuilder
    private var pinChrome: some View {
        if note.pinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(note.color?.strip ?? DesignToken.accent)
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

    // MARK: Fill / border

    /// The summary rarely reaches exactly 6 lines; only draw the fade when the
    /// preview plausibly overflows the visible budget (~6 lines at this width).
    private var isSummaryClipped: Bool {
        NoteThumbnailRenderer.attributedPreview(for: note, maxLines: 6).description.count > 160
    }

    private var borderColor: Color {
        if isSelected || isDropTarget {
            return note.color?.strip ?? DesignToken.accent
        }
        if isHovered {
            return DesignToken.hairline
        }
        return DesignToken.hairlineSoft
    }

    private var cardFill: Color {
        if usesTint, let color = note.color {
            return color.cardTint
        }
        return reduceTransparency ? DesignToken.surfaceCard : DesignToken.glassCard
    }
}

private enum DesignTokenFont {
    static let thumbnail = SwiftUI.Font.system(size: 11)
}

// MARK: - CardDropDelegate

/// Per-card drop target for the vertical drag-reorder. Upper half inserts the
/// dragged note above this card, lower half below.
private struct CardDropDelegate: DropDelegate {
    let targetID: UUID
    let cardHeight: CGFloat
    @Binding var isTargeted: Bool
    let onDrop: (UUID, Bool) -> Void

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        onDrop(targetID, info.location.y <= cardHeight / 2)
        return true
    }
}
