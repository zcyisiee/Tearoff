import SwiftUI

// MARK: - FolderRowView

/// Folder row with hover highlight animation. Tap gestures (single-click select,
/// double-click open) are wired by the caller — this view only renders.
struct FolderRowView: View {
    let name: String
    let count: Int
    var date: Date?
    let iconWidth: CGFloat
    var color: TagColor?
    var isSelected: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(color?.color ?? DesignToken.accent)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignToken.onAccent)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(DesignToken.ink.opacity(0.8), in: Capsule())
                        .offset(x: 4, y: -3)
                }
            }
            .frame(width: iconWidth)

            Text(name)
                .font(DesignToken.Typography.body)
                .foregroundStyle(DesignToken.ink)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if let date {
                Text(date.homeDisplayFormat)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                .fill(rowBackground)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return DesignToken.accent.opacity(isHovered ? 0.28 : 0.2)
        }
        return DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.ghost : 0)
    }
}

// MARK: - NoteRowView

/// Note row with hover highlight animation and preview line. Tap gestures are
/// wired by the caller (single-click select, double-click open).
struct NoteRowView: View {
    let note: Note
    let iconWidth: CGFloat
    var isSelected: Bool = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(DesignToken.muted)
                .frame(width: iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    TagDotsView(tags: note.tags)

                    Text(note.title.isEmpty ? L10n.shared["common.untitled"] : note.title)
                        .font(DesignToken.Typography.body)
                        .foregroundStyle(DesignToken.ink)
                        .lineLimit(1)

                    Spacer()

                    Text(note.createdAt.homeDisplayFormat)
                        .font(DesignToken.Typography.caption)
                        .foregroundStyle(DesignToken.mutedSoft)
                }

                if !note.previewText.isEmpty {
                    Text(note.previewText)
                        .font(DesignToken.Typography.caption)
                        .foregroundStyle(DesignToken.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                .fill(rowBackground)
        }
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return DesignToken.accent.opacity(isHovered ? 0.28 : 0.2)
        }
        return DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.ghost : 0)
    }
}
