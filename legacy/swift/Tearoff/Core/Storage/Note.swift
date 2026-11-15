import AppKit
import Foundation
import OSLog

struct Note: Identifiable {
    let id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date
    /// When Tearoff last wrote this file to disk. Used as the external-change
    /// detection sentinel — separate from `modifiedAt` so auto-saves without
    /// content changes don't advance the user-visible timestamp.
    var savedAt: Date
    var folder: String

    /// Color tags assigned to this note (Finder-style multi-tag).
    /// Persisted in the sidecar.
    var tags: [TagColor]

    /// Identity color (SideNotes-style card color). Persisted in the sidecar.
    var color: NoteColor?

    /// Pinned notes float above the rest of the board. Persisted in the sidecar.
    var pinned: Bool

    /// Manual sort position within a visible list (drag-reorder). nil = no
    /// explicit position yet. Persisted in the sidecar.
    var sortOrder: Int?

    /// When the note was moved to Trash (nil = active). Persisted in YAML front matter.
    var trashedAt: Date?

    /// The filename currently on disk (nil for brand-new notes not yet saved).
    /// Used to detect renames when the title changes.
    var savedFilename: String?

    /// Filename derived from sanitized title: "Title.md"
    var filename: String {
        "\(FileStorage.sanitizeForFilename(title)).md"
    }

    /// Relative path from storage root: "folder/Title.md" or just "Title.md".
    var relativePath: String {
        folder.isEmpty ? filename : "\(folder)/\(filename)"
    }

    /// User-facing display path: "folder/title.md" or "title.md".
    var displayPath: String {
        relativePath
    }

    /// Directory portion only: "/FolderName/" or "/" for root notes.
    var displayDirectory: String {
        folder.isEmpty ? "/" : "/\(folder)/"
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        savedAt: Date = Date(),
        folder: String = "",
        tags: [TagColor] = [],
        color: NoteColor? = nil,
        pinned: Bool = false,
        sortOrder: Int? = nil,
        trashedAt: Date? = nil,
        savedFilename: String? = nil,
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.savedAt = savedAt
        self.folder = folder
        self.tags = tags
        self.color = color
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.trashedAt = trashedAt
        self.savedFilename = savedFilename
    }

    /// Compare all UI-visible properties. Exclude savedFilename (transient storage metadata).
    static func == (lhs: Note, rhs: Note) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.content == rhs.content
            && lhs.createdAt == rhs.createdAt
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.folder == rhs.folder
            && lhs.tags == rhs.tags
            && lhs.color == rhs.color
            && lhs.pinned == rhs.pinned
            && lhs.sortOrder == rhs.sortOrder
            && lhs.trashedAt == rhs.trashedAt
    }
}

extension Note: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Note {
    /// Plain-text preview from the note body, stripping the title heading and markdown syntax.
    ///
    /// The body is capped before any split/regex: a pathological or very large note can
    /// otherwise pin the main thread in `String.index` / `String.distance` for seconds
    /// when the note list renders (e.g. at launch, when the panel's view tree is built
    /// eagerly even while hidden). See devlog-0721, issue #56. 4 000 graphemes is far
    /// beyond any real title line, so dropping the first line (the H1 heading) still
    /// works; the 120-char preview output is unchanged.
    var previewText: String {
        let head = content.prefix(4000)
        // If the first line alone exceeds the cap, the title heading never fits in the
        // window — `dropFirst()` then empties the preview. Surface that so a reported
        // blank-subtitle can be pinpointed from Console.app (see devlog-0721, #56).
        // Cheap by construction: both checks are bounded to the ≤4 000-grapheme window
        // (no full-content walk).
        if head.firstIndex(of: "\n") == nil, head.endIndex != content.endIndex {
            let path = relativePath
            Log.storage.debug("[Note] preview capped — first line exceeds 4000 graphemes: \(path, privacy: .public)")
        }
        let lines = head.split(separator: "\n", omittingEmptySubsequences: true)
        let raw = lines.dropFirst().prefix(3).joined(separator: " ")
        return raw
            .replacingOccurrences(of: "#{1,6}\\s", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*{1,2}([^*]+)\\*{1,2}", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
            .prefix(120)
            .description
    }

    /// RTF data converted from Markdown via HTML → NSAttributedString, preserving
    /// headings (with proper font sizes), bold, italic, strikethrough, code, and lists.
    var rtfData: Data? {
        Note.rtfData(from: content)
    }

    /// Full plain text with all Markdown syntax stripped.
    var plainText: String {
        Note.plainText(from: content)
    }
}

// MARK: - Note Text Conversion Cache

final class NoteTextCache {
    static let shared = NoteTextCache()

    private let plainTextCache = NSCache<NSString, NSString>()
    private let rtfDataCache = NSCache<NSString, NSData>()

