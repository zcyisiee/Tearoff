import Foundation
import SwiftUI

// MARK: - NoteThumbnailRenderer

/// Lightweight markdown renderer for note card thumbnails. Renders the visual
/// subset that reads at card size — heading levels, bullets, task items,
/// quotes, inline bold/italic/code/links — and strips everything else
/// (fences, images, raw HTML) to plain text. Output is a single multiline
/// `AttributedString` so one `Text` renders the whole preview.
///
/// Results are cached per note (id + modifiedAt), so scrolling the board does
/// not re-parse content.
enum NoteThumbnailRenderer {
    private static let cache = NSCache<NSString, CachableString>()

    /// Render up to `maxLines` lines of the note body into attributed text.
    /// A leading H1 that duplicates the note title is skipped — the card
    /// already shows the title separately.
    static func attributedPreview(for note: Note, maxLines: Int = 6) -> AttributedString {
        let key = "\(note.id.uuidString)|\(note.modifiedAt.timeIntervalSince1970)|\(maxLines)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = render(note.content, maxLines: maxLines, skipTitle: note.title)
        cache.setObject(CachableString(result), forKey: key)
        return result
    }

    final class CachableString {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    // MARK: - Rendering

    private static func render(_ content: String, maxLines: Int, skipTitle: String) -> AttributedString {
        var lines: [AttributedString] = []
        var inFence = false
        var didSkipTitle = false

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= maxLines { break }
            let line = String(rawLine)

            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence {
                // Collapsed fence contents: one dim line per block.
                if let last = lines.last, last.runs.first?.inlinePresentationIntent == .code {
                    continue
                }
                lines.append(codeLine("…"))
                continue
            }

            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if line.hasPrefix("#") {
                if let heading = headingLine(line) {
                    // Drop the leading "# Title" line when it duplicates the card title.
                    if !didSkipTitle, headingMatches(heading, title: skipTitle) {
                        didSkipTitle = true
                        continue
                    }
                    lines.append(heading)
                }
                continue
            }
            if line.hasPrefix(">") {
                var quoteBody = Substring(line)
                while quoteBody.hasPrefix(">") || quoteBody.hasPrefix(" ") {
                    quoteBody = quoteBody.dropFirst()
                }
                lines.append(quoteLine(String(quoteBody)))
                continue
            }
            if isTaskLine(line) {
                lines.append(taskLine(line))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                var bulletBody = line[line.index(line.startIndex, offsetBy: 2)...]
                // Editors can nest tasks ("- - [x] …") — strip extra markers, still render as a task.
                while bulletBody.hasPrefix("- ") || bulletBody.hasPrefix("* ") || bulletBody.hasPrefix("+ ") {
                    bulletBody = bulletBody.dropFirst(2)
                }
                if bulletBody.hasPrefix("[ ] ") || bulletBody.hasPrefix("[x] ") {
                    lines.append(taskLine("- " + bulletBody))
                } else {
                    lines.append(bulletLine(String(bulletBody)))
                }
                continue
            }
            if let match = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                let orderedBody = line.replacingCharacters(in: match, with: "")
                lines.append(bodyLine(orderedBody))
                continue
            }
            if line.hasPrefix("---") || line.hasPrefix("!") || line.hasPrefix("|") {
                continue
            }

            lines.append(bodyLine(line))
        }

        return joinLines(lines)
    }

    private static func isTaskLine(_ line: String) -> Bool {
        line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ")
            || line.hasPrefix("* [ ] ") || line.hasPrefix("* [x] ")
    }

    private static func joinLines(_ lines: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                result += AttributedString("\n")
            }
            result += line
        }
        return result
    }

    private static func headingLine(_ line: String) -> AttributedString? {
        let hashes = line.prefix(while: { $0 == "#" })
        let level = hashes.count
        guard level <= 6, line.count > hashes.count,
              let text = inline(String(line.dropFirst(level + 1)))
        else { return nil }
        var a = text
        let size: CGFloat = switch level {
        case 1: 14
        case 2: 13
        default: 12
        }
        a.font = .system(size: size, weight: .semibold)
        a.foregroundColor = level == 1 ? DesignTokenColor.bodyStrong : DesignTokenColor.body
        return a
    }

    /// Whether a rendered heading line's plain text equals the note title.
    private static func headingMatches(_ heading: AttributedString, title: String) -> Bool {
        guard !title.isEmpty else { return false }
        return String(heading.characters).trimmed() == title
    }

    private static func bulletLine(_ text: String) -> AttributedString {
        var a = AttributedString("•  ")
        a.foregroundColor = DesignTokenColor.mutedSoft
        if let body = inline(text) {
            a += body
            a.font = DesignTokenFont.thumbnailBody
            a.foregroundColor = DesignTokenColor.body
        }
        return a
    }

    private static func taskLine(_ line: String) -> AttributedString {
        let isChecked = line.contains("[x]")
        var a = AttributedString(isChecked ? "☑  " : "☐  ")
        a.foregroundColor = isChecked ? DesignTokenColor.accent : DesignTokenColor.mutedSoft
        let bodyText = line.dropFirst(6)
        if let body = inline(String(bodyText)) {
            a += body
            a.font = DesignTokenFont.thumbnailBody
            a.foregroundColor = isChecked ? DesignTokenColor.muted : DesignTokenColor.body
            if isChecked { a.strikethroughStyle = .single }
        }
        return a
    }

    private static func quoteLine(_ text: String) -> AttributedString {
        var a = AttributedString("│ ")
        a.foregroundColor = DesignTokenColor.hairline
        if let body = inline(text) {
            a += body
            a.font = DesignTokenFont.thumbnailBody.italic()
            a.foregroundColor = DesignTokenColor.muted
        }
        return a
    }

    private static func codeLine(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        a.font = DesignTokenFont.thumbnailMono
        a.foregroundColor = DesignTokenColor.muted
        a.inlinePresentationIntent = .code
        return a
    }

    private static func bodyLine(_ text: String) -> AttributedString {
        var a = inline(text) ?? AttributedString(text)
        a.font = DesignTokenFont.thumbnailBody
        a.foregroundColor = DesignTokenColor.body
        return a
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

// MARK: - Token shims (avoid public exposure of DesignToken internals)

/// File-private color/ font aliases so the renderer stays readable.
private enum DesignTokenColor {
    static let bodyStrong = DesignToken.bodyStrong
    static let body = DesignToken.bodyText
    static let muted = DesignToken.muted
    static let mutedSoft = DesignToken.mutedSoft
    static let accent = DesignToken.accent
    static let hairline = DesignToken.hairline
}

private enum DesignTokenFont {
    static let thumbnailBody = SwiftUI.Font.system(size: 11)
    static let thumbnailMono = SwiftUI.Font.system(size: 10, design: .monospaced)
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
