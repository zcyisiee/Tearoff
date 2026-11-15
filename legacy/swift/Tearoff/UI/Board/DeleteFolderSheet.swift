import SwiftUI

// MARK: - DeleteFolderSheet

/// In-panel overlay for deleting a folder that still contains notes — the app
/// is a compact floating panel, so instead of a window sheet the user picks
/// between moving the notes elsewhere (default) and trashing the folder with
/// everything in it. Rendered as a card over a dimmed, tap-to-cancel scrim.
struct DeleteFolderSheet: View {
    let folderName: String
    let noteCount: Int
    let noteStore: NoteStore
    let l10n: L10n
    let onCancel: () -> Void

    /// Move notes out is the default — trashing content is the last resort.
    @State private var moveNotes = true
    /// Destination folder path for the move; "" = root. Defaults to the
    /// deleted folder's parent (root for a top-level folder).
    @State private var destination: String

    init(
        folderName: String,
        noteCount: Int,
        noteStore: NoteStore,
        l10n: L10n,
        onCancel: @escaping () -> Void,
    ) {
        self.folderName = folderName
        self.noteCount = noteCount
        self.noteStore = noteStore
        self.l10n = l10n
        self.onCancel = onCancel
        let parent = (folderName as NSString).deletingLastPathComponent
        _destination = State(initialValue: parent == "." ? "" : parent)
    }

    private var displayName: String {
        (folderName as NSString).lastPathComponent
    }

    /// Every folder except the one being deleted and its descendants — legal
    /// move destinations. The picker additionally offers Root ("").
    private var destinationFolders: [Folder] {
        let prefix = folderName + "/"
        return noteStore.sortedFolders(
            noteStore.folders.filter { $0.name != folderName && !$0.name.hasPrefix(prefix) },
            by: .name,
            ascending: true,
        )
    }

    var body: some View {
        ZStack {
            DesignToken.ink.opacity(0.15)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            card
                .frame(maxWidth: 280)
                .shadow(color: DesignToken.ink.opacity(0.18), radius: 12, y: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nsContextMenuBarrier()
        .onExitCommand(perform: onCancel)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.md) {
            Text(l10n["alert.deleteFolder.title"])
                .font(DesignToken.Typography.heading)
                .foregroundStyle(DesignToken.bodyStrong)

            Text(l10n.t("alert.deleteFolder.withNotesChoose", displayName, "\(noteCount)"))
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.muted)
                .fixedSize(horizontal: false, vertical: true)

            choiceRow(
                isSelected: moveNotes,
                title: l10n.t("alert.deleteFolder.moveNotes", "\(noteCount)"),
            ) {
                moveNotes = true
            }

            if moveNotes {
                Picker(selection: $destination) {
                    Text(l10n["common.root"]).tag("")
                    ForEach(destinationFolders) { folder in
                        Text(folder.isTopLevel ? folder.displayName : folder.name)
                            .tag(folder.name)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            choiceRow(
                isSelected: !moveNotes,
                title: l10n.t("alert.deleteFolder.deleteWithNotes", "\(noteCount)"),
                tint: DesignToken.error,
            ) {
                moveNotes = false
            }

            HStack(spacing: DesignToken.Space.sm) {
                Spacer()
                Button(l10n["common.cancel"], action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if moveNotes {
                    Button(l10n["alert.deleteFolder.confirmMove"]) {
                        noteStore.dissolveFolder(folderName, movingNotesTo: destination)
                        onCancel()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(l10n["common.delete"], role: .destructive) {
                        noteStore.trashFolder(folderName)
                        onCancel()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(DesignToken.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .fill(DesignToken.solidCard),
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .strokeBorder(DesignToken.hairline, lineWidth: 1)
        }
    }

    /// Radio-style choice row — plain buttons with circle glyphs so the rows
    /// stay compact in the narrow panel.
    private func choiceRow(
        isSelected: Bool,
        title: String,
        tint: Color = DesignToken.accent,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DesignToken.Space.sm) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? tint : DesignToken.mutedSoft)
                Text(title)
                    .font(DesignToken.Typography.callout)
                    .foregroundStyle(DesignToken.bodyText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignToken.Space.sm)
            .padding(.vertical, DesignToken.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                    .fill(isSelected ? DesignToken.accentSubtle.opacity(0.5) : DesignToken.surfaceInset),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