    init() {
        plainTextCache.countLimit = 100
        rtfDataCache.countLimit = 50
    }

    private func cacheKey(for text: String) -> NSString {
        "\(text.utf8.count)_\(text.hashValue)" as NSString
    }

    func plainText(for markdown: String) -> String? {
        plainTextCache.object(forKey: cacheKey(for: markdown)) as String?
    }

    func setPlainText(_ plainText: String, for markdown: String) {
        plainTextCache.setObject(plainText as NSString, forKey: cacheKey(for: markdown))
    }

    func rtfData(for markdown: String) -> Data? {
        rtfDataCache.object(forKey: cacheKey(for: markdown)) as Data?
    }

    func setRtfData(_ data: Data, for markdown: String) {
        rtfDataCache.setObject(data as NSData, forKey: cacheKey(for: markdown))
    }

    func clear() {
        plainTextCache.removeAllObjects()
        rtfDataCache.removeAllObjects()
    }
}

// MARK: - Static text conversion helpers (used by Coordinator for selection copy)

extension Note {
    private struct TextRegexRule {
        let regex: NSRegularExpression
        let template: String
    }

    private static let plainTextRules: [TextRegexRule] = [
        ("^```[^\\n]*$", ""),
        ("(?m)^#{1,6}\\s+", ""),
        ("\\*{3}([^*]+)\\*{3}", "$1"),
        ("_{3}([^_]+)_{3}", "$1"),
        ("\\*{2}([^*]+)\\*{2}", "$1"),
        ("_{2}([^_]+)_{2}", "$1"),
        ("\\*([^*]+)\\*", "$1"),
        ("(?<=\\s|^)_([^_]+)_(?=\\s|$)", "$1"),
        ("~~([^~]+)~~", "$1"),
        ("\\[([^\\]]+)\\]\\([^)]+\\)", "$1"),
        ("!\\[([^\\]]*)]\\([^)]+\\)", "$1"),
        ("`([^`]+)`", "$1"),
        ("(?m)^>\\s?", ""),
        ("(?m)^[-*_]{3,}\\s*$", ""),
        ("(?m)^\\s*[-*+]\\s+\\[[ xX]\\]\\s", ""),
        ("(?m)^\\s*[-*+]\\s+", ""),
        ("(?m)^\\s*\\d+\\.\\s+", ""),
        ("\\n{3,}", "\n\n"),
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return TextRegexRule(regex: regex, template: template)
    }

    private static let inlineHTMLRules: [TextRegexRule] = [
        ("\\*{3}(.+?)\\*{3}", "<strong><em>$1</em></strong>"),
        ("_{3}(.+?)_{3}", "<strong><em>$1</em></strong>"),
        ("\\*{2}(.+?)\\*{2}", "<strong>$1</strong>"),
        ("_{2}(.+?)_{2}", "<strong>$1</strong>"),
        ("\\*([^*\\n]+)\\*", "<em>$1</em>"),
        ("~~(.+?)~~", "<del>$1</del>"),
        ("`([^`]+)`", "<code>$1</code>"),
        ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>"),
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return TextRegexRule(regex: regex, template: template)
    }

    private static let taskListRegex = try? NSRegularExpression(pattern: "^\\s*[-*+]\\s+\\[[xX ]\\]")
    private static let unorderedListRegex = try? NSRegularExpression(pattern: "^\\s*[-*+]\\s")
    private static let orderedListRegex = try? NSRegularExpression(pattern: "^\\s*\\d+\\.\\s")
    private static let hrRegex = try? NSRegularExpression(pattern: "^[-*_]{3,}\\s*$")
    private static let taskStripRegex = try? NSRegularExpression(pattern: "^\\s*[-*+]\\s+\\[[xX ]?\\]\\s*")
    private static let unorderedStripRegex = try? NSRegularExpression(pattern: "^\\s*[-*+]\\s+")
    private static let orderedStripRegex = try? NSRegularExpression(pattern: "^\\s*\\d+\\.\\s+")

