import SwiftUI

// MARK: - BoardSettingsView

/// In-panel settings page (replaces the old standalone settings window).
/// One scrolling column of frosted glass sections: Appearance, Layout,
/// Behavior, Shortcuts, Storage, About. Reuses the existing settings stores —
/// no new persistence.
struct BoardSettingsView: View {
    @Environment(L10n.self) var l10n
    @Environment(AppSettings.self) var appSettings

    private var engine = ThemeEngine.shared

    @State private var editingTheme: TearoffTheme?
    @State private var isNewTheme = false

    // Behavior mirrors (PanelSettings is a plain class)
    @State private var edgeSide: EdgeSide = PanelSettings.shared.edgeSide
    @State private var dismissalMode: DismissalMode = PanelSettings.shared.dismissalMode
    @State private var edgeActivationEnabled = PanelSettings.shared.edgeActivationEnabled
    @State private var activationDelay = PanelSettings.shared.activationDelay
    @State private var toggleDismissDelay = PanelSettings.shared.toggleDismissDelay
    @State private var excludeCorners = PanelSettings.shared.excludeCorners
    @State private var autoHideOnMouseExit = PanelSettings.shared.autoHideOnMouseExit
    @State private var hideDelay = PanelSettings.shared.hideDelay
    @State private var hideOnClickOutside = PanelSettings.shared.hideOnClickOutside
    @State private var swipeToNavigateEnabled = PanelSettings.shared.swipeToNavigateEnabled
    @State private var editorSwipeToNavigateEnabled = PanelSettings.shared.editorSwipeToNavigateEnabled
    @State private var swipeGestureSensitivity = PanelSettings.shared.swipeGestureSensitivity
    @State private var animationStyle = PanelSettings.shared.animationStyle

    // Storage mirrors
    @State private var roots: [StorageRoot] = StorageSettings.shared.storageRoots
    @State private var activeRootID: String? = StorageSettings.shared.activeStorageRoot?.id
    @State private var askOnLaunch = StorageSettings.shared.askOnLaunch
    @State private var removalBlockedMessage: String?

    // Shortcuts mirrors
    @State private var toggleShortcut: KeyboardShortcut? = ShortcutSettings.shared.togglePanelShortcut
    @State private var newNoteShortcut: KeyboardShortcut? = ShortcutSettings.shared.newNoteShortcut
    @State private var newFolderShortcut: KeyboardShortcut? = ShortcutSettings.shared.newFolderShortcut
    @State private var searchShortcut: KeyboardShortcut? = ShortcutSettings.shared.searchShortcut
    @State private var pinShortcut: KeyboardShortcut? = ShortcutSettings.shared.pinShortcut
    @State private var previousNoteShortcut: KeyboardShortcut? = ShortcutSettings.shared.previousNoteShortcut
    @State private var nextNoteShortcut: KeyboardShortcut? = ShortcutSettings.shared.nextNoteShortcut

    @State private var selectedLocale = L10n.shared.locale

    var body: some View {
        ScrollView {
            VStack(spacing: DesignToken.Space.md) {
                appearanceSection(settings: appSettings)
                layoutSection(settings: appSettings)
                behaviorSection
                shortcutsSection
                storageSection
                aboutSection
            }
            .padding(.horizontal, DesignToken.Space.lg)
            .padding(.vertical, DesignToken.Space.md)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $editingTheme) { theme in
            ThemeEditorSheet(
                theme: theme,
                isNew: isNewTheme,
                onSave: { engine.update($0) },
            )
            .frame(width: 360)
        }
        .alert("Cannot remove", isPresented: .constant(removalBlockedMessage != nil)) {
            Button(l10n["common.ok"]) { removalBlockedMessage = nil }
        } message: {
            Text(removalBlockedMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .storageRootChanged)) { _ in
            roots = StorageSettings.shared.storageRoots
            activeRootID = StorageSettings.shared.activeStorageRoot?.id
            askOnLaunch = StorageSettings.shared.askOnLaunch
        }
    }

    // MARK: - Appearance

