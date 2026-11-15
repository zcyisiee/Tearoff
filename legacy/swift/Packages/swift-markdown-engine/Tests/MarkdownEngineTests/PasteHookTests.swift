//
//  PasteHookTests.swift
//  MarkdownEngineTests
//
//  The embedder paste hooks: `onPasteText` interception (raw string flavor +
//  selected text in, replacement out) and `onPasteCompleted` reporting the
//  final inserted range after `insertPasted` commits.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Paste hooks")
struct PasteHookTests {

    private func makeTextView(_ document: String) -> NativeTextView {
        let tv = NativeTextView(frame: .zero)
        tv.string = document
        return tv
    }

    private func makePasteboard(_ text: String?) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("PasteHookTests.\(UUID().uuidString)"))
        pb.declareTypes([.string], owner: nil)
        if let text { pb.setString(text, forType: .string) }
        return pb
    }

    // MARK: onPasteText interception

    @Test("hook returns a replacement for the raw string flavor")
    func interceptionReplacesText() {
        let tv = makeTextView("hello")
        tv.onPasteText = { _, raw, _ in raw == "https://example.com" ? "[](https://example.com)" : nil }
        let replaced = tv.interceptPastedText(makePasteboard("https://example.com"))
        #expect(replaced == "[](https://example.com)")
    }

    @Test("hook declining (nil) falls through")
    func interceptionDeclined() {
        let tv = makeTextView("hello")
        tv.onPasteText = { _, _, _ in nil }
        #expect(tv.interceptPastedText(makePasteboard("plain text")) == nil)
    }

    @Test("no hook installed falls through")
    func noHook() {
        let tv = makeTextView("hello")
        #expect(tv.interceptPastedText(makePasteboard("anything")) == nil)
    }

    @Test("empty string flavor falls through even with a hook")
    func emptyFlavor() {
        let tv = makeTextView("hello")
        tv.onPasteText = { _, _, _ in "replaced" }
        #expect(tv.interceptPastedText(makePasteboard(nil)) == nil)
    }

    @Test("selected text is passed through (nil without selection)")
    func selectionForwarded() {
        let tv = makeTextView("hello world")
        tv.setSelectedRange(NSRange(location: 6, length: 5))
        var captured: String?? = nil
        tv.onPasteText = { _, _, selected in
            captured = selected
            return nil
        }
        _ = tv.interceptPastedText(makePasteboard("https://example.com"))
        #expect(captured ?? nil == "world")
    }

    @Test("no selection forwards nil selected text")
    func noSelectionForwardsNil() {
        let tv = makeTextView("hello")
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        var captured: String?? = nil
        tv.onPasteText = { _, _, selected in
            captured = selected
            return nil
        }
        _ = tv.interceptPastedText(makePasteboard("https://example.com"))
        #expect(captured ?? "sentinel" == nil)
    }

    // MARK: onPasteCompleted

    @Test("insertPasted reports the final inserted range")
    func completionReportsRange() {
        let tv = makeTextView("abcdef")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        var reported: NSRange? = nil
        tv.onPasteCompleted = { _, range in reported = range }
        tv.insertPasted("XYZ", replacementRange: NSRange(location: 3, length: 0))
        #expect(tv.string == "abcXYZdef")
        #expect(reported == NSRange(location: 3, length: 3))
    }

    @Test("insertPasted over a selection reports replacement-relative range")
    func completionOverSelection() {
        let tv = makeTextView("abcdef")
        tv.setSelectedRange(NSRange(location: 2, length: 3)) // "cde"
        var reported: NSRange? = nil
        tv.onPasteCompleted = { _, range in reported = range }
        tv.insertPasted("[link](https://example.com)", replacementRange: NSRange(location: 2, length: 3))
        #expect(tv.string == "ab[link](https://example.com)f")
        #expect(reported == NSRange(location: 2, length: "[link](https://example.com)".utf16.count))
    }

    @Test("no completion hook is safe")
    func noCompletionHook() {
        let tv = makeTextView("abc")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertPasted("d", replacementRange: NSRange(location: 3, length: 0))
        #expect(tv.string == "abcd")
    }
}