    private static func hasRegexMatch(_ regex: NSRegularExpression?, in text: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func replaceRegex(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    /// Convert markdown to RTF data using the HTML → NSAttributedString pipeline.
    /// Must be called on the main thread (NSAttributedString HTML parsing uses WebKit).
    static func rtfData(from markdown: String) -> Data? {
        if let cached = NoteTextCache.shared.rtfData(for: markdown) {
            return cached
        }
        let html = markdownToHTML(markdown)
        guard let htmlData = html.data(using: .utf8),
              let attrStr = try? NSAttributedString(
                  data: htmlData,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil,
              )
        else { return nil }
        let data = attrStr.rtf(
            from: NSRange(location: 0, length: attrStr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf],
        )
        if let data {
            NoteTextCache.shared.setRtfData(data, for: markdown)
        }
        return data
    }

    /// Strip all Markdown syntax and return plain text.
    static func plainText(from markdown: String) -> String {
        if let cached = NoteTextCache.shared.plainText(for: markdown) {
            return cached
        }
        var text = markdown
        for rule in plainTextRules {
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            text = rule.regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: rule.template)
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        NoteTextCache.shared.setPlainText(result, for: markdown)
        return result
    }

    // MARK: - HTML conversion for RTF pipeline

    private static func markdownToHTML(_ text: String) -> String {
        let style = """
        body{font-family:-apple-system,sans-serif;font-size:14px;line-height:1.5}\
        h1{font-size:24px;font-weight:bold;margin:6px 0}\
        h2{font-size:20px;font-weight:bold;margin:6px 0}\
        h3{font-size:17px;font-weight:bold;margin:6px 0}\
        h4{font-size:15px;font-weight:bold;margin:4px 0}\
        p{margin:6px 0}ul,ol{margin:4px 0;padding-left:20px}\
        blockquote{margin:4px 0 4px 8px;padding-left:8px;border-left:3px solid #888}\
        pre{font-family:monospace;margin:6px 0}code{font-family:monospace}
        """
        var html = "<html><head><meta charset='utf-8'><style>\(style)</style></head><body>"
        let lines = text.components(separatedBy: "\n")
        var i = 0
        var inCodeBlock = false
        var codeLines: [String] = []
        var openList = ""

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                if inCodeBlock {
                    html += escapeHTML(codeLines.joined(separator: "\n")) + "</code></pre>"
                    codeLines = []; inCodeBlock = false
                } else {
                    if !openList.isEmpty {
                        html += "</\(openList)>"; openList = ""
                    }
                    html += "<pre><code>"; inCodeBlock = true
                }
                i += 1; continue
            }
            if inCodeBlock {
                codeLines.append(line); i += 1; continue
            }

            // Close open list unless this line continues it or is blank
            if !openList.isEmpty, !line.isEmpty,
               !hasRegexMatch(unorderedListRegex, in: line),
               !hasRegexMatch(orderedListRegex, in: line)
            {
                html += "</\(openList)>"; openList = ""
            }

            if line.hasPrefix("# ") {
                html += "<h1>" + inlineHTML(String(line.dropFirst(2))) + "</h1>"
            } else if line.hasPrefix("## ") {
                html += "<h2>" + inlineHTML(String(line.dropFirst(3))) + "</h2>"
            } else if line.hasPrefix("### ") {
                html += "<h3>" + inlineHTML(String(line.dropFirst(4))) + "</h3>"
            } else if line.hasPrefix("#### ") {
                html += "<h4>" + inlineHTML(String(line.dropFirst(5))) + "</h4>"
            } else if line.hasPrefix("> ") {
                html += "<blockquote><p>" + inlineHTML(String(line.dropFirst(2))) + "</p></blockquote>"
            } else if hasRegexMatch(taskListRegex, in: line) {
                let checked = line.contains("[x]") || line.contains("[X]")
                let content = replaceRegex(taskStripRegex, in: line, with: "")
                if openList != "ul" {
                    html += "<ul>"; openList = "ul"
                }
                html += "<li>" + (checked ? "&#x2611; " : "&#x2610; ") + inlineHTML(content) + "</li>"
            } else if hasRegexMatch(unorderedListRegex, in: line) {
                let content = replaceRegex(unorderedStripRegex, in: line, with: "")
                if openList != "ul" {
                    html += "<ul>"; openList = "ul"
                }
                html += "<li>" + inlineHTML(content) + "</li>"
            } else if hasRegexMatch(orderedListRegex, in: line) {
                let content = replaceRegex(orderedStripRegex, in: line, with: "")
                if openList != "ol" {
                    html += "<ol>"; openList = "ol"
                }
                html += "<li>" + inlineHTML(content) + "</li>"
            } else if hasRegexMatch(hrRegex, in: line) {
                html += "<hr>"
            } else if line.isEmpty {
                html += "<p>&nbsp;</p>"
            } else {
                html += "<p>" + inlineHTML(line) + "</p>"
            }
            i += 1
        }

        if !openList.isEmpty {
            html += "</\(openList)>"
        }
        if inCodeBlock {
            html += escapeHTML(codeLines.joined(separator: "\n")) + "</code></pre>"
        }
        html += "</body></html>"
        return html
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inlineHTML(_ text: String) -> String {
        var s = escapeHTML(text)
        for rule in inlineHTMLRules {
            let range = NSRange(s.startIndex ..< s.endIndex, in: s)
            s = rule.regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: rule.template)
        }
        return s
    }
}
