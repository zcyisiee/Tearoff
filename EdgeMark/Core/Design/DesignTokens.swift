import AppKit
import SwiftUI

// MARK: - DesignToken

/// EdgeMark's design language — the single source of truth for colors, radii,
/// spacing and type. Palette derived from claude-cream
/// (github.com/kakarrot-dev/claude-cream): warm ivory canvas instead of cold
/// white, a warm ink text ramp, hairline borders, and a restrained amber
/// accent used only for interactive states.
///
/// Every value here adapts to light/dark automatically (dynamic NSColor
/// providers keyed on the effective appearance, which `AppSettings.applyAppearance`
/// controls app-wide). Views must not hardcode corner radii, spacing steps,
/// highlight opacities, or neutral colors — use these tokens.
enum DesignToken {
    // MARK: Color — surfaces

    /// Soft raised surface — secondary strips, insets, hover fills.
    static let surfaceSoft = dynamic(light: 0xF8F7F2, dark: 0x313230)
    /// Card surface — the brightest layer. Also the solid fallback used when
    /// Reduce Transparency is on (glass fills swap to this).
    static let surfaceCard = dynamic(light: 0xFFFFFF, dark: 0x343533)
    /// Inset surface — wells, code blocks, inputs.
    static let surfaceInset = dynamic(light: 0xF0EEE6, dark: 0x292A29)

    /// Frosted card fill — a translucent wash that lets the vibrancy backdrop
    /// read through, floating each card as its own pane (SideNotes-style).
    /// Swap for `surfaceCard` under Reduce Transparency.
    static let glassCard = dynamicAlpha(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.055)
    /// Frosted inset fill — inputs and wells on glass surfaces.
    static let glassInset = dynamicAlpha(light: 0x8A7A55, dark: 0x000000, lightAlpha: 0.08, darkAlpha: 0.22)

    // MARK: Color — lines

    static let hairline = dynamic(light: 0xD8D2C3, dark: 0x45433D)
    static let hairlineSoft = dynamic(light: 0xE5E0D4, dark: 0x3A3934)

    // MARK: Color — text

    static let ink = dynamic(light: 0x29271D, dark: 0xE9E6DC)
    static let bodyText = dynamic(light: 0x403D36, dark: 0xDDD9CD)
    static let bodyStrong = dynamic(light: 0x302E28, dark: 0xF0EDE2)
    static let muted = dynamic(light: 0x6D675B, dark: 0xA8A294)
    static let mutedSoft = dynamic(light: 0x8D8575, dark: 0x87816F)

    // MARK: Color — accent (theme-driven, amber in the default Cream theme)

    static var accent: Color { ThemeEngine.shared.activeTheme.accent }
    static let accentActive = dynamic(light: 0x9F6819, dark: 0xF0CF92)
    /// Text/icon color on top of accent fills.
    static let onAccent = dynamic(light: 0xFFF8F3, dark: 0x3D2C0F)
    /// Tinted wash of the accent — selections, active rows, badge fills.
    static let accentSubtle = dynamic(light: 0xEADFC8, dark: 0x403623)
    /// Editor text selection background.
    static let selection = dynamic(light: 0xE6D7B7, dark: 0x4A4030)

    // MARK: Color — supporting hues (claude-cream semantics)

    static let teal = dynamic(light: 0x2C6F75, dark: 0x75B5BC)
    static let success = dynamic(light: 0x4B6F3D, dark: 0x94B583)
    static let warning = dynamic(light: 0x8A5E16, dark: 0xD9B25E)
    static let error = dynamic(light: 0x7C1B13, dark: 0xE07A6D)

    // MARK: - Radius

    enum Radius {
        /// Tiny chips, color strips, inline highlights.
        static let xs: CGFloat = 4
        /// Buttons, list rows, small controls.
        static let sm: CGFloat = 6
        /// Cards, popovers, thumbnails.
        static let md: CGFloat = 8
        /// Panels, windows, large containers.
        static let lg: CGFloat = 10
        /// Board cards and the header pill — the SideNotes-style generous rounding.
        static let card: CGFloat = 16
    }

    // MARK: - Space

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    // MARK: - Alpha (interactive fills over neutral surfaces)

    enum Alpha {
        /// Barely-there hover wash.
        static let ghost: Double = 0.04
        /// Standard hover fill.
        static let hover: Double = 0.07
        /// Selected / active fill (prefer accentSubtle for accent-tinted selection).
        static let selected: Double = 0.12
    }

    // MARK: - Typography (compact editorial scale)

    enum Typography {
        /// Screen title (home, list). Compact — 15pt semibold, not .title2.bold.
        static let display = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// Note title in the editor header.
        static let heading = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        /// List rows, outline entries.
        static let callout = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        /// Uppercase micro section header (add `.tracking(0.6)` + uppercase text).
        static let sectionHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
    }

    // MARK: - Helpers

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    private static func dynamicAlpha(light: UInt32, dark: UInt32, lightAlpha: Double, darkAlpha: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(rgb: isDark ? dark : light)
            return base.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }
}

// MARK: - NSColor RGB helper

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
            green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(rgb & 0xFF) / 255.0,
            alpha: 1,
        )
    }
}
