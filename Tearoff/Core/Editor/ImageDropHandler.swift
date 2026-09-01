import AppKit
import SwiftUI

// MARK: - Drop target view

final class DropTargetView: NSView {
    var onImageURLDropped: ((URL) -> Void)?

    private static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "bmp", "heic", "heif"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    /// Transparent to all mouse/key events — only drag-and-drop lands here.
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImageFile(in: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hasImageFile(in: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: ["public.image"],
        ]) as? [URL],
            let url = urls.first
        else { return false }
        // Defer to next run loop so the drag session finishes and the window
        // restores first-responder state before we look for the text view.
        DispatchQueue.main.async { [weak self] in
            self?.onImageURLDropped?(url)
        }
        return true
    }

    private func hasImageFile(in pasteboard: NSPasteboard) -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: ["public.image"],
        ]) as? [URL] else { return false }
        return urls.contains { Self.imageTypes.contains($0.pathExtension.lowercased()) }
    }
}

// MARK: - SwiftUI wrapper

struct ImageDropOverlay: NSViewRepresentable {
    let onImageURLDropped: (URL) -> Void

    func makeNSView(context _: Context) -> DropTargetView {
        let v = DropTargetView()
        v.onImageURLDropped = onImageURLDropped
        return v
    }

    func updateNSView(_ nsView: DropTargetView, context _: Context) {
        nsView.onImageURLDropped = onImageURLDropped
    }
}

// MARK: - Board-level drop target

/// Transparent drag target laid over the whole board viewport. Receives
/// image-file drags, converts the drop point into `BoardViewportSpace`
/// coordinates (SwiftUI's top-left origin — AppKit hands us bottom-left, so
/// the y flips against the view's own bounds), and hands (url, point) to the
/// board for card hit-testing. Sits BELOW the expanded editor in the board's
/// ZStack, so a full-editor session's own drop overlay keeps precedence;
/// drops over an in-place editing card are routed by the board into that
/// card's live editor.
final class BoardImageDropView: NSView {
    /// (file URL, drop point in `BoardViewportSpace`), delivered after the
    /// drag session finishes.
    var onImageDropped: ((URL, CGPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstImageFileURL(sender.draggingPasteboard) != nil ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        firstImageFileURL(sender.draggingPasteboard) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = firstImageFileURL(sender.draggingPasteboard) else { return false }
        let local = convert(sender.draggingLocation, from: nil)
        let viewportPoint = CGPoint(x: local.x, y: bounds.height - local.y)
        DispatchQueue.main.async { [weak self] in
            self?.onImageDropped?(url, viewportPoint)
        }
        return true
    }

    private func firstImageFileURL(_ pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: ["public.image"],
        ]) as? [URL] ?? []
        return urls.first
    }
}

/// SwiftUI mounting for ``BoardImageDropView``.
struct BoardImageDropOverlay: NSViewRepresentable {
    let onImageDropped: (URL, CGPoint) -> Void

    func makeNSView(context _: Context) -> BoardImageDropView {
        let v = BoardImageDropView()
        v.onImageDropped = onImageDropped
        return v
    }

    func updateNSView(_ nsView: BoardImageDropView, context _: Context) {
        nsView.onImageDropped = onImageDropped
    }
}

// MARK: - Helpers

/// Walk the view hierarchy from `root` and return the first NSTextView found
/// inside an NSScrollView (NativeTextViewWrapper's structure).
func findEditorTextView(in root: NSView?) -> NSTextView? {
    guard let root else { return nil }
    if let scroll = root as? NSScrollView, let tv = scroll.documentView as? NSTextView {
        return tv
    }
    for sub in root.subviews {
        if let found = findEditorTextView(in: sub) {
            return found
        }
    }
    return nil
}
