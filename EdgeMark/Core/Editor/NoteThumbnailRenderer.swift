import Foundation
import SwiftUI

// MARK: - CardPreviewBlock

/// One block of the structured card preview. Content carries inline styling
/// only (bold/italic/code) — fonts and colors are applied by the view so the
/// whole preview scales from `boardFontSize` and headings can take the card's
/// identity color.
struct CardPreviewBlock: Identifiable {
    enum Kind {
        /// `#`–`######` heading; the view styles level 2 vs 3+ distinctly.
        case heading(level: Int, text: AttributedString)
        /// `- [ ]` / `- [x]` task item. `lineIndex` points at the source line
        /// in `note.content` so the view can toggle the checkbox in place.
        case task(lineIndex: Int, isChecked: Bool, text: AttributedString)
        case bullet(text: AttributedString)
        case quote(text: AttributedString)
        case code(text: AttributedString)
        case text(AttributedString)
    }

    let id: Int
    let kind: Kind
}

// MARK: - NoteThumbnailRenderer

/// Lightweight markdown block parser for note card previews. Renders the
/// visual subset that reads at card size — heading levels, bullets, task
/// items, quotes, fences (collapsed), inline bold/italic/code/links — and
/// strips everything else (images, raw HTML, tables) to plain text.
///
/// Results are cached per note (id + modifiedAt + size), so scrolling the
/// board does not re-parse content.
enum NoteThumbnailRenderer {
    private static let cache = NSCache<NSString, CachableBlocks>()

    /// Parse up to `maxLines` blocks of the note body. A leading H1 that
    /// duplicates the note title is skipped — the card shows the title itself.
    static func structuredPreview(
        for note: Note,
        maxLines: Int = 6,
        fontSize: Double,
    ) -> [CardPreviewBlock] {
        let key = "\(note.id.uuidString)|\(note.modifiedAt.timeIntervalSince1970)|\(maxLines)|\(fontSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = parse(note.content, maxLines: maxLines, skipTitle: note.title)
        cache.setObject(CachableBlocks(result), forKey: key)
        return result
    }

    final class CachableBlocks {
        let value: [CardPreviewBlock]
        init(_ value: [CardPreviewBlock]) { self.value = value }
    }

    // MARK: - Parsing