    private func appearanceSection(@Bindable settings: AppSettings) -> some View {
        SettingsSection(title: l10n["settings.general.appearance"], icon: "circle.lefthalf.filled") {
            Picker(l10n["settings.general.appearance"], selection: $settings.appearanceMode) {
                Text(l10n["settings.appearance.system"]).tag(AppSettings.AppearanceMode.system)
                Text(l10n["settings.appearance.light"]).tag(AppSettings.AppearanceMode.light)
                Text(l10n["settings.appearance.dark"]).tag(AppSettings.AppearanceMode.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            themeGrid

            row(l10n["settings.editor.font"]) {
                HStack(spacing: DesignToken.Space.xs) {
                    Text(fontDescription)
                        .foregroundStyle(DesignToken.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    FontPickerButton(title: l10n["settings.editor.chooseFont"])
                    if appSettings.editorFontName != nil {
                        Button(l10n["settings.editor.resetFont"]) {
                            appSettings.editorFontName = nil
                        }
                        .font(DesignToken.Typography.caption)
                    }
                }
            }

            row(l10n["settings.editor.fontSize"]) {
                HStack(spacing: DesignToken.Space.xs) {
                    Text("\(Int(appSettings.editorFontSize)) pt")
                        .foregroundStyle(DesignToken.muted)
                        .monospacedDigit()
                    Stepper(
                        "",
                        value: $settings.editorFontSize, in: 11 ... 28, step: 1,
                    )
                    .labelsHidden()
                    if appSettings.editorFontSize != 16 {
                        Button(l10n["settings.editor.resetFont"]) {
                            appSettings.editorFontSize = 16
                        }
                        .font(DesignToken.Typography.caption)
                    }
                }
            }

            row(l10n["settings.board.fontSize"]) {
                HStack(spacing: DesignToken.Space.xs) {
                    Text(String(format: "%.1f pt", appSettings.boardFontSize))
                        .foregroundStyle(DesignToken.muted)
                        .monospacedDigit()
                    Stepper(
                        "",
                        value: $settings.boardFontSize, in: 11 ... 20, step: 0.5,
                    )
                    .labelsHidden()
                    if appSettings.boardFontSize != 13.5 {
                        Button(l10n["settings.editor.resetFont"]) {
                            appSettings.boardFontSize = 13.5
                        }
                        .font(DesignToken.Typography.caption)
                    }
                }
            }

            Picker(l10n["settings.general.language"], selection: $selectedLocale) {
                Text(l10n["settings.language.system"]).tag("system")
                ForEach(L10n.availableLocales, id: \.code) { locale in
                    Text(locale.displayName).tag(locale.code)
                }
            }
            .onChange(of: selectedLocale) { _, newValue in
                L10n.shared.locale = newValue
            }
        }
    }

    private var fontDescription: String {
        guard let postscript = appSettings.editorFontName,
              let f = NSFont(name: postscript, size: 13)
        else {
            return l10n["settings.editor.systemFont"]
        }
        let name = f.familyName ?? f.fontName
        return name.hasPrefix(".") ? l10n["settings.editor.systemFont"] : name
    }

    /// Accent-only theme cards — activation tap, duplicate/edit affordances.
    private var themeGrid: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            HStack {
                Text(l10n["themes.edit"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.muted)
                Spacer()
                Button {
                    let copy = engine.addCopy(of: engine.activeTheme)
                    editingTheme = copy
                    isNewTheme = true
                } label: {
                    Label(l10n["themes.new"], systemImage: "plus")
                        .font(DesignToken.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignToken.accent)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88, maximum: 120), spacing: DesignToken.Space.xs)],
                spacing: DesignToken.Space.xs,
            ) {
                ForEach(engine.allThemes) { theme in
                    ThemeCard(
                        theme: theme,
                        isActive: engine.activeTheme.id == theme.id,
                        onActivate: { engine.activate(theme) },
                        onEdit: {
                            editingTheme = theme
                            isNewTheme = false
                        },
                    )
                }
            }
        }
        .padding(.vertical, DesignToken.Space.xs)
    }

    // MARK: - Layout

