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
        return ImageDecodingCache.shared.image(
            at: FileStorage.imageURL(forRelativePath: request.name, folder: noteFolder),
            maxDimension: ImageDecodingCache.editorMaxDimension,
        )
    }

    func fingerprint() -> AnyHashable {
        noteFolder
    }
}

// MARK: - Inserted-link caret resolution

/// Locates the name/alt span of the first markdown link or image inside a
/// freshly inserted range, so paste/drop insertions can land the caret
/// Typora-style: between empty `[]`, on a prefilled name, or after a name.
enum InsertedLinkCaret {
    enum Intent {
        /// `![name](…)` — select `name` so typing replaces it (dragged-in image).
        case selectName
        /// `![](…)` / `[](…)` — caret between empty brackets; when a name is
        /// already present, caret at its end (pasted image, pasted link).
        case caretAtName
    }

    enum Resolved {
        case insideBrackets(location: Int)
        case nameSpan(NSRange)
    }

    /// First `[…` … `](` span fully inside `range`. `nil` when the inserted
    /// text carries no link-shaped construct (plain text paste).
    static func resolve(in text: NSString, range: NSRange) -> Resolved? {
        guard range.length >= 4,
              range.location >= 0,
              NSMaxRange(range) <= text.length else { return nil }
        let open = text.range(of: "[", options: [], range: range)
        guard open.location != NSNotFound else { return nil }
        let nameStart = NSMaxRange(open)
        var i = nameStart
        let end = NSMaxRange(range) - 1  // "](" needs the char after i too
        while i < end {
            if text.character(at: i) == 0x5D /* ] */, text.character(at: i + 1) == 0x28 /* ( */ {
                let length = i - nameStart
                return length > 0
                    ? .nameSpan(NSRange(location: nameStart, length: length))
                    : .insideBrackets(location: nameStart)
            }
            i += 1
        }
        return nil
    }

