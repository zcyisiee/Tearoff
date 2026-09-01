import AppKit
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

@Observable
final class AppSettings {
    static let shared = AppSettings()

    // MARK: - Sort

    enum SortBy: String, CaseIterable {
        case name = "Name"
        case dateModified = "Date Modified"
        case dateCreated = "Date Created"
        case manual = "Manual"
    }

    var sortBy: SortBy = .dateModified {
        didSet { UserDefaults.standard.set(sortBy.rawValue, forKey: "sortBy") }
    }

    var sortAscending: Bool = false {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "sortAscending") }
    }

    /// PostScript font name (e.g. "HelveticaNeue", "SFMono-Regular"). nil = system font.
    var editorFontName: String? {
        didSet {
            if let name = editorFontName {
                UserDefaults.standard.set(name, forKey: "editorFontName")
            } else {
                UserDefaults.standard.removeObject(forKey: "editorFontName")
            }
            NotificationCenter.default.post(name: .editorFontChanged, object: nil)
        }
    }

    /// Editor body font size in pixels. Headings scale relative to this via em units.
    var editorFontSize: Double = 16 {
        didSet {
            UserDefaults.standard.set(editorFontSize, forKey: "editorFontSize")
            NotificationCenter.default.post(name: .editorFontChanged, object: nil)
        }
    }

    // MARK: - Board typography

    /// Board (card stream) base font size in points. The card title, content
    /// headings, body and meta text all derive from this so the whole main
    /// interface scales together. Independent of `editorFontSize`.
    var boardFontSize: Double = 13.5 {
        didSet { UserDefaults.standard.set(boardFontSize, forKey: "boardFontSize") }
    }

    // MARK: - Outline navigation

    /// Where the markdown outline lives: a right-hand tree panel or a top
    /// breadcrumb strip under the note header.
    enum OutlinePosition: String, CaseIterable {
        case top
        case right
    }

    /// Whether the outline (panel or breadcrumb) is shown in the editor.
    var outlineVisible: Bool = true {
        didSet { UserDefaults.standard.set(outlineVisible, forKey: "outlineVisible") }
    }

    /// Outline placement — right panel or top breadcrumb.
    var outlinePosition: OutlinePosition = .right {
        didSet { UserDefaults.standard.set(outlinePosition.rawValue, forKey: "outlinePosition") }
    }

    /// Right outline panel width in points; user-draggable.
    var outlinePanelWidth: CGFloat = 230 {
        didSet { UserDefaults.standard.set(Double(outlinePanelWidth), forKey: "outlinePanelWidth") }
    }

    // MARK: - Task checkbox symbols

    /// SF Symbol presets drawn for `- [ ]` / `- [x]` task-list items. Display-only —
    /// the underlying markdown stays standard GitHub task-list syntax; this only
    /// changes which glyph the engine draws over `[ ]` / `[x]`. Backed by
    /// `swift-markdown-engine` 0.10.1's `TaskCheckboxStyle`; names that fail to
    /// resolve fall back to the stock look at draw time.
    enum TaskCheckboxPreset: String, CaseIterable, Codable {
        case square
        case circle
        case diamond
        case shield
        case triangle
        case star
        case hexagon
        case heart

        var uncheckedSymbolName: String {
            switch self {
            case .square: "square"
            case .circle: "circle"
            case .diamond: "diamond"
            case .shield: "shield"
            case .triangle: "triangle"
            case .star: "star"
            case .hexagon: "hexagon"
            case .heart: "heart"
            }
        }

        var checkedSymbolName: String {
            switch self {
            case .square: "checkmark.square.fill"
            case .circle: "checkmark.circle.fill"
            case .diamond: "checkmark.diamond.fill"
            case .shield: "checkmark.shield.fill"
            case .triangle: "triangle.fill"
            case .star: "star.fill"
            case .hexagon: "hexagon.fill"
            case .heart: "heart.fill"
            }
        }
    }

    /// Default `.square` matches the engine default — no visual change for existing users.
    /// Live re-render of the editor is driven by `@Observable` tracking (the editor
    /// reads this via `.id(...)` in its body, so a change recreates the text view).
    var taskCheckboxPreset: TaskCheckboxPreset = .square {
        didSet { UserDefaults.standard.set(taskCheckboxPreset.rawValue, forKey: "taskCheckboxPreset") }
    }

    // MARK: - Appearance, updates, launch

    enum AppearanceMode: String {
        case system
        case light
        case dark
    }

    /// Appearance mode: system, light, or dark.
    var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    /// Whether the editor presents the note as raw Markdown source instead of
    /// the default rich WYSIWYG rendering. Persisted so the choice survives
    /// note switches and app restarts.
    var editorRawSourceMode: Bool = false {
        didSet { UserDefaults.standard.set(editorRawSourceMode, forKey: "editorRawSourceMode") }
    }

    // MARK: - Image storage

    /// Where pasted/dropped images are written. Both modes stay readable at
    /// render time — switching never migrates or breaks existing notes; it
    /// only decides where NEW images land.
    enum ImageStorageMode: String, CaseIterable {
        /// Shared `assets/` directory next to the note (Typora-style): visible
        /// in Finder and shared by every note in the same folder.
        case sharedAssets
        /// Legacy hidden `.<NoteName>/` directory co-located with each note.
        case hiddenDirectory
    }

    /// Default `.sharedAssets` (new Typora-like behavior); existing vaults keep
    /// rendering legacy hidden-dir images regardless of this setting.
    var imageStorageMode: ImageStorageMode = .sharedAssets {
        didSet { UserDefaults.standard.set(imageStorageMode.rawValue, forKey: "imageStorageMode") }
    }


    /// Whether to automatically check for updates on launch (24h throttle).
    var autoCheckUpdates: Bool = true {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }

    /// Whether the app launches at login.
    var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }

    func applyAppearance() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let msg = error.localizedDescription
            Log.app.error("Failed to update login item: \(msg)")
        }
    }

    // MARK: - Spell checking

    /// Mirrors `SpellCheckingPolicy.continuousSpellChecking`.
    /// Default on — matches Notes / TextEdit behavior.
    var spellCheckingEnabled: Bool = true {
        didSet { UserDefaults.standard.set(spellCheckingEnabled, forKey: "spellCheckingEnabled") }
    }

    /// Mirrors `SpellCheckingPolicy.grammarChecking`.
    /// Default off — opt-in for writing-focused workflows.
    var grammarCheckingEnabled: Bool = false {
        didSet { UserDefaults.standard.set(grammarCheckingEnabled, forKey: "grammarCheckingEnabled") }
    }

    /// Mirrors `SpellCheckingPolicy.automaticSpellingCorrection`.
    /// Default off — autocorrect is disruptive in code-heavy notes.
    var automaticSpellingCorrectionEnabled: Bool = false {
        didSet { UserDefaults.standard.set(automaticSpellingCorrectionEnabled, forKey: "automaticSpellingCorrectionEnabled") }
    }

    // MARK: - Board layout

    /// Note board organization: folder tabs over a card grid, or every folder
    /// as a collapsible section in one scrolling view.
    enum BoardLayout: String, CaseIterable {
        case tabs
        case sections
    }

    var boardLayout: BoardLayout = .tabs {
        didSet { UserDefaults.standard.set(boardLayout.rawValue, forKey: "boardLayout") }
    }

    /// Custom labels for color tags. Missing entries fall back to `TagColor.defaultLabel`.
    /// Persisted as a single UserDefaults dictionary keyed by raw color name.
    var tagLabels: [TagColor: String] = [:] {
        didSet {
            let raw = tagLabels.reduce(into: [String: String]()) { $0[$1.key.rawValue] = $1.value }
            UserDefaults.standard.set(raw, forKey: "tagLabels")
        }
    }

    /// Display label for a tag — user override if set, otherwise the default name.
    func label(for tag: TagColor) -> String {
        if let custom = tagLabels[tag], !custom.isEmpty {
            return custom
        }
        return tag.defaultLabel
    }

    /// Resolved NSFont for the editor — falls back to system font when no custom name is set.
    var editorFont: NSFont {
        let size = CGFloat(editorFontSize)
        if let name = editorFontName, let f = NSFont(name: name, size: size) {
            return f
        }
        return .systemFont(ofSize: size)
    }

    init() {
        LegacyDefaults.importIfNeeded()
        if let raw = UserDefaults.standard.string(forKey: "sortBy"),
           let value = SortBy(rawValue: raw)
        {
            sortBy = value
        }
        sortAscending = UserDefaults.standard.bool(forKey: "sortAscending")
        // If the saved font is no longer installed (e.g. user uninstalled it),
        // drop it silently so the editor falls back to the system font.
        if let saved = UserDefaults.standard.string(forKey: "editorFontName"),
           NSFont(name: saved, size: 13) != nil
        {
            editorFontName = saved
        } else {
            UserDefaults.standard.removeObject(forKey: "editorFontName")
        }
        let savedSize = UserDefaults.standard.object(forKey: "editorFontSize") as? Double
        editorFontSize = savedSize ?? 16
        boardFontSize = min(max(UserDefaults.standard.object(forKey: "boardFontSize") as? Double ?? 13.5, 11), 20)
        if let raw = UserDefaults.standard.string(forKey: "taskCheckboxPreset"),
           let value = TaskCheckboxPreset(rawValue: raw)
        {
            taskCheckboxPreset = value
        }
        outlineVisible = UserDefaults.standard.object(forKey: "outlineVisible") as? Bool ?? true
        if let raw = UserDefaults.standard.string(forKey: "outlinePosition"),
           let value = OutlinePosition(rawValue: raw)
        {
            outlinePosition = value
        }
        if let savedWidth = UserDefaults.standard.object(forKey: "outlinePanelWidth") as? Double {
            outlinePanelWidth = max(180, min(420, CGFloat(savedWidth)))
        }

        // Appearance, updates, launch (moved from ShortcutSettings)
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw)
        {
            appearanceMode = mode
        }
        editorRawSourceMode = UserDefaults.standard.bool(forKey: "editorRawSourceMode")
        if let raw = UserDefaults.standard.string(forKey: "imageStorageMode"),
           let value = ImageStorageMode(rawValue: raw)
        {
            imageStorageMode = value
        }
        autoCheckUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true
        launchAtLogin = UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false
        if let raw = UserDefaults.standard.object(forKey: "spellCheckingEnabled") as? Bool {
            spellCheckingEnabled = raw
        }
        if let raw = UserDefaults.standard.object(forKey: "grammarCheckingEnabled") as? Bool {
            grammarCheckingEnabled = raw
        }
        if let raw = UserDefaults.standard.object(forKey: "automaticSpellingCorrectionEnabled") as? Bool {
            automaticSpellingCorrectionEnabled = raw
        }
        if let raw = UserDefaults.standard.string(forKey: "boardLayout"),
           let value = BoardLayout(rawValue: raw)
        {
            boardLayout = value
        }
        if let raw = UserDefaults.standard.dictionary(forKey: "tagLabels") as? [String: String] {
            tagLabels = raw.reduce(into: [TagColor: String]()) { result, kv in
                if let color = TagColor(rawValue: kv.key) {
                    result[color] = kv.value
                }
            }
        }
    }

    /// Folder date to display based on the current sort setting.
    func folderDate(for folder: Folder) -> Date? {
        switch sortBy {
        case .name: folder.latestModifiedAt
        case .dateModified: folder.latestModifiedAt
        case .dateCreated: folder.earliestCreatedAt
        case .manual: folder.latestModifiedAt
        }
    }
}