    private func layoutSection(@Bindable settings: AppSettings) -> some View {
        SettingsSection(title: l10n["settings.section.layout"], icon: "square.grid.2x2") {
            Picker(l10n["settings.boardLayout"], selection: $settings.boardLayout) {
                ForEach(AppSettings.BoardLayout.allCases, id: \.self) { layout in
                    Text(layout.displayName(l10n)).tag(layout)
                }
            }

            Picker(l10n["sort.help"], selection: $settings.sortBy) {
                ForEach(AppSettings.SortBy.allCases, id: \.self) { sort in
                    Text(sort.displayName(l10n)).tag(sort)
                }
            }

            Picker(l10n["sort.help"], selection: $settings.sortAscending) {
                Text(l10n["sort.descending"]).tag(false)
                Text(l10n["sort.ascending"]).tag(true)
            }

            Divider()

            Text(l10n["settings.tags.section"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.muted)
            ForEach(TagColor.allCases, id: \.self) { tag in
                HStack(spacing: DesignToken.Space.sm) {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 11, height: 11)
                    TextField(
                        tag.defaultLabel,
                        text: Binding(
                            get: { appSettings.tagLabels[tag] ?? tag.defaultLabel },
                            set: { newValue in
                                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                if trimmed.isEmpty || trimmed == tag.defaultLabel {
                                    appSettings.tagLabels[tag] = nil
                                } else {
                                    appSettings.tagLabels[tag] = trimmed
                                }
                            },
                        ),
                    )
                    .textFieldStyle(.plain)
                    .font(DesignToken.Typography.callout)
                }
            }
        }
    }

    // MARK: - Behavior

