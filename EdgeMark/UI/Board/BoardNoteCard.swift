import SwiftUI

// MARK: - BoardNoteCard

/// Card in the note board: light-rendered markdown thumbnail, title, and
/// meta row. Single click expands the note (SideNotes-style in-place
/// editing); context menu reuses the shared note menu.
struct BoardNoteCard: View {
    @Environment(L10n.self) private var l10n
    @Environment(AppSettings.self) private var appSettings
    let note: Note
    var isHighlighted: Bool = false
    var onOpen: () -> Void

    @State private var isHovered = false

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

            Text(NoteThumbnailRenderer.attributedPreview(for: note, maxLines: 5))
                .font(DesignTokenFont.thumbnail)
                .foregroundStyle(DesignToken.bodyText)
                .lineLimit(5)
                .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 68, alignment: .topLeading)

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
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                .strokeBorder(
                    isHighlighted ? (note.color?.strip ?? DesignToken.accent) : (isHovered ? DesignToken.hairline : DesignToken.hairlineSoft),
                    lineWidth: isHighlighted ? 1.5 : 1,
                )
        }
        .shadow(
            color: DesignToken.ink.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 5 : 3,
            y: 1,
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        .onTapGesture(perform: onOpen)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .help(title)
    }

    private var cardFill: Color {
        if usesTint, let color = note.color {
            return color.cardTint
        }
        return DesignToken.surfaceCard
    }
}

private enum DesignTokenFont {
    static let thumbnail = SwiftUI.Font.system(size: 11)
}
