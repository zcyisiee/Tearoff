import Foundation

// MARK: - OutlineEntry

/// One heading in a note's outline. `range` is the heading line's character range
/// in the editor's display text (body without the hidden title line); the title
/// entry uses `location: 0` so jumping to it scrolls to the top.
struct OutlineEntry: Identifiable, Equatable {
    let level: Int
    let title: String
    let range: NSRange
    /// Path from the note title down to this heading (层级路径), used to key
    /// collapse state so it survives edits that shift character offsets.
    let pathKey: String

    var id: String {
        pathKey
    }
}

// MARK: - MarkdownOutline

/// Line-scan outline extraction: `#`–`######` ATX headings, skipping fenced
/// code blocks (```/~~~) so `# comments` inside code aren't misread as headings.
enum MarkdownOutline {
    /// - Parameters:
    ///   - body: editor display text (the note's hidden first-line `# title` removed).
    ///   - hiddenHeading: the stripped `# ...` title line, if any. Becomes the root
    ///     entry (level = its `#` count) that scrolls to the top.
    static func parse(body: String, hiddenHeading: String?) -> [OutlineEntry] {
        var entries: [OutlineEntry] = []
        // Stack of open heading ancestors used to build each entry's path key.
        var stack: [(level: Int, title: String)] = []

        func append(_ level: Int, _ title: String, _ range: NSRange) {
            while let last = stack.last, last.level >= level {
                stack.removeLast()
            }
            stack.append((level, title))
            // Unit-separator joined path + occurrence index keeps ids unique when
            // the same heading text repeats under the same parent.
            let path = stack.map { "\($0.level):\($0.title)" }.joined(separator: "\u{1}")
            let occurrence = entries.filter { $0.pathKey.hasPrefix(path) }.count
            entries.append(
                OutlineEntry(
                    level: level,
                    title: title,
                    range: range,
                    pathKey: path + "\u{1}\(occurrence)",
                ),
            )
        }

        if let hiddenHeading, let (level, title) = splitHeadingLine(hiddenHeading) {
            append(level, title, NSRange(location: 0, length: 0))
        }

        var inFence = false
        var offset = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf16.count
            defer { offset += length + 1 }
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence, let (level, title) = splitHeadingLine(String(trimmed)) else { continue }
            append(level, title, NSRange(location: offset, length: length))
        }
        return entries
    }

    /// `"### Title"` → `(3, "Title")`. Requires a space after the hashes so tags
    /// like `#tag` don't count. Returns nil for non-headings.
    private static func splitHeadingLine(_ line: String) -> (level: Int, title: String)? {
        var level = 0
        for ch in line {
            guard ch == "#", level < 6 else { break }
            level += 1
        }
        guard level > 0 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " || rest.first == "\t" else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }
}