    private var behaviorSection: some View {
        SettingsSection(title: l10n["settings.tab.behavior"], icon: "macwindow.on.rectangle") {
            Picker(l10n["settings.animation.style"], selection: $animationStyle) {
                Text(l10n["settings.animation.slide"]).tag(AnimationStyle.slide)
                Text(l10n["settings.animation.fade"]).tag(AnimationStyle.fade)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: animationStyle) { _, v in
                PanelSettings.shared.animationStyle = v
            }

            Picker(l10n["settings.general.edge"], selection: $edgeSide) {
                Text(l10n["settings.general.left"]).tag(EdgeSide.left)
                Text(l10n["settings.general.right"]).tag(EdgeSide.right)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: edgeSide) { _, v in
                PanelSettings.shared.edgeSide = v
            }

            Toggle(l10n["settings.general.enableEdgeActivation"], isOn: $edgeActivationEnabled)
                .onChange(of: edgeActivationEnabled) { _, v in
                    PanelSettings.shared.edgeActivationEnabled = v
                }

            if edgeActivationEnabled {
                sliderRow(l10n["settings.general.activationDelay"], value: $activationDelay, range: 0 ... 1, format: "%.1fs") {
                    PanelSettings.shared.activationDelay = $0
                }
                Toggle(l10n["settings.general.excludeCorners"], isOn: $excludeCorners)
                    .onChange(of: excludeCorners) { _, v in
                        PanelSettings.shared.excludeCorners = v
                    }
            }

            Picker(l10n["settings.dismissal.mode"], selection: $dismissalMode) {
                Text(l10n["settings.dismissal.auto"]).tag(DismissalMode.auto)
                Text(l10n["settings.dismissal.toggle"]).tag(DismissalMode.toggle)
            }
            .onChange(of: dismissalMode) { _, v in
                PanelSettings.shared.dismissalMode = v
            }

            if dismissalMode == .auto {
                Toggle(l10n["settings.general.autoHideOnExit"], isOn: $autoHideOnMouseExit)
                    .onChange(of: autoHideOnMouseExit) { _, v in
                        PanelSettings.shared.autoHideOnMouseExit = v
                    }
                if autoHideOnMouseExit {
                    sliderRow(l10n["settings.general.hideDelay"], value: $hideDelay, range: 0 ... 3, format: "%.1fs") {
                        PanelSettings.shared.hideDelay = $0
                    }
                }
                Toggle(l10n["settings.general.hideOnClickOutside"], isOn: $hideOnClickOutside)
                    .onChange(of: hideOnClickOutside) { _, v in
                        PanelSettings.shared.hideOnClickOutside = v
                    }
            } else {
                Text(l10n["settings.dismissal.toggleHint"])
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.mutedSoft)
                sliderRow(l10n["settings.dismissal.toggleDelay"], value: $toggleDismissDelay, range: 0.05 ... 2.0, format: "%.2fs") {
                    PanelSettings.shared.toggleDismissDelay = $0
                }
            }

            Divider()

            Toggle(l10n["settings.gesture.enableSwipe"], isOn: $swipeToNavigateEnabled)
                .onChange(of: swipeToNavigateEnabled) { _, v in
                    PanelSettings.shared.swipeToNavigateEnabled = v
                }
            Toggle(l10n["settings.gesture.enableEditorSwipe"], isOn: $editorSwipeToNavigateEnabled)
                .onChange(of: editorSwipeToNavigateEnabled) { _, v in
                    PanelSettings.shared.editorSwipeToNavigateEnabled = v
                }
            if swipeToNavigateEnabled || editorSwipeToNavigateEnabled {
                sliderRow(l10n["settings.gesture.sensitivity"], value: $swipeGestureSensitivity, range: 0 ... 1, format: "%.0f%%", percent: true) {
                    PanelSettings.shared.swipeGestureSensitivity = $0
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: dismissalMode)
        .animation(.easeInOut(duration: 0.2), value: edgeActivationEnabled)
        .animation(.easeInOut(duration: 0.2), value: autoHideOnMouseExit)
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        SettingsSection(title: l10n["settings.tab.keyboard"], icon: "keyboard") {
            Text(l10n["settings.keyboard.globalDescription"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)

            shortcutRow(
                l10n["settings.keyboard.togglePanel"],
                shortcut: $toggleShortcut,
                defaultValue: ShortcutSettings.defaultTogglePanel,
                ownKey: "settings.keyboard.togglePanel",
                apply: { ShortcutSettings.shared.togglePanelShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.newNote"],
                shortcut: $newNoteShortcut,
                defaultValue: ShortcutSettings.defaultNewNote,
                ownKey: "settings.keyboard.newNote",
                apply: { ShortcutSettings.shared.newNoteShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.newFolder"],
                shortcut: $newFolderShortcut,
                defaultValue: ShortcutSettings.defaultNewFolder,
                ownKey: "settings.keyboard.newFolder",
                apply: { ShortcutSettings.shared.newFolderShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.search"],
                shortcut: $searchShortcut,
                defaultValue: ShortcutSettings.defaultSearch,
                ownKey: "settings.keyboard.search",
                apply: { ShortcutSettings.shared.searchShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.pinPanel"],
                shortcut: $pinShortcut,
                defaultValue: ShortcutSettings.defaultPin,
                ownKey: "settings.keyboard.pinPanel",
                apply: { ShortcutSettings.shared.pinShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.previousNote"],
                shortcut: $previousNoteShortcut,
                defaultValue: ShortcutSettings.defaultPreviousNote,
                ownKey: "settings.keyboard.previousNote",
                apply: { ShortcutSettings.shared.previousNoteShortcut = $0 },
            )
            shortcutRow(
                l10n["settings.keyboard.nextNote"],
                shortcut: $nextNoteShortcut,
                defaultValue: ShortcutSettings.defaultNextNote,
                ownKey: "settings.keyboard.nextNote",
                apply: { ShortcutSettings.shared.nextNoteShortcut = $0 },
            )

            Divider()

            staticShortcutRow("Esc", l10n["settings.keyboard.hidePanel"])
            staticShortcutRow("⌘Z", l10n["settings.keyboard.undo"])
            staticShortcutRow("⇧⌘Z", l10n["settings.keyboard.redo"])
            staticShortcutRow("⌘B", l10n["settings.keyboard.bold"])
            staticShortcutRow("⌘I", l10n["settings.keyboard.italic"])
            staticShortcutRow("⌘E", l10n["settings.keyboard.inlineCode"])
            staticShortcutRow("⌘K", l10n["settings.keyboard.link"])
            staticShortcutRow("⇧⌘X", l10n["settings.keyboard.strikethrough"])
            staticShortcutRow("/", l10n["settings.keyboard.slashCommand"])
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        @Bindable var settings = appSettings
        return SettingsSection(
            title: l10n["settings.general.storage"],
            icon: "folder",
            trailing: {
                Button {
                    addLocation()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignToken.accent)
                }
                .buttonStyle(.plain)
                .help(l10n["settings.general.addLocation"])
            },
        ) {
            Picker(l10n["settings.storage.imageLocation"], selection: $settings.imageStorageMode) {
                ForEach(AppSettings.ImageStorageMode.allCases, id: \.self) { mode in
                    Text(mode.displayName(l10n)).tag(mode)
                }
            }
            Text(l10n["settings.storage.images.hint"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)

            Divider()

            ForEach(roots) { root in
                storageRootRow(root)
            }

            Toggle(l10n["settings.general.askOnLaunch"], isOn: $askOnLaunch)
                .disabled(roots.count < 2)
                .onChange(of: askOnLaunch) { _, v in
                    StorageSettings.shared.askOnLaunch = v
                }
            Text(l10n["settings.general.askOnLaunchHint"])
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.mutedSoft)
        }
    }

    @ViewBuilder
    private func storageRootRow(_ root: StorageRoot) -> some View {
        let isActive = activeRootID == root.id
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DesignToken.Space.xs) {
                Button {
                    AppDelegate.shared?.switchRoot(to: root, temporary: false)
                } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? DesignToken.accent : DesignToken.mutedSoft)
                }
                .buttonStyle(.plain)
                .disabled(isActive)
                .help(isActive ? "" : l10n["settings.general.setAsDefault"])

                TextField(
                    l10n["common.rename"],
                    text: labelBinding(forID: root.id),
                )
                .textFieldStyle(.plain)
                .font(DesignToken.Typography.callout)

                Spacer()

                Button {
                    NSWorkspace.shared.open(root.url)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignToken.muted)
                }
                .buttonStyle(.plain)
                .help(l10n["settings.general.showInFinder"])

                Button {
                    NSApp.sendAction(#selector(AppDelegate.changeNotesFolder), to: nil, from: nil)
                } label: {
                    Image(systemName: "arrow.right.arrow.left")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignToken.muted)
                }
                .buttonStyle(.plain)
                .help(l10n["settings.general.changeFolder"])

                Button {
                    removeRoot(root)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignToken.error)
                }
                .buttonStyle(.plain)
                .help(l10n["settings.general.removeLocation"])
            }
            Text(root.url.path(percentEncoded: false))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(DesignToken.mutedSoft)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.leading, 22)
        }
        .padding(.vertical, 3)
    }

