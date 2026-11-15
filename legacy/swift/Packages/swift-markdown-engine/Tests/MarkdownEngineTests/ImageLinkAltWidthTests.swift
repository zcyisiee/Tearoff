//
//  ImageLinkAltWidthTests.swift
//  MarkdownEngineTests
//
//  `![alt|300](url)` — the alt-text width suffix parsed by
//  `MarkdownStyler.requestedWidthInAlt(_:)` for standard image links.
//

import Testing
@testable import MarkdownEngine

@Suite("Image link alt width suffix")
struct ImageLinkAltWidthTests {
    @Test func plainSuffix() {
        #expect(MarkdownStyler.requestedWidthInAlt("photo|300") == 300)
    }

    @Test func fractionalSuffix() {
        #expect(MarkdownStyler.requestedWidthInAlt("photo|250.5") == 250.5)
    }

    @Test func suffixAlone() {
        #expect(MarkdownStyler.requestedWidthInAlt("|480") == 480)
    }

    @Test func spacesAroundNumberAreTrimmed() {
        #expect(MarkdownStyler.requestedWidthInAlt("photo| 64 ") == 64)
    }

    @Test func noSuffix() {
        #expect(MarkdownStyler.requestedWidthInAlt("photo") == nil)
        #expect(MarkdownStyler.requestedWidthInAlt("") == nil)
    }

    @Test func nonNumericSuffixIsIgnored() {
        // a `|` that isn't a width (e.g. a table-ish alt) must not parse
        #expect(MarkdownStyler.requestedWidthInAlt("a|b|c") == nil)
        #expect(MarkdownStyler.requestedWidthInAlt("a|3x") == nil)
    }

    @Test func lastPipeWins() {
        #expect(MarkdownStyler.requestedWidthInAlt("a|b|128") == 128)
    }

    @Test func zeroAndNegativeAreRejected() {
        #expect(MarkdownStyler.requestedWidthInAlt("photo|0") == nil)
        #expect(MarkdownStyler.requestedWidthInAlt("photo|-40") == nil)
    }
}