    private static func parse(_ content: String, maxLines: Int, skipTitle: String) -> [CardPreviewBlock] {
        var blocks: [CardPreviewBlock] = []
        var inFence = false
        var didSkipTitle = false

        for (lineIndex, rawLine) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if blocks.count >= maxLines { break }
            let line = String(rawLine)

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                // Collapsed fence contents: one dim line per block.
                if case .code = blocks.last?.kind { continue }
                blocks.append(CardPreviewBlock(id: blocks.count, kind: .code(text: AttributedString("…"))))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") {
                guard let level = headingLevel(line) else { continue }
                let text = inline(String(line.dropFirst(level + 1))) ?? AttributedString("")
                // Drop the leading "# Title" line when it duplicates the card title.
                if !didSkipTitle, level == 1, !skipTitle.isEmpty,
                   String(text.characters).trimmed() == skipTitle
                {
                    didSkipTitle = true
                    continue
                }
                blocks.append(CardPreviewBlock(id: blocks.count, kind: .heading(level: level, text: text)))
                continue
            }
            if line.hasPrefix(">") {
                var quoteBody = Substring(line)
                while quoteBody.hasPrefix(">") || quoteBody.hasPrefix(" ") {
                    quoteBody = quoteBody.dropFirst()
                }
                blocks.append(CardPreviewBlock(id: blocks.count, kind: .quote(text: inline(String(quoteBody)) ?? AttributedString(""))))
                continue
            }
            if isTaskLine(line) {
                blocks.append(taskBlock(line, lineIndex: lineIndex, blockIndex: blocks.count))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                var bulletBody = line[line.index(line.startIndex, offsetBy: 2)...]
                // Editors can nest tasks ("- - [x] …") — strip extra markers, still render as a task.
                while bulletBody.hasPrefix("- ") || bulletBody.hasPrefix("* ") || bulletBody.hasPrefix("+ ") {
                    bulletBody = bulletBody.dropFirst(2)
                }
                if isTaskLine("- " + bulletBody) {
                    blocks.append(taskBlock("- " + bulletBody, lineIndex: lineIndex, blockIndex: blocks.count))
                } else {
                    blocks.append(CardPreviewBlock(id: blocks.count, kind: .bullet(text: inline(String(bulletBody)) ?? AttributedString(""))))
                }
                continue
            }
            if let match = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let orderedBody = line.replacingCharacters(in: match, with: "")
                blocks.append(CardPreviewBlock(id: blocks.count, kind: .text(inline(orderedBody) ?? AttributedString(""))))
                continue
            }
            if line.hasPrefix("---") || line.hasPrefix("!") || line.hasPrefix("|") {
                continue
            }

            blocks.append(CardPreviewBlock(id: blocks.count, kind: .text(inline(line) ?? AttributedString(""))))
        }

        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard level >= 1, level <= 6, line.count > hashes.count else { return nil }
        return level
    }

    private static func isTaskLine(_ line: String) -> Bool {
        line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ")
            || line.hasPrefix("* [ ] ") || line.hasPrefix("* [x] ") || line.hasPrefix("* [X] ")
    }

    private static func taskBlock(_ line: String, lineIndex: Int, blockIndex: Int) -> CardPreviewBlock {
        let isChecked = line.contains("[x]") || line.contains("[X]")
        let bodyText = line.dropFirst(6)
        return CardPreviewBlock(
            id: blockIndex,
            kind: .task(lineIndex: lineIndex, isChecked: isChecked, text: inline(String(bodyText)) ?? AttributedString("")),
        )
    }

    /// Inline markdown subset: **bold**, *italic*, `code`, [text](url) → text.
    private static func inline(_ text: String) -> AttributedString? {
        var source = text
        // Links → display text only.
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^)]*\)"#) {
            source = regex.stringByReplacingMatches(
                in: source,
                range: NSRange(source.startIndex..., in: source),
                withTemplate: "$1",
            )
        }
        // Images → drop entirely.
        if let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^)]*\)"#) {
            source = regex.stringByReplacingMatches(
                in: source,
                range: NSRange(source.startIndex..., in: source),
                withTemplate: "",
            )
        }
        guard !source.isEmpty else { return nil }
        return parseInline(Array(source))
    }

    private static func parseInline(_ chars: [Character]) -> AttributedString? {
        var result = AttributedString()
        var buffer = ""
        var index = 0

        func flush(_ intent: InlinePresentationIntent? = nil) {
            guard !buffer.isEmpty else { return }
            var a = AttributedString(buffer)
            if let intent { a.inlinePresentationIntent = intent }
            result += a
            buffer = ""
        }

        while index < chars.count {
            let c = chars[index]
            switch c {
            case "*":
                let isDouble = index + 1 < chars.count && chars[index + 1] == "*"
                let marker = isDouble ? 2 : 1
                if let close = findClose(chars, from: index + marker, marker: isDouble ? "**" : "*") {
                    flush()
                    let inner = String(chars[(index + marker) ..< close])
                    var a = AttributedString(inner)
                    a.inlinePresentationIntent = isDouble ? .stronglyEmphasized : .emphasized
                    result += a
                    index = close + (isDouble ? 2 : 1)
                    continue
                }
                buffer.append(c)
                index += 1
            case "`":
                if let close = chars[(index + 1)...].firstIndex(of: "`") {
                    flush()
                    var a = AttributedString(String(chars[(index + 1) ..< close]))
                    a.inlinePresentationIntent = .code
                    result += a
                    index = chars.index(after: close)
                    continue
                }
                buffer.append(c)
                index += 1
            default:
                buffer.append(c)
                index += 1
            }
        }
        flush()
        return result.characters.isEmpty ? nil : result
    }

    private static func findClose(_ chars: [Character], from start: Int, marker: String) -> Int? {
        let markerChars = Array(marker)
        var i = start
        while i + markerChars.count <= chars.count {
            if Array(chars[i ..< i + markerChars.count]) == markerChars {
                return i
            }
            i += 1
        }
        return nil
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
