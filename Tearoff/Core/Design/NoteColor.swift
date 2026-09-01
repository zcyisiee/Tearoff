import AppKit
import SwiftUI

/// Per-note identity color — the SideNotes-style "color as identity" system.
/// A single optional color per note, stored in the sidecar as its raw value.
///
/// The palette is derived from claude-cream's supporting hues so cards sit
/// naturally on the warm ivory canvas. Each case provides:
/// - `strip`: the saturated marker (color-strip mode, title accents)
/// - `cardTint`: a low-saturation wash (full-card background mode)
enum NoteColor: String, CaseIterable, Codable {
    case amber
    case teal
    case olive
    case ochre
    case brick
    case plum
    case ink
    case sand

    /// Localized display name for menus.
    var label: String {
        L10n.shared["noteColor.\(rawValue)"]
    }

    /// Saturated marker color (left strip, selected borders, accents).
    var strip: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: dark ? stripDark : stripLight)
        })
    }

    /// Low-saturation card background wash (full-tint display mode).
    var cardTint: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: dark ? tintDark : tintLight)
        })
    }

    private var stripLight: UInt32 {
        switch self {
        case .amber: 0xB7791F
        case .teal: 0x2C6F75
        case .olive: 0x4B6F3D
        case .ochre: 0x8A5E16
        case .brick: 0x7C1B13
        case .plum: 0x6F3F82
        case .ink: 0x403D36
        case .sand: 0xA08A5F
        }
    }

    private var stripDark: UInt32 {
        switch self {
        case .amber: 0xE6BF7A
        case .teal: 0x75B5BC
        case .olive: 0x94B583
        case .ochre: 0xD9B25E
        case .brick: 0xE07A6D
        case .plum: 0xB085C7
        case .ink: 0xA8A294
        case .sand: 0xC4AF85
        }
    }

    private var tintLight: UInt32 {
        switch self {
        case .amber: 0xF2E7CF
        case .teal: 0xDCe9EA
        case .olive: 0xE2EBDC
        case .ochre: 0xF0E5CE
        case .brick: 0xF2DDDA
        case .plum: 0xE9E0F0
        case .ink: 0xE7E4DC
        case .sand: 0xEFE7D2
        }
    }

    private var tintDark: UInt32 {
        switch self {
        case .amber: 0x3B3120
        case .teal: 0x223538
        case .olive: 0x2B3526
        case .ochre: 0x3A3320
        case .brick: 0x3D2624
        case .plum: 0x372D40
        case .ink: 0x3B3B38
        case .sand: 0x3B3628
        }
    }
}

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
