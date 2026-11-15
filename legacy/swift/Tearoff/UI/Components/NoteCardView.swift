import SwiftUI

struct NoteCardView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(DesignToken.Typography.heading)
                    .foregroundStyle(DesignToken.bodyStrong)
                    .lineLimit(1)

                Spacer()

                Text(note.createdAt.homeDisplayFormat)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
            }

            Text(note.previewText)
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.muted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignToken.Space.sm + 2)
        .background(DesignToken.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                .strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
        }
    }
}