    private func labelBinding(forID id: String) -> Binding<String> {
        Binding(
            get: {
                if let r = StorageSettings.shared.storageRoots.first(where: { $0.id == id }) {
                    return r.label ?? r.url.lastPathComponent
                }
                return ""
            },
            set: { newVal in
                var current = StorageSettings.shared.storageRoots
                if let idx = current.firstIndex(where: { $0.id == id }) {
                    current[idx].label = newVal.isEmpty ? nil : newVal
                }
                StorageSettings.shared.storageRoots = current
                roots = current
            },
        )
    }

    private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n["settings.general.addLocationMessage"]
        panel.prompt = l10n["common.select"]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var current = StorageSettings.shared.storageRoots
            guard !current.contains(where: { $0.url == url }) else { return }
            do {
                try FileStorage.ensureRootStructure(at: url)
            } catch {
                removalBlockedMessage = error.localizedDescription
                return
            }
            current.append(StorageRoot(id: UUID().uuidString, url: url, label: nil))
            StorageSettings.shared.storageRoots = current
            roots = current
        }
    }

    private func removeRoot(_ root: StorageRoot) {
        var current = StorageSettings.shared.storageRoots
        guard current.count > 1 else {
            removalBlockedMessage = l10n["settings.general.cantRemoveLast"]
            return
        }
        let wasActive = StorageSettings.shared.activeRootID == root.id
            || StorageSettings.shared.sessionRootOverride?.id == root.id
        current.removeAll { $0.id == root.id }
        StorageSettings.shared.storageRoots = current
        roots = current
        if wasActive, let next = current.first {
            AppDelegate.shared?.switchRoot(to: next, temporary: false)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        @Bindable var settings = appSettings
        return SettingsSection(title: l10n["settings.tab.about"], icon: "info.circle") {
            HStack(spacing: DesignToken.Space.md) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n["app.name"])
                        .font(DesignToken.Typography.body.weight(.semibold))
                        .foregroundStyle(DesignToken.bodyStrong)
                    Text(l10n.t("settings.about.version", appVersion, buildNumber))
                        .font(DesignToken.Typography.caption)
                        .foregroundStyle(DesignToken.mutedSoft)
                }
                Spacer()
                Button(l10n["menu.checkUpdates"]) {
                    Task { await AppDelegate.shared?.performUpdateCheck(source: .manual) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Toggle(l10n["settings.general.autoCheckUpdates"], isOn: $settings.autoCheckUpdates)
            Toggle(l10n["settings.general.launchAtLogin"], isOn: $settings.launchAtLogin)

            Toggle(l10n["settings.about.debugLogging"], isOn: $settings.debugLoggingEnabled)
            if settings.debugLoggingEnabled {
                HStack {
                    Text(l10n["settings.about.debugLogging.hint"])
                        .font(DesignToken.Typography.caption)
                        .foregroundStyle(DesignToken.mutedSoft)
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(FileLog.logDirectory)
                    } label: {
                        Label(l10n["settings.about.debugLogging.openFolder"], systemImage: "folder")
                    }
                    .controlSize(.small)
                }
            }

            Link(destination: URL(string: "https://github.com/zcyisiee/Tearoff")!) {
                Label(l10n["settings.about.viewOnGitHub"], systemImage: "arrow.up.right.square")
                    .font(DesignToken.Typography.callout)
            }
            Link(destination: URL(string: "https://github.com/zcyisiee/Tearoff/issues/new?template=bug_report.md")!) {
                Label(l10n["settings.about.reportBug"], systemImage: "ladybug")
                    .font(DesignToken.Typography.callout)
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    // MARK: - Row helpers

    private func row(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(DesignToken.Typography.callout)
                .foregroundStyle(DesignToken.bodyText)
            Spacer()
            control()
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        percent: Bool = false,
        apply: @escaping (Double) -> Void,
    ) -> some View {
        HStack {
            Text(label)
                .font(DesignToken.Typography.callout)
                .foregroundStyle(DesignToken.bodyText)
            Slider(value: value, in: range, step: percent ? 0.1 : 0.05)
                .onChange(of: value.wrappedValue) { _, v in apply(v) }
            Text(String(format: format, value.wrappedValue * (percent ? 100 : 1)))
                .monospacedDigit()
                .foregroundStyle(DesignToken.muted)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func shortcutRow(
        _ label: String,
        shortcut: Binding<KeyboardShortcut?>,
        defaultValue: KeyboardShortcut,
        ownKey: String,
        apply: @escaping (KeyboardShortcut?) -> Void,
    ) -> some View {
        let conflictKey = shortcut.wrappedValue.flatMap {
            ShortcutSettings.shared.conflictingKey(for: $0, excluding: ownKey)
        }
        return HStack(spacing: DesignToken.Space.xs) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(DesignToken.Typography.callout)
                    .foregroundStyle(DesignToken.bodyText)
                if let conflictKey {
                    Text("⚠ \(l10n["settings.keyboard.conflictsWith"]): \(l10n[conflictKey])")
                        .font(DesignToken.Typography.caption)
                        .foregroundStyle(DesignToken.error)
                }
            }
            Spacer()
            if shortcut.wrappedValue != defaultValue {
                Button(l10n["settings.keyboard.reset"]) {
                    shortcut.wrappedValue = defaultValue
                }
                .buttonStyle(.plain)
                .font(DesignToken.Typography.caption)
                .foregroundStyle(DesignToken.muted)
            }
            ShortcutRecorderView(shortcut: shortcut)
                .frame(width: 120, height: 28)
                .onChange(of: shortcut.wrappedValue) { _, v in apply(v) }
        }
    }

    private func staticShortcutRow(_ keys: String, _ description: String) -> some View {
        HStack {
            Text(description)
                .font(DesignToken.Typography.callout)
                .foregroundStyle(DesignToken.bodyText)
            Spacer()
            Text(keys)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DesignToken.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: DesignToken.Radius.xs).fill(DesignToken.glassInset))
        }
    }
}

