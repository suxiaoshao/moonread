import MoonreadSettings
import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

struct AppThemePreferencesView: View {
    @Environment(ThemeStore.self) private var themes
    private var preferences: ThemePreferences { themes.snapshot.preferences }
    var body: some View {
        AppearanceSettings(
            mode: Binding(get: { preferences.appMode }, set: { mode in themes.update { $0.appMode = mode } }),
            reduceMotion: Binding(get: { preferences.reduceMotion }, set: { value in themes.update { $0.reduceMotion = value } }),
            saving: themes.saving, preview: themes.app, route: LibraryRoute.settingsPalette, paletteName: paletteName
        )
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
