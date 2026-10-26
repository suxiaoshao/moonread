import SwiftUI

struct AppThemePreferencesView: View {
    var showsLanguage = false
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var preferences: ThemePreferences { themes.snapshot.preferences }
    var body: some View {
        Form {
            Section {
                    Picker("明暗模式", selection: Binding(get: { preferences.appMode }, set: { mode in themes.update { $0.appMode = mode } })) {
                        Text("跟随系统").tag(AppAppearanceMode.system)
                        Text("浅色").tag(AppAppearanceMode.light)
                        Text("深色").tag(AppAppearanceMode.dark)
                    }.accessibilityIdentifier("appAppearanceMode")
            }.disabled(themes.saving).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("配色") {
                slot(.light, title: "浅色时")
                slot(.dark, title: "深色时")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                Toggle("减弱动态效果", isOn: Binding(get: { preferences.reduceMotion }, set: { value in themes.update { $0.reduceMotion = value } }))
                    .disabled(themes.saving).accessibilityIdentifier("reduceMotion")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            if showsLanguage {
                Section {
                    Button("语言", systemImage: "globe") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                        .accessibilityIdentifier("languageSettings")
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            Section {
                PalettePreview(theme: themes.app)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .themedPage()
        .navigationTitle("应用外观")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func slot(_ appearance: ThemeAppearance, title: LocalizedStringKey) -> some View {
        NavigationLink(value: LibraryRoute.settingsPalette(appearance)) {
            LabeledContent(title, value: paletteName(appearance))
        }.accessibilityIdentifier("paletteSlot-\(appearance == .light ? "light" : "dark")")
            .accessibilityValue(paletteName(appearance))
    }
    private func paletteName(_ appearance: ThemeAppearance) -> String {
        let id: String
            switch appearance == .light ? preferences.appLight : preferences.appDark {
            case .system: return String(localized: "系统配色")
            case let .palette(value): id = value
            }
        return themes.snapshot.palettes.first { $0.id == id }.map(paletteDisplayName) ?? id
    }
}
