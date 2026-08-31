import Cocoa
import SwiftUI

// MARK: - ExpandedNoteEditor

/// The note in its expanded, editing state — fills the board content area.
/// Carries the full editor experience (find bar, outline panel/breadcrumb,
/// slash commands, external-change alerts) that used to live in
/// `EditorScreen`; the header's back button becomes a collapse button.
struct ExpandedNoteEditor: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(AppSettings.self) var appSettings
    @Environment(L10n.self) var l10n

    @State private var showDeleteConfirm = false
    @State private var pendingEditorReload: String? = nil
    @State private var isFindBarShowing = false
    @State private var outline = OutlineState()

    let note: Note
    /// Close path supplied by the board — plays the shrink-into-card morph
    /// before the store closes the note. Falls back to a direct close.
    var onRequestClose: (() -> Void)? = nil

    private var showsOutlinePanel: Bool {
        appSettings.outlineVisible && appSettings.outlinePosition == .right
    }

    private var showsOutlineBreadcrumb: Bool {
        appSettings.outlineVisible && appSettings.outlinePosition == .top
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if showsOutlineBreadcrumb {
                OutlineBreadcrumbView(outline: outline)
                    .padding(.bottom, DesignToken.Space.xs)
            }

            DesignToken.hairlineSoft.frame(height: 1)

            HStack(spacing: 0) {
                editor(for: note)
                if showsOutlinePanel {
                    DesignToken.hairlineSoft.frame(width: 1)
                    OutlinePanelView(outline: outline)
                        .frame(width: appSettings.outlinePanelWidth)
                }
            }
            .frame(maxHeight: .infinity)
        }
        // The editor is one enlarged solid card floating on the desktop,
        // matching the board-card language (SideNotes-style single surface).
        .padding(.horizontal, DesignToken.Space.lg)
        .padding(.top, DesignToken.Space.sm)
        .padding(.bottom, DesignToken.Space.md)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .fill(DesignToken.solidCard)
        }
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                .strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignToken.Radius.card))
        .alert(l10n["alert.deleteNote.title"], isPresented: $showDeleteConfirm) {
            Button(l10n["common.delete"], role: .destructive) {
                noteStore.closeNote()
                noteStore.deleteNote(note)
            }
            Button(l10n["common.cancel"], role: .cancel) {}
        }
        .alert(
            l10n["alert.externalChange.title"],
            isPresented: Binding(
                get: { noteStore.pendingExternalChange != nil },
                set: {
                    if !$0 {
                        noteStore.pendingExternalChange = nil
                    }
                },
            ),
        ) {
            Button(l10n["alert.externalChange.keepEdgeMarkEdits"]) {
                noteStore.resolveExternalChange(keepEdgeMarkEdits: true)
            }
            Button(l10n["alert.externalChange.reloadFromDisk"], role: .destructive) {
                noteStore.resolveExternalChange(keepEdgeMarkEdits: false)
            }
        } message: {
            Text(l10n["alert.externalChange.message"])
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: DesignToken.Space.xs) {
            HStack(spacing: DesignToken.Space.xs) {
                HeaderIconButton(
                    systemName: "chevron.down",
                    help: l10n["common.back"],
                ) {
                    if let onRequestClose {
                        onRequestClose()
                    } else {
                        noteStore.closeNote()
                    }
                }

                Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                    .font(DesignToken.Typography.heading)
                    .foregroundStyle(DesignToken.bodyStrong)
                    .lineLimit(1)

                Text(note.displayDirectory)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                NoteColorMenuButton(note: note)

                RawSourceToggleButton()

                OutlineToggleButton()

                CopyMenuButton(note: note)

                DeleteIconButton {
                    showDeleteConfirm = true
                }
            }

            HStack(spacing: DesignToken.Space.md) {
                DateLabelView(
                    systemName: "clock",
                    date: note.modifiedAt.homeDisplayFormat,
                    tooltip: L10n.shared.t("editor.modifiedAt", note.modifiedAt.homeDisplayFormat),
                )

                DateLabelView(
                    systemName: "calendar",
                    date: note.createdAt.homeDisplayFormat,
                    tooltip: L10n.shared.t("editor.createdAt", note.createdAt.homeDisplayFormat),
                )

                Spacer()
            }
        }
        .padding(.horizontal, DesignToken.Space.lg)
        .padding(.top, DesignToken.Space.sm + 2)
        .padding(.bottom, DesignToken.Space.xs)
    }

    // MARK: - Editor

    private func editor(for note: Note) -> some View {
        MarkdownEditorView(
            noteID: note.id,
            noteTitle: note.title,
            noteFolder: note.folder,
            initialContent: note.content,
            onContentChanged: { id, newContent in
                noteStore.updateContent(for: id, content: newContent)
            },
            pendingReload: $pendingEditorReload,
            showFindBar: $isFindBarShowing,
            onNavigateNext: { noteStore.navigateToNextNote(sortedBy: appSettings) },
            onNavigatePrevious: { noteStore.navigateToPreviousNote(sortedBy: appSettings) },
            outline: outline,
        )
        .onAppear {
            noteStore.onNeedEditorReload = { content in
                pendingEditorReload = content
            }
        }
        .onChange(of: noteStore.pendingEditorFind) { _, pending in
            guard pending else { return }
            noteStore.pendingEditorFind = false
            isFindBarShowing = true
        }
    }
}

