import SwiftUI

// MARK: - SelectionToolbar

/// Floating batch-action bar that rises from the bottom of the board while a
/// Finder-style multi-selection is active. Mirrors the right-click selection
/// menu: move to folder, set identity color, pin, trash.
struct SelectionToolbar: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(L10n.self) private var l10n

    var body: some View {
        if !noteStore.selection.isEmpty {
            HStack(spacing: DesignToken.Space.sm) {
                Text(l10n.t("selection.count", "\(noteStore.selection.count)"))
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.muted)
                    .lineLimit(1)

                Spacer(minLength: DesignToken.Space.sm)

                moveToMenu
                colorMenu
                pinButton

                Button {
                    noteStore.trashSelection()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignToken.error)
                }
                .buttonStyle(.plain)
                .help(l10n["selection.moveToTrash.button"])

                Button {
                    noteStore.clearSelection()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignToken.muted)
                }
                .buttonStyle(.plain)
                .help(l10n["selection.clear"])
            }
            .padding(.horizontal, DesignToken.Space.md)
            .padding(.vertical, DesignToken.Space.sm)
            .background {
                RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                            .strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
                    }
                    .shadow(color: DesignToken.ink.opacity(0.18), radius: 8, y: 2)
            }
            .padding(.horizontal, DesignToken.Space.lg)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.18), value: noteStore.selection.isEmpty)
        }
    }

    // MARK: Menus

    private var moveToMenu: some View {
        Menu {
            Button(l10n["common.root"]) {
                noteStore.moveSelection(toFolder: "")
            }
            ForEach(topLevelFolders) { folder in
                folderMenuTree(folder)
            }
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n["common.moveTo"])
    }

    private func folderMenuTree(_ folder: Folder) -> AnyView {
        let children = noteStore.childFolders(of: folder.name)
        if children.isEmpty {
            return AnyView(
                Button(folder.displayName) {
                    noteStore.moveSelection(toFolder: folder.name)
                },
            )
        }
        return AnyView(
            Menu(folder.displayName) {
                Button(l10n["common.moveHere"]) {
                    noteStore.moveSelection(toFolder: folder.name)
                }
                Divider()
                ForEach(children) { child in
                    folderMenuTree(child)
                }
            },
        )
    }

    private var colorMenu: some View {
        Menu {
            Button(L10n.shared["noteColor.none"]) {
                noteStore.setNoteColorOnSelection(nil)
            }
            Divider()
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button {
                    noteStore.setNoteColorOnSelection(color)
                } label: {
                    HStack {
                        Text(color.label)
                        Circle()
                            .fill(color.strip)
                            .frame(width: 9, height: 9)
                    }
                }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignToken.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.shared["noteColor.menu"])
    }

    private var pinButton: some View {
        Button {
            noteStore.setPinnedOnSelection(!allSelectedPinned)
        } label: {
            Image(systemName: allSelectedPinned ? "pin.slash" : "pin")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignToken.muted)
        }
        .buttonStyle(.plain)
        .help(allSelectedPinned ? l10n["note.unpin"] : l10n["note.pin"])
    }

    private var allSelectedPinned: Bool {
        let notes = noteStore.selectedNotes
        return !notes.isEmpty && notes.allSatisfy(\.pinned)
    }

    private var topLevelFolders: [Folder] {
        noteStore.sortedFolders(
            noteStore.folders.filter(\.isTopLevel),
            by: .name,
            ascending: true,
        )
    }
}
