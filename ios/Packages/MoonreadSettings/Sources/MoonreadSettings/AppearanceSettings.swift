import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI

public struct AppearanceSettings<Route: Hashable>: View {
    @Environment(\.theme) private var theme
    @Binding private var mode: AppAppearanceMode
    @Binding private var reduceMotion: Bool
    let saving: Bool
    let preview: ThemeSurface
    let route: (ThemeAppearance) -> Route
    let paletteName: (ThemeAppearance) -> String

    public init(mode: Binding<AppAppearanceMode>, reduceMotion: Binding<Bool>, saving: Bool,
                preview: ThemeSurface, route: @escaping (ThemeAppearance) -> Route,
                paletteName: @escaping (ThemeAppearance) -> String) {
        _mode = mode
        _reduceMotion = reduceMotion
        self.saving = saving
        self.preview = preview
        self.route = route
        self.paletteName = paletteName
    }

    public var body: some View {
        Form {
            Section {
                    Picker("明暗模式", selection: $mode) {
                        Text("跟随系统").tag(AppAppearanceMode.system)
                        Text("浅色").tag(AppAppearanceMode.light)
                        Text("深色").tag(AppAppearanceMode.dark)
                    }.accessibilityIdentifier("appAppearanceMode")
            }.disabled(saving).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section("配色") {
                slot(.light, title: "浅色时")
                slot(.dark, title: "深色时")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                Toggle("减弱动态效果", isOn: $reduceMotion)
                    .disabled(saving).accessibilityIdentifier("reduceMotion")
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                PalettePreview(theme: preview)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
            }
        }
        .themedPage()
        .navigationTitle("应用外观")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func slot(_ appearance: ThemeAppearance, title: LocalizedStringKey) -> some View {
        NavigationLink(value: route(appearance)) {
            LabeledContent(title, value: paletteName(appearance))
        }.accessibilityIdentifier("paletteSlot-\(appearance == .light ? "light" : "dark")")
            .accessibilityValue(paletteName(appearance))
    }
}