// MARK: - Note Color Menu Button

/// Editor-header identity color picker. Shows the current color as a filled
/// dot (or a palette glyph when uncolored); menu lists the palette + none.
struct NoteColorMenuButton: View {
    @Environment(NoteStore.self) private var noteStore
    let note: Note

    @State private var isHovered = false

    var body: some View {
        Menu {
            Section {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button {
                        noteStore.setNoteColor(color, on: note)
                    } label: {
                        if note.color == color {
                            Label(color.label, systemImage: "checkmark")
                        } else {
                            Text(color.label)
                        }
                    }
                }
            }
            Section {
                Button(L10n.shared["noteColor.none"]) {
                    noteStore.setNoteColor(nil, on: note)
                }
            }
        } label: {
            ZStack {
                if let color = note.color {
                    Circle()
                        .fill(color.strip)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignToken.muted)
                }
            }
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                    .fill(DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.hover : 0))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.shared["noteColor.menu"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Raw Source Toggle Button

/// Source-view switch in the editor header; accent-tinted while the note is
/// presented as raw Markdown. The choice persists via AppSettings.
struct RawSourceToggleButton: View {
    @State private var isHovered = false

    private var isRaw: Bool {
        AppSettings.shared.editorRawSourceMode
    }

    var body: some View {
        Button {
            AppSettings.shared.editorRawSourceMode.toggle()
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .iconHoverChrome(isHovered: isHovered, isActive: isRaw)
        }
        .buttonStyle(.plain)
        .help(L10n.shared["editor.toggleRawSource"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Outline Toggle Button

/// Outline icon in the editor header; accent-tinted while the outline is shown.
struct OutlineToggleButton: View {
    @State private var isHovered = false

    private var isVisible: Bool {
        AppSettings.shared.outlineVisible
    }

    var body: some View {
        Button {
            AppSettings.shared.outlineVisible.toggle()
        } label: {
            Image(systemName: "list.bullet.indent")
                .iconHoverChrome(isHovered: isHovered, isActive: isVisible)
        }
        .buttonStyle(.plain)
        .help(L10n.shared["editor.toggleOutline"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Copy Menu Button

/// Copy icon that opens a menu with plain text and Markdown copy options.
/// If text is selected in the editor, copies the selection; otherwise copies the whole document.
struct CopyMenuButton: View {
    let note: Note

    @State private var isHovered = false

    var body: some View {
        let l10n = L10n.shared
        Menu {
            Button(l10n["common.copyPlainText"]) {
                let selected = Self.getSelectedText()
                let source = selected.isEmpty ? note.content : selected
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Note.plainText(from: source), forType: .string)
            }
            Button(l10n["common.copyMarkdown"]) {
                let selected = Self.getSelectedText()
                let text = selected.isEmpty ? note.content : selected
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            Button(l10n["common.copyRTF"]) {
                let selected = Self.getSelectedText()
                let source = selected.isEmpty ? note.content : selected
                let pb = NSPasteboard.general
                pb.clearContents()
                if let rtf = Note.rtfData(from: source) {
                    pb.setData(rtf, forType: .rtf)
                } else {
                    pb.setString(Note.plainText(from: source), forType: .string)
                }
            }
        } label: {
            Image(systemName: "doc.on.doc")
                .iconHoverChrome(isHovered: isHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n["editor.copyNote"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private static func getSelectedText() -> String {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView,
              tv.selectedRange().length > 0
        else { return "" }
        return (tv.string as NSString).substring(with: tv.selectedRange())
    }
}

// MARK: - Delete Icon Button

/// Trash icon that turns red on hover.
struct DeleteIconButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovered ? DesignToken.error : DesignToken.muted)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                        .fill(DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.hover : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.shared["editor.deleteNote"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Date Label View

/// Icon + date text in a compact row with hover tooltip.
struct DateLabelView: View {
    let systemName: String
    let date: String
    let tooltip: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemName)
            Text(date)
        }
        .font(DesignToken.Typography.caption)
        .foregroundStyle(DesignToken.mutedSoft)
        .contentShape(Rectangle())
        .help(tooltip)
    }
}
