import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

// MARK: - Image provider

/// Resolves markdown image references (`![alt](path)`) for the engine's
/// `styleImageLinks` renderer. Accepts both path dialects the app has ever
/// written — shared `assets/…` (Typora-style) and legacy hidden
/// `.NoteName/IMG-uuid.ext` — resolving them relative to the note's folder.
/// Decoding is downsampled and cached by `ImageDecodingCache` (path + mtime),
/// so restyles never re-read image bytes.
struct TearoffImageProvider: EmbeddedImageProvider {
    let noteFolder: String

    func image(for request: EmbeddedImageRequest) -> NSImage? {
        // request.name is the relative path, e.g. "assets/IMG_….png"
        // or legacy ".My-Note/IMG-uuid.png".
        guard !request.name.isEmpty, !request.name.hasPrefix("/") else { return nil }
        var base = FileStorage.rootURL
        if !noteFolder.isEmpty {
            base = base.appendingPathComponent(noteFolder, isDirectory: true)
        }
        return ImageDecodingCache.shared.image(
            at: base.appendingPathComponent(request.name),
            maxDimension: ImageDecodingCache.editorMaxDimension,
        )
    }

    func fingerprint() -> AnyHashable {
        noteFolder
    }
}

// MARK: - MarkdownEditorView

/// SwiftUI wrapper around NativeTextViewWrapper (swift-markdown-engine).
/// Manages heading stripping, save debouncing, font observation, and the
/// slash-command popup.
struct MarkdownEditorView: View {
    let noteID: UUID
    let noteTitle: String
    let noteFolder: String
    let initialContent: String
    let onContentChanged: (UUID, String) -> Void
    /// Set to new full note content to reload the editor (e.g. from file watcher).
    /// Cleared automatically after the view applies it.
    @Binding var pendingReload: String?
    /// When true, the find bar overlay is visible. Driven by EditorScreen via ⌘F routing.
    var showFindBar: Binding<Bool> = .constant(false)
    var onNavigateNext: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?
    /// Outline state fed from the editor text; nil disables outline tracking.
    var outline: OutlineState? = nil

    @State private var text: String
    @State private var hiddenHeadingLine: String
    @State private var saveDebouncer = Debouncer(delay: 1.0)
    @State private var slashHandler = SlashCommandHandler()
    @State private var noteNavMonitor: Any?

    /// Per-note scroll offsets persisted across editor unmount/remount (engine 0.12.0
    /// `onPersistScrollOffset` / `restoreScrollOffset`). Session-level — not persisted
    /// to disk (matches the engine's original coordinator-level offsets). Keyed by noteID.
    private static var scrollOffsets: [String: CGFloat] = [:]
    /// Latched at init — never updated on re-render. Guards against @Observable pushing
    /// a new selectedNote into the animating-out EditorScreen, which would overwrite
    /// onContentChanged's captured note ID while @State text still holds the old note's content.
    @State private var stableNoteID: UUID

