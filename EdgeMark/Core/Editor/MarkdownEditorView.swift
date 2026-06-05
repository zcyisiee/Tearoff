import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// SwiftUI wrapper around NativeTextViewWrapper (swift-markdown-engine).
/// Manages heading stripping, save debouncing, font observation, and the
/// slash-command popup.
struct MarkdownEditorView: View {
    let noteID: UUID
    let noteTitle: String
    let noteFolder: String
    let initialContent: String
    let onContentChanged: (String) -> Void
    /// Set to new full note content to reload the editor (e.g. from file watcher).
    /// Cleared automatically after the view applies it.
    @Binding var pendingReload: String?
    var onNavigateNext: (() -> Void)?
    var onNavigatePrevious: (() -> Void)?

    @State private var text: String
    @State private var hiddenHeadingLine: String
    @State private var saveDebouncer = Debouncer(delay: 1.0)
    @State private var slashHandler = SlashCommandHandler()
    @State private var noteNavMonitor: Any?

    init(
        noteID: UUID,
        noteTitle: String,
        noteFolder: String,
        initialContent: String,
        onContentChanged: @escaping (String) -> Void,
        pendingReload: Binding<String?> = .constant(nil),
        onNavigateNext: (() -> Void)? = nil,
        onNavigatePrevious: (() -> Void)? = nil,
    ) {
        self.noteID = noteID
        self.noteTitle = noteTitle
        self.noteFolder = noteFolder
        self.initialContent = initialContent
        self.onContentChanged = onContentChanged
        _pendingReload = pendingReload
        self.onNavigateNext = onNavigateNext
        self.onNavigatePrevious = onNavigatePrevious
        let (heading, body) = Self.splitHeading(initialContent)
        _text = State(initialValue: body)
        _hiddenHeadingLine = State(initialValue: heading)
    }

    var body: some View {
        // Reading AppSettings.shared properties here registers @Observable tracking —
        // the view re-renders (and NativeTextViewWrapper.updateNSView re-applies font)
        // whenever editorFontName or editorFontSize changes.
        let appSettings = AppSettings.shared
        let fontName = Self.resolvedFontFamily(from: appSettings.editorFontName) ?? "SF Pro"

        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(
            syntaxHighlighter: HighlighterSwiftBridge(),
            latex: SwiftMathBridge(),
        )

        return NativeTextViewWrapper(
            text: $text,
            configuration: config,
            fontName: fontName,
            fontSize: CGFloat(appSettings.editorFontSize),
            documentId: noteID.uuidString,
            onPasteImage: { [noteID, noteTitle, noteFolder] pasteboard in
                guard let (data, ext) = Self.imageData(from: pasteboard) else { return nil }
                let note = Note(id: noteID, title: noteTitle, folder: noteFolder)
                return try? FileStorage.saveImage(data: data, ext: ext, forNote: note).markdown
            },
        )
        .onChange(of: text) { _, newText in
            let cursorPos = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange().location ?? 0
            slashHandler.contentDidChange(content: newText, cursorPos: cursorPos)
            let heading = hiddenHeadingLine
            saveDebouncer.call { [onContentChanged] in
                let full = heading.isEmpty ? newText : heading + "\n\n" + newText
                onContentChanged(full)
            }
        }
        .onChange(of: pendingReload) { _, newContent in
            guard let newContent else { return }
            saveDebouncer.cancel()
            let (heading, body) = Self.splitHeading(newContent)
            hiddenHeadingLine = heading
            text = body
            pendingReload = nil
        }
        .onAppear {
            noteNavMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                guard event.modifierFlags.contains(.command),
                      !event.modifierFlags.contains(.shift)
                else { return event }
                if event.keyCode == 123 { onNavigatePrevious?(); return nil }
                if event.keyCode == 124 { onNavigateNext?(); return nil }
                return event
            }
        }
        .onDisappear {
            // Flush debounced save immediately on note switch or panel hide
            saveDebouncer.cancel()
            let full = hiddenHeadingLine.isEmpty ? text : hiddenHeadingLine + "\n\n" + text
            onContentChanged(full)
            slashHandler.dismiss()
            if let m = noteNavMonitor { NSEvent.removeMonitor(m); noteNavMonitor = nil }
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
