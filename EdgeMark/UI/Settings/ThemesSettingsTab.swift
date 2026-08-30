import SwiftUI

// MARK: - ThemesSettingsTab

/// Theme management: built-in theme grid, duplicate-to-customize, and a
/// full editor (name, light/dark canvas + accent, material) for custom themes.
struct ThemesSettingsTab: View {
    @Environment(L10n.self) var l10n
    private var engine = ThemeEngine.shared

    @State private var editingTheme: EdgeMarkTheme?
    @State private var isNewTheme = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignToken.Space.md) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: DesignToken.Space.sm)],
                    spacing: DesignToken.Space.sm,
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

                Button {
                    let copy = engine.addCopy(of: engine.activeTheme)
                    editingTheme = copy
                    isNewTheme = true
                } label: {
                    Label(l10n["themes.new"], systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(DesignToken.Space.lg)
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $editingTheme) { theme in
            ThemeEditorSheet(
                theme: theme,
                isNew: isNewTheme,
                onSave: { engine.update($0) },
            )
            .frame(width: 420)
        }
    }
}

// MARK: - ThemeCard

private struct ThemeCard: View {
    @Environment(L10n.self) var l10n
    let theme: EdgeMarkTheme
    let isActive: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.xs) {
            // Mini panel preview: canvas + accent dot.
            ZStack {
                RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                    .fill(theme.canvas)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(0 ..< 3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(DesignToken.ink.opacity(0.25))
                                .frame(width: 26, height: 3)
                        }
                    }
                    Spacer()
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 10, height: 10)
                }
                .padding(DesignToken.Space.xs + 2)
            }
            .frame(height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                    .strokeBorder(isActive ? theme.accent : DesignToken.hairlineSoft, lineWidth: isActive ? 2 : 1)
            }

            HStack {
                Text(theme.name)
                    .font(DesignToken.Typography.callout)
                    .foregroundStyle(DesignToken.bodyStrong)
                    .lineLimit(1)
                Spacer()
                if theme.isBuiltin {
                    Button(action: onEdit) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignToken.mutedSoft)
                    }
                    .buttonStyle(.plain)
                    .help(l10n["themes.duplicate"])
                } else {
                    Menu {
                        Button(l10n["common.rename"]) { onEdit() }
                        Button(l10n["common.delete"], role: .destructive) {
                            ThemeEngine.shared.remove(theme)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignToken.mutedSoft)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(DesignToken.Space.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignToken.Radius.sm)
                .fill(DesignToken.ink.opacity(isHovered ? DesignToken.Alpha.ghost : 0)),
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovered = $0 }
        .help(theme.name)
    }
}

// MARK: - ThemeEditorSheet

private struct ThemeEditorSheet: View {
    @Environment(L10n.self) var l10n
    @Environment(\.dismiss) private var dismiss

    @State var theme: EdgeMarkTheme
    let isNew: Bool
    let onSave: (EdgeMarkTheme) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Space.md) {
            Text(isNew ? l10n["themes.new"] : l10n["themes.edit"])
                .font(DesignToken.Typography.heading)

            Form {
                TextField(l10n["themes.name"], text: $theme.name)

                Section(l10n["themes.canvas"]) {
                    ColorPicker(l10n["themes.light"], selection: $theme.lightCanvas)
                    ColorPicker(l10n["themes.dark"], selection: $theme.darkCanvas)
                }

                Section(l10n["themes.accent"]) {
                    ColorPicker(l10n["themes.light"], selection: $theme.lightAccent)
                    ColorPicker(l10n["themes.dark"], selection: $theme.darkAccent)
                }

                Picker(l10n["themes.material"], selection: $theme.material) {
                    ForEach(ThemeMaterial.allCases, id: \.self) { material in
                        Text(material == .translucent ? l10n["themes.material.translucent"] : l10n["themes.material.opaque"])
                            .tag(material)
                    }
                }
            }
            .formStyle(.grouped)

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