    init(
        noteID: UUID,
        noteTitle: String,
        noteFolder: String,
        initialContent: String,
        onContentChanged: @escaping (UUID, String) -> Void,
        pendingReload: Binding<String?> = .constant(nil),
        showFindBar: Binding<Bool> = .constant(false),
        onNavigateNext: (() -> Void)? = nil,
        onNavigatePrevious: (() -> Void)? = nil,
        outline: OutlineState? = nil,
    ) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.noteFolder = noteFolder
        self.initialContent = initialContent
        self.onContentChanged = onContentChanged
        _pendingReload = pendingReload
        self.showFindBar = showFindBar
        self.onNavigateNext = onNavigateNext
        self.onNavigatePrevious = onNavigatePrevious
        self.outline = outline
        let (heading, body) = Self.splitHeading(initialContent)
        _text = State(initialValue: body)
        _hiddenHeadingLine = State(initialValue: heading)
        _stableNoteID = State(initialValue: noteID)
    }

    var body: some View {
        // Reading AppSettings.shared properties here registers @Observable tracking —
        // the view re-renders (and NativeTextViewWrapper.updateNSView re-applies font)
        // whenever editorFontName or editorFontSize changes.
        let appSettings = AppSettings.shared
        let fontName = Self.resolvedFontFamily(from: appSettings.editorFontName) ?? "SF Pro"
        let isRawSource = appSettings.editorRawSourceMode

        var config = MarkdownEditorConfiguration.makeTearoffConfig(
            noteFolder: noteFolder,
            bus: MarkdownEditorBus(
                // Formatting-request channels — posting these drives the engine's
                // didMarkdown* actions (bold/italic/code/link/strikethrough), which in
                // 0.8+ also word-wrap the token under the caret when nothing is selected.
                applyBoldRequest: .editorApplyBold,
                applyItalicRequest: .editorApplyItalic,
                applyStrikethroughRequest: .editorApplyStrikethrough,
                applyInlineCodeRequest: .editorApplyInlineCode,
                applyLinkRequest: .editorApplyLink,
                findScrollToRange: .editorFindScrollToRange,
                findClearHighlights: .editorFindClearHighlights,
            ),
            rawSourceMode: isRawSource,
        )
        config.spellChecking = SpellCheckingPolicy(
            continuousSpellChecking: appSettings.spellCheckingEnabled,
            grammarChecking: appSettings.grammarCheckingEnabled,
            automaticSpellingCorrection: appSettings.automaticSpellingCorrectionEnabled,
        )

        return ZStack(alignment: .bottom) {
            // Anchors the outline coordinator to this window (editor + outline live together).
            OutlineWindowAnchor { window in
                outline?.scrollCoordinator.attach(to: window)
            }
            .frame(width: 0, height: 0)

            NativeTextViewWrapper(
                text: $text,
                configuration: config,
                fontName: fontName,
                fontSize: CGFloat(appSettings.editorFontSize),
                documentId: noteID.uuidString,
                onPasteImage: { [noteID, noteTitle, noteFolder] pasteboard in
                    guard let (data, ext) = Self.imageData(from: pasteboard) else { return nil }
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    // Standard `![](path)` markdown — the engine renders it inline
                    // (styleImageLinks routes the path through TearoffImageProvider).
                    return (try? FileStorage.saveImage(data: data, ext: ext, forNote: note))?.markdown
                },
                onSpellCheckingPolicyChanged: { policy in
                    // Persist context-menu spelling/grammar/autocorrect toggles back to settings
                    // so they survive note switches and app restarts.
                    AppSettings.shared.spellCheckingEnabled = policy.continuousSpellChecking
                    AppSettings.shared.grammarCheckingEnabled = policy.grammarChecking
                    AppSettings.shared.automaticSpellingCorrectionEnabled = policy.automaticSpellingCorrection
                },
                onPersistScrollOffset: { docId, offset in
                    Self.scrollOffsets[docId] = offset
                },
                restoreScrollOffset: { docId in
                    Self.scrollOffsets[docId]
                },
            )
            // Force the text view to rebuild (makeNSView) when the task-checkbox style
            // changes — the engine's updateNSView doesn't sync taskCheckbox, so only a
            // full config re-application picks up the new SF Symbols.
            .id(appSettings.taskCheckboxPreset)
            .onChange(of: isRawSource) { _, raw in
                // Mode flip: re-express the same document without saving a mid-state.
                // WYSIWYG keeps the heading split out (`hiddenHeadingLine`); raw shows
                // the complete on-disk file verbatim. Always cancel the pending
                // debounce first so the swap can't flush a half-converted state.
                saveDebouncer.cancel()
                if raw {
                    let heading = hiddenHeadingLine
                    hiddenHeadingLine = ""
                    text = heading.isEmpty ? text : heading + "\n\n" + text
                } else {
                    let (heading, body) = Self.splitHeading(text)
                    hiddenHeadingLine = heading
                    text = body
                }
            }
            .onChange(of: text) { _, newText in
                outline?.update(body: newText, hiddenHeading: hiddenHeadingLine)
                let cursorPos = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange().location ?? 0
                slashHandler.contentDidChange(content: newText, cursorPos: cursorPos)
                let heading = hiddenHeadingLine
                let noteIDSnapshot = stableNoteID
                saveDebouncer.call { [onContentChanged] in
                    let full = heading.isEmpty ? newText : heading + "\n\n" + newText
                    onContentChanged(noteIDSnapshot, full)
                }
            }
            .onChange(of: pendingReload) { _, newContent in
                guard let newContent else { return }
                saveDebouncer.cancel()
                if AppSettings.shared.editorRawSourceMode {
                    // Raw mode shows the complete file — no heading split.
                    hiddenHeadingLine = ""
                    text = newContent
                } else {
                    let (heading, body) = Self.splitHeading(newContent)
                    hiddenHeadingLine = heading
                    text = body
                }
                pendingReload = nil
            }
            .overlay(
                ImageDropOverlay { [noteID, noteTitle, noteFolder] url in
                    guard let data = try? Data(contentsOf: url) else { return }
                    let ext = url.pathExtension.lowercased()
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    guard let result = try? FileStorage.saveImage(data: data, ext: ext, forNote: note) else { return }
                    // After a drag completes the text view may have lost first responder.
                    // Fall back to walking the window hierarchy to find it.
                    let window = NSApp.keyWindow
                    let tv = (window?.firstResponder as? NSTextView)
                        ?? findEditorTextView(in: window?.contentView)
                    guard let tv else { return }
                    window?.makeFirstResponder(tv)
                    tv.insertText(result.markdown, replacementRange: tv.selectedRange())
                },
            )

            // Find bar overlay — slides in from the bottom when showFindBar is true.
            if showFindBar.wrappedValue {
                FindBarView(isPresented: showFindBar, editorText: $text)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showFindBar.wrappedValue)
        .onAppear {
            outline?.update(body: text, hiddenHeading: hiddenHeadingLine)
            noteNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                // Markdown formatting shortcuts — route through the engine's bus so the
                // didMarkdown* actions run (with word-boundary auto-wrap when no selection).
                // Guard on the editor's text view being focused, not a field editor (find
                // bar / search / rename), so typing into those doesn't bold/italicize.
                if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, !tv.isFieldEditor {
                    let key = event.charactersIgnoringModifiers?.lowercased()
                    let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
                    if key == "b", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyBold, object: nil); return nil
                    }
                    if key == "i", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyItalic, object: nil); return nil
                    }
                    if key == "e", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyInlineCode, object: nil); return nil
                    }
                    if key == "k", mods == [.command] {
                        NotificationCenter.default.post(name: .editorApplyLink, object: nil); return nil
                    }
                    if key == "x", mods == [.command, .shift] {
                        NotificationCenter.default.post(name: .editorApplyStrikethrough, object: nil); return nil
                    }
                }
                let s = ShortcutSettings.shared
                if s.previousNoteShortcut?.matches(event) == true {
                    onNavigatePrevious?(); return nil
                }
                if s.nextNoteShortcut?.matches(event) == true {
                    onNavigateNext?(); return nil
                }
                return event
            }
        }
        .onDisappear {
            outline?.scrollCoordinator.detach()
            // Flush debounced save immediately on note switch or panel hide.
            // Use stableNoteID (latched @State) — not noteID (let) — because @Observable
            // may re-render this view with a new note's data while it's animating out,
            // which would update onContentChanged to point to the new note. stableNoteID
            // always holds the note that was active when this view was first inserted.
            let capturedID = stableNoteID
            saveDebouncer.cancel()
            let full = hiddenHeadingLine.isEmpty ? text : hiddenHeadingLine + "\n\n" + text
            onContentChanged(capturedID, full)
            slashHandler.dismiss()
            if let m = noteNavMonitor {
                NSEvent.removeMonitor(m); noteNavMonitor = nil
            }
        }
    }

    // MARK: - Helpers

    static func splitHeading(_ content: String) -> (heading: String, body: String) {
        let lines = content.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("#") else { return ("", content) }
        var rest = Array(lines.dropFirst())
        while rest.first == "" {
            rest.removeFirst()
        }
        return (first, rest.joined(separator: "\n"))
    }

    private static func resolvedFontFamily(from postscriptName: String?) -> String? {
        guard let name = postscriptName, let font = NSFont(name: name, size: 16) else { return nil }
        return font.familyName
    }

    private static func imageData(from pasteboard: NSPasteboard) -> (Data, String)? {
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType("public.png")) {
            return (data, "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let img = NSImage(data: tiff),
           let rep = NSBitmapImageRep(data: img.tiffRepresentation ?? Data()),
           let png = rep.representation(using: .png, properties: [:])
        {
            return (png, "png")
        }
        return nil
    }
}

// MARK: - Notification names for the editor find bus

extension Notification.Name {
    static let editorFindScrollToRange = Notification.Name("io.github.zcyisiee.Tearoff.editor.findScrollToRange")
    static let editorFindClearHighlights = Notification.Name("io.github.zcyisiee.Tearoff.editor.findClearHighlights")

    // Formatting-request bus channels — posting these drives the engine's
    // didMarkdown* actions (routed from the ⌘B/⌘I/⌘E/⌘K/⇧⌘X local key monitor).
    static let editorApplyBold = Notification.Name("io.github.zcyisiee.Tearoff.editor.applyBold")
    static let editorApplyItalic = Notification.Name("io.github.zcyisiee.Tearoff.editor.applyItalic")
    static let editorApplyInlineCode = Notification.Name("io.github.zcyisiee.Tearoff.editor.applyInlineCode")
    static let editorApplyLink = Notification.Name("io.github.zcyisiee.Tearoff.editor.applyLink")
    static let editorApplyStrikethrough = Notification.Name("io.github.zcyisiee.Tearoff.editor.applyStrikethrough")
}
