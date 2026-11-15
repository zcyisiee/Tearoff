import AppKit
import SwiftUI

// MARK: - TearoffTheme

/// A named accent pairing: light/dark accent values the whole UI tints from.
/// The panel backdrop is a single fixed vibrancy material (SideNotes-style);
/// themes no longer carry a canvas tint or material choice.
struct TearoffTheme: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var isBuiltin = false

    var lightAccent: Color
    var darkAccent: Color

    enum CodingKeys: String, CodingKey {
        case id, name, isBuiltin
        case lightAccent, darkAccent
    }

    init(
        id: UUID = UUID(),
        name: String,
        isBuiltin: Bool = false,
        lightAccent: Color,
        darkAccent: Color,
    ) {
        self.id = id
        self.name = name
        self.isBuiltin = isBuiltin
        self.lightAccent = lightAccent
        self.darkAccent = darkAccent
    }

    /// `Color` isn't Codable on this deployment target — persist as hex strings.
    /// Legacy keys (lightCanvas/darkCanvas/material) are accepted and dropped so
    /// v2 theme payloads decode cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)).flatMap(UUID.init(uuidString:)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        isBuiltin = try c.decodeIfPresent(Bool.self, forKey: .isBuiltin) ?? false
        lightAccent = Self.decodeColor(c, .lightAccent) ?? TearoffTheme.builtinThemes[0].lightAccent
        darkAccent = Self.decodeColor(c, .darkAccent) ?? TearoffTheme.builtinThemes[0].darkAccent
    }

    private static func decodeColor(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Color? {
        guard let hex = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return Color(hex: hex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isBuiltin, forKey: .isBuiltin)
        try c.encode(lightAccent.toHex(), forKey: .lightAccent)
        try c.encode(darkAccent.toHex(), forKey: .darkAccent)
    }

    /// Interactive accent — selection, toggles, highlights.
    var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkAccent : lightAccent)
        })
    }

    /// Small preview swatches for the settings grid.
    var previewColors: [Color] {
        [lightAccent, darkAccent]
    }
}

// MARK: - Built-in themes

extension TearoffTheme {
    /// Cream is the Tearoff default (claude-cream); the rest re-hue the same
    /// structure. Built-ins can't be edited or deleted — duplicate instead.
    static let builtinThemes: [TearoffTheme] = [
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E01")!,
            name: "Cream",
            isBuiltin: true,
            lightAccent: Color(red: 0xB7 / 255, green: 0x79 / 255, blue: 0x1F / 255),
            darkAccent: Color(red: 0xE6 / 255, green: 0xBF / 255, blue: 0x7A / 255),
        ),
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E02")!,
            name: "Graphite",
            isBuiltin: true,
            lightAccent: Color(red: 0x51 / 255, green: 0x5B / 255, blue: 0x74 / 255),
            darkAccent: Color(red: 0xA2 / 255, green: 0xB0 / 255, blue: 0xCC / 255),
        ),
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E03")!,
            name: "Sage",
            isBuiltin: true,
            lightAccent: Color(red: 0x5F / 255, green: 0x7A / 255, blue: 0x52 / 255),
            darkAccent: Color(red: 0xA9 / 255, green: 0xC2 / 255, blue: 0x9A / 255),
        ),
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E04")!,
            name: "Slate",
            isBuiltin: true,
            lightAccent: Color(red: 0x3E / 255, green: 0x5C / 255, blue: 0x76 / 255),
            darkAccent: Color(red: 0x8F / 255, green: 0xB0 / 255, blue: 0xCC / 255),
        ),
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E05")!,
            name: "Rose",
            isBuiltin: true,
            lightAccent: Color(red: 0xA1 / 255, green: 0x5A / 255, blue: 0x66 / 255),
            darkAccent: Color(red: 0xD9 / 255, green: 0x9A / 255, blue: 0xA6 / 255),
        ),
        TearoffTheme(
            id: UUID(uuidString: "A0E5A7B4-6F2E-4C1D-9A50-1D2B3C4D5E06")!,
            name: "Sand",
            isBuiltin: true,
            lightAccent: Color(red: 0x8A / 255, green: 0x5E / 255, blue: 0x16 / 255),
            darkAccent: Color(red: 0xD9 / 255, green: 0xB2 / 255, blue: 0x5E / 255),
        ),
    ]

    static let defaultThemeID = builtinThemes[0].id
}