extension AppSettings.SortBy {
    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .name: l10n["sort.name"]
        case .dateModified: l10n["sort.dateModified"]
        case .dateCreated: l10n["sort.dateCreated"]
        case .manual: l10n["sort.manual"]
        }
    }
}

extension Notification.Name {
    static let editorFontChanged = Notification.Name("editorFontChanged")
}

// MARK: - Board typography

extension AppSettings {
    /// Card title — largest tier, bold, identity-colored.
    var boardTitleFont: Font { .system(size: boardFontSize + 3.5, weight: .bold) }
    /// Content H2 — a step under the title, semibold, same accent family.
    var boardHeadingFont: Font { .system(size: boardFontSize + 2, weight: .semibold) }
    /// Content H3 — a step under H2, semibold, slightly softened accent.
    var boardSubheadingFont: Font { .system(size: boardFontSize + 1, weight: .semibold) }
    /// Preview body text.
    var boardBodyFont: Font { .system(size: boardFontSize) }
    /// Folder / date meta row.
    var boardMetaFont: Font { .system(size: max(boardFontSize - 2, 9)) }
}

extension AppSettings.BoardLayout {
    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .tabs: l10n["settings.boardLayout.tabs"]
        case .sections: l10n["settings.boardLayout.sections"]
        }
    }
}

extension AppSettings.OutlinePosition {
    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .top: l10n["settings.editor.outlinePosition.top"]
        case .right: l10n["settings.editor.outlinePosition.right"]
        }
    }
}

extension AppSettings.ImageStorageMode {
    func displayName(_ l10n: L10n) -> String {
        switch self {
        case .sharedAssets: l10n["settings.storage.images.shared"]
        case .hiddenDirectory: l10n["settings.storage.images.hidden"]
        }
    }
}

