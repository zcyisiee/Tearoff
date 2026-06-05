import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

/// Non-editable Markdown viewer using swift-markdown-engine.
/// Used for previewing trashed notes.
struct ReadOnlyMarkdownView: View {
    let content: String

    var body: some View {
        var config = MarkdownEditorConfiguration.default
        config.services = MarkdownEditorServices(
            syntaxHighlighter: HighlighterSwiftBridge(),
            latex: SwiftMathBridge(),
        )
        return NativeTextViewWrapper(
            text: .constant(content),
            configuration: config,
            isEditable: false,
        )
    }
}