// MARK: - SettingsSection

/// A titled group of settings rows rendered as one solid card.
private struct SettingsSection<Trailing: View, Content: View>: View {
    let title: String
    let icon: String
    let trailing: Trailing
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content,
    ) {
        self.title = title
        self.icon = icon
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            HStack {
                Label(title, systemImage: icon)
                    .font(DesignToken.Typography.sectionHeader)
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(DesignToken.muted)
                Spacer()
                trailing
            }
            .padding(.leading, DesignToken.Space.xs)

            VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
                content
            }
            .padding(DesignToken.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                    .fill(DesignToken.solidCard)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignToken.Radius.card)
                    .strokeBorder(DesignToken.hairlineSoft, lineWidth: 1)
            }
        }
    }
}

// MARK: - ThemeCard

/// Accent-swatch card for the theme grid. Tap activates; the corner control
/// duplicates built-ins or renames/deletes customs.
private struct ThemeCard: View {
    @Environment(L10n.self) var l10n
    let theme: TearoffTheme
    let isActive: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            HStack(spacing: DesignToken.Space.xs) {
                // Light + dark accent swatch pair previews the pairing.
                RoundedRectangle(cornerRadius: DesignToken.Radius.xs)
                    .fill(theme.lightAccent)
                    .frame(height: 14)
                RoundedRectangle(cornerRadius: DesignToken.Radius.xs)
                    .fill(theme.darkAccent)
                    .frame(height: 14)
            }
            .overlay {
                RoundedRectangle(cornerRadius: DesignToken.Radius.xs)
                    .strokeBorder(DesignToken.hairlineSoft, lineWidth: 0.5)
            }