// MARK: - ThemeEngine

/// Observable theme registry — the single source of truth for the active
/// theme. `DesignToken.accent` reads through this engine, so any view body
/// that touches that token re-renders on theme change (the Observation
/// framework tracks the access through the singleton).
@Observable
final class ThemeEngine {
    static let shared = ThemeEngine()

    static let storageKey = "customThemes"
    static let activeThemeKey = "activeThemeID"

    private(set) var customThemes: [TearoffTheme] = []
    private(set) var activeTheme: TearoffTheme = .builtinThemes[0]

    private init() {
        LegacyDefaults.importIfNeeded()
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([TearoffTheme].self, from: data)
        {
            customThemes = stored
        }
        activeTheme = resolvedActiveTheme()
        migrateLegacyTintIfNeeded()
    }

    var allThemes: [TearoffTheme] {
        TearoffTheme.builtinThemes + customThemes
    }

    // MARK: - Resolution

    private func resolvedActiveTheme() -> TearoffTheme {
        guard let idData = UserDefaults.standard.data(forKey: Self.activeThemeKey),
              let id = try? JSONDecoder().decode(UUID.self, from: idData),
              let theme = allThemes.first(where: { $0.id == id })
        else {
            return .builtinThemes[0]
        }
        return theme
    }

    /// Old `panelTint` values map onto the closest built-in theme.
    private func migrateLegacyTintIfNeeded() {
        guard UserDefaults.standard.data(forKey: Self.activeThemeKey) == nil,
              let raw = UserDefaults.standard.string(forKey: "panelTint")
        else { return }
        let mapped: TearoffTheme = switch raw {
        case "graphite": .builtinThemes[1]
        case "sage": .builtinThemes[2]
        case "slate": .builtinThemes[3]
        case "rose": .builtinThemes[4]
        case "sand": .builtinThemes[5]
        default: .builtinThemes[0]
        }
        activate(mapped)
    }

    // MARK: - Activation & editing

    func activate(_ theme: TearoffTheme) {
        activeTheme = theme
        if let data = try? JSONEncoder().encode(theme.id) {
            UserDefaults.standard.set(data, forKey: Self.activeThemeKey)
        }
    }

    func theme(withID id: UUID) -> TearoffTheme? {
        allThemes.first(where: { $0.id == id })
    }

    /// Add a custom theme (copy of an existing one with a fresh id) and activate it.
    func addCopy(of theme: TearoffTheme) -> TearoffTheme {
        var copy = theme
        copy.id = UUID()
        copy.name = localizedCopyName(of: theme.name)
        copy.isBuiltin = false
        customThemes.append(copy)
        persistCustomThemes()
        activate(copy)
        return copy
    }

    /// Update a custom theme in place. Built-ins are rejected.
    func update(_ theme: TearoffTheme) {
        guard !theme.isBuiltin,
              let index = customThemes.firstIndex(where: { $0.id == theme.id })
        else { return }
        customThemes[index] = theme
        persistCustomThemes()
        if activeTheme.id == theme.id {
            activeTheme = theme
        }
    }

    func remove(_ theme: TearoffTheme) {
        guard !theme.isBuiltin else { return }
        customThemes.removeAll(where: { $0.id == theme.id })
        persistCustomThemes()
        if activeTheme.id == theme.id {
            activate(.builtinThemes[0])
        }
    }

    private func persistCustomThemes() {
        if let data = try? JSONEncoder().encode(customThemes) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func localizedCopyName(of name: String) -> String {
        let l10n = L10n.shared
        if name.hasPrefix("Tearoff ") {
            return name + " 2"
        }
        return l10n["themes.copyPrefix"] + " " + name
    }
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var value: UInt64 = 0
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard Scanner(string: raw).scanHexInt64(&value), raw.count == 6 || raw.count == 8 else { return nil }
        let r, g, b, a: Double
        if raw.count == 8 {
            a = Double((value >> 24) & 0xFF) / 255
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            a = 1
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int(round(resolved.redComponent * 255))
        let g = Int(round(resolved.greenComponent * 255))
        let b = Int(round(resolved.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - DesignToken integration is in Core/Design/DesignTokens.swift

// (`accent` is a computed property backed by ThemeEngine).
