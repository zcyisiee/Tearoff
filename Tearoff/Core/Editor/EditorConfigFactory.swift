import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import MarkdownEngineLatex
import SwiftUI

// MARK: - Shared editor configuration

extension MarkdownEditorConfiguration {
    /// Shared config for the live editor and the read-only preview/card view.
    ///
    /// Both call sites must stay in sync so previews match the editor. Keeps the
    /// text insets, highlight/strikethrough extensions, task-checkbox style, and the
    /// image/syntax/latex services in one place. The live editor passes its
    /// formatting-request `bus`; the read-only view uses the default (no formatting).
    ///
    /// - Parameters:
    ///   - accentColor: When provided, tints heading `#` markers with this color so
    ///     the editor accent tracks the note's identity color. Pass `nil` to keep the
    ///     default `theme.headingMarker` (gray). Note: the engine API can only tint the
    ///     marker glyphs — heading text itself inherits `bodyText` (engine limitation).
    ///   - useBoardTypography: When `true`, heading multipliers and paragraph spacing
    ///     match the board card preview scale (compact). Pass `false` (default) for the
    ///     full-page editor scale.
    static func makeTearoffConfig(
        noteFolder: String,
        bus: MarkdownEditorBus = .default,
        rawSourceMode: Bool = false,
        accentColor: Color? = nil,
        useBoardTypography: Bool = false,
    ) -> MarkdownEditorConfiguration {
        let preset = AppSettings.shared.taskCheckboxPreset
        var config = MarkdownEditorConfiguration.default
        config.textInsets = TextInsets(horizontal: 16, vertical: 12)
        config.rawSourceMode = rawSourceMode
        // Register highlight (==text==) and strikethrough (~~text~~). Opt-in since
        // swift-markdown-engine 0.10; without this, the markers render as literal text.
        config.extensions = [HighlightExtension(), StrikethroughExtension()]
        config.taskCheckbox = TaskCheckboxStyle(
            uncheckedSymbolName: preset.uncheckedSymbolName,
            checkedSymbolName: preset.checkedSymbolName,
        )
        config.services = MarkdownEditorServices(
            images: TearoffImageProvider(noteFolder: noteFolder),
            syntaxHighlighter: HighlighterSwiftBridge(),
            latex: SwiftMathBridge(),
            bus: bus,
        )

        // Accent color: tint the heading marker glyphs (`#`/`##`/…). The engine API
        // does not expose a separate heading-text color — heading text inherits bodyText.
        if let accentColor {
            var theme = config.theme
            theme.headingMarker = NSColor(accentColor)
            config.theme = theme
        }

        // Board typography: heading multipliers and paragraph spacing aligned with
        // the card preview so the inline editor and expanded editor look consistent
        // with the board card preview pane.
        if useBoardTypography {
            let b = CGFloat(AppSettings.shared.boardFontSize)
            // Compute multipliers so heading point sizes match the board font scale:
            //   H1 → boardFontSize + 3.5 (boardTitleFont)
            //   H2 → boardFontSize + 2   (boardHeadingFont)
            //   H3 → boardFontSize + 1   (boardSubheadingFont)
            //   H4–H6 keep the engine defaults (1.0, 0.83, 0.67)
            let h1 = (b + 3.5) / b
            let h2 = (b + 2.0) / b
            let h3 = (b + 1.0) / b
            config.headings = HeadingStyle(
                fontMultipliers: [h1, h2, h3, 1.0, 0.83, 0.67],
                topSpacingEm: config.headings.topSpacingEm,
            )
            // Tighten paragraph spacing to match the denser card preview feel.
            config.paragraph = ParagraphStyle(
                spacingFactor: 0.15,
                lineHeightExtraSpacing: config.paragraph.lineHeightExtraSpacing,
            )
        }

        return config
    }
}