            HStack {
                Text(theme.name)
                    .font(DesignToken.Typography.caption)
                    .foregroundStyle(DesignToken.bodyStrong)
                    .lineLimit(1)
                Spacer()
                if isHovered {
                    Button(action: onEdit) {
                        Image(systemName: theme.isBuiltin ? "doc.on.doc" : "pencil")
                            .font(.system(size: 9))
                            .foregroundStyle(DesignToken.mutedSoft)
                    }
                    .buttonStyle(.plain)
                    .help(theme.isBuiltin ? l10n["themes.duplicate"] : l10n["themes.edit"])
                }
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.accent)
                }
            }
        }
        .padding(DesignToken.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                .fill(DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.ghost : 0)),
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                .strokeBorder(isActive ? theme.accent : DesignToken.hairlineSoft, lineWidth: isActive ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .help(theme.name)
    }
}

// MARK: - ThemeEditorSheet

/// Accent-only theme editor (name + light/dark accent). Custom themes only.
private struct ThemeEditorSheet: View {
    @Environment(L10n.self) var l10n
    @Environment(\.dismiss) private var dismiss

    @State var theme: TearoffTheme
    let isNew: Bool
    let onSave: (TearoffTheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.md) {
            Text(isNew ? l10n["themes.new"] : l10n["themes.edit"])
                .font(DesignToken.Typography.heading)

            VStack(alignment: .leading, spacing: DesignToken.Space.sm) {
                TextField(l10n["themes.name"], text: $theme.name)
                    .textFieldStyle(.roundedBorder)

                ColorPicker(l10n["themes.light"], selection: $theme.lightAccent)
                ColorPicker(l10n["themes.dark"], selection: $theme.darkAccent)
            }
            .padding(DesignToken.Space.md)
            .background {
                RoundedRectangle(cornerRadius: DesignToken.Radius.md)
                    .fill(DesignToken.solidCard)
            }

            HStack {
                Spacer()
                Button(l10n["common.cancel"], role: .cancel) { dismiss() }
                Button(l10n["common.save"]) {
                    onSave(theme)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(theme.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(DesignToken.Space.lg)
        .interactiveDismissDisabled()
    }
}