    static func apply(_ intent: Intent, in range: NSRange, to textView: NSTextView) {
        guard let resolved = resolve(in: textView.string as NSString, range: range) else { return }
        switch (intent, resolved) {
        case (_, .insideBrackets(let location)):
            textView.setSelectedRange(NSRange(location: location, length: 0))
        case (.selectName, .nameSpan(let span)):
            textView.setSelectedRange(span)
        case (.caretAtName, .nameSpan(let span)):
            textView.setSelectedRange(NSRange(location: NSMaxRange(span), length: 0))
        }
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
    /// Set right before a paste hook returns markdown; consumed once by the
    /// matching `onPasteCompleted` to land the caret (Typora-style name
    /// positioning). nil leaves the caret where the engine put it.
    @State private var pendingCaretIntent: InsertedLinkCaret.Intent?

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
                    // Pasting a file URL (Finder copy) keeps the original bytes
                    // and name; anything else decodes through the engine's
                    // reader (png/tiff/NSImage flavors) as PNG.
                    let data: Data, ext: String, preferredName: String?
                    if let fileURL = PasteboardImageReader.imageFileURL(from: pasteboard),
                       let bytes = try? Data(contentsOf: fileURL) {
                        data = bytes
                        ext = fileURL.pathExtension.lowercased()
                        preferredName = fileURL.lastPathComponent
                    } else if let png = PasteboardImageReader.imageData(from: pasteboard) {
                        data = png
                        ext = "png"
                        preferredName = nil
                    } else {
                        return nil
                    }
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    // Standard `![](path)` markdown with an empty alt — the
                    // engine renders it (styleImageLinks) and the caret lands
                    // between the brackets via the pending intent.
                    pendingCaretIntent = .caretAtName
                    return (try? FileStorage.saveImage(
                        data: data, ext: ext, forNote: note, preferredName: preferredName
                    ))?.markdown
                },
                onPasteText: { pasteboard, raw, selectedText in
                    // Typora-style link paste: a bare URL becomes a markdown
                    // link with the caret on the (empty or selected) name.
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Self.isWebURL(trimmed) {
                        pendingCaretIntent = .caretAtName
                        return "[\(selectedText ?? "")](\(trimmed))"
                    }
                    // Browser-copied hyperlink text: `.string` is just the
                    // label and the URL rides only in an inline-only HTML
                    // flavor the engine's own converter skips — recover it.
                    if let anchor = Self.inlineHTMLLink(pasteboard: pasteboard, plainText: trimmed) {
                        pendingCaretIntent = .caretAtName
                        return "[\(anchor.text)](\(anchor.url))"
                    }
                    return nil
                },
                onPasteCompleted: { tv, insertedRange in
                    guard let intent = pendingCaretIntent else { return }
                    pendingCaretIntent = nil
                    InsertedLinkCaret.apply(intent, in: insertedRange, to: tv)
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
                    let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                    Self.insertDroppedImageFile(url, for: note)
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

    // MARK: Link paste conversion

    /// Single-line absolute http(s) URL — the shape worth auto-linking.
    private static func isWebURL(_ s: String) -> Bool {
        guard !s.isEmpty, !s.contains(where: \.isNewline),
              let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// An inline-only HTML flavor whose first hyperlink's visible text matches
    /// `plainText` — the "copied a link's text off a webpage" clipboard, where
    /// the URL exists only in the HTML. nil for anything else (no HTML, block
    /// structure, mismatched text, non-web href).
    private static func inlineHTMLLink(pasteboard: NSPasteboard, plainText: String) -> (text: String, url: String)? {
        guard !plainText.isEmpty,
              let html = pasteboard.string(forType: .html),
              !NativeTextViewWrapper.htmlHasBlockStructure(html),
              let anchor = firstHTMLAnchor(html),
              isWebURL(anchor.href),
              collapsedWhitespace(anchor.text) == collapsedWhitespace(plainText)
        else { return nil }
        return (text: plainText, url: anchor.href)
    }

    /// First `<a href="…">label</a>` in `html`, inner tags stripped.
    private static func firstHTMLAnchor(_ html: String) -> (text: String, href: String)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\s[^>]*?href="([^"]*)"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ), let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length))
        else { return nil }
        let ns = html as NSString
        let href = decodeHTMLEntities(ns.substring(with: match.range(at: 1)))
        let inner = ns.substring(with: match.range(at: 2))
        let text = decodeHTMLEntities(
            inner.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        )
        return (text: text, href: href)
    }

    /// The handful of entities browsers actually emit in copied HTML.
    /// `&amp;` decodes last so pre-escaped sequences survive one round only.
    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func collapsedWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Shared drag-in path for editor drop overlays: save the file into note
    /// storage (original name kept), focus the live text view (falling back
    /// to a hierarchy walk — a finished drag may have dropped first
    /// responder), insert the reference on its own line, and land the caret
    /// on the name.
    static func insertDroppedImageFile(_ url: URL, for note: Note) {
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        guard let result = try? FileStorage.saveImage(
            data: data, ext: ext, forNote: note, preferredName: url.lastPathComponent
        ) else { return }
        let window = NSApp.keyWindow
        let tv = (window?.firstResponder as? NSTextView)
            ?? findEditorTextView(in: window?.contentView)
        guard let tv else { return }
        window?.makeFirstResponder(tv)
        let alt = dropImageAlt(for: url)
        let markdown = alt.isEmpty
            ? result.markdown
            : "![\(alt)](\(result.relativePath))"
        insertImageMarkdown(markdown, selectingName: !alt.isEmpty, in: tv)
    }

    /// Alt text for a dragged-in image: the file's display name. Dropped when
    /// the legacy hidden-dir mode is on (it writes opaque UUID filenames) or
    /// the name would break the link syntax.
    static func dropImageAlt(for url: URL) -> String {
        guard AppSettings.shared.imageStorageMode == .sharedAssets else { return "" }
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty, !stem.contains(where: { "[]()".contains($0) || $0.isNewline }) else {
            return ""
        }
        return stem
    }

    /// Insert `![…](…)` as its own line with undo fencing (one Cmd+Z reverts
    /// the whole insertion), then land the caret: select a prefilled name so
    /// typing replaces it, or park between empty brackets.
    static func insertImageMarkdown(_ markdown: String, selectingName: Bool, in tv: NSTextView) {
        let sel = tv.selectedRange()
        let nsText = tv.string as NSString
        var prefix = ""
        var suffix = ""
        if sel.location > 0, nsText.character(at: sel.location - 1) != 0x0A {
            prefix = "\n"
        }
        let after = sel.location + sel.length
        if after < nsText.length, nsText.character(at: after) != 0x0A {
            suffix = "\n"
        }
        let inserted = prefix + markdown + suffix
        tv.breakUndoCoalescing()
        tv.insertText(inserted, replacementRange: sel)
        tv.undoManager?.setActionName("Paste")
        tv.breakUndoCoalescing()
        let range = NSRange(location: sel.location, length: (inserted as NSString).length)
        InsertedLinkCaret.apply(selectingName ? .selectName : .caretAtName, in: range, to: tv)
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
