import Foundation

extension AppDataService {
    func themes() async throws -> ThemeSnapshot {
        var snapshot = defaultThemeSnapshot()
        if let json = sourceDefaults.string(forKey: "Moonread.themePreferences") { snapshot.preferences = try decodeThemePreferences(json: json) }
        let rows = try await userStore().allValues(prefix: "palette/")
        let custom = try rows.values.filter { $0 != "null" }.map { try decodeThemePalette(json: $0) }.filter(\.custom)
        snapshot.palettes = defaultThemeSnapshot().palettes + custom
        // A remotely removed palette falls back to the existing device defaults.
        let defaults = defaultThemeSnapshot().preferences
        let ids = Set(snapshot.palettes.map(\.id))
        if case .palette(let id) = snapshot.preferences.appLight, !ids.contains(id) { snapshot.preferences.appLight = defaults.appLight }
        if case .palette(let id) = snapshot.preferences.appDark, !ids.contains(id) { snapshot.preferences.appDark = defaults.appDark }
        if case .palette(let id) = snapshot.preferences.readerLight, !ids.contains(id) { snapshot.preferences.readerLight = .app }
        if case .palette(let id) = snapshot.preferences.readerDark, !ids.contains(id) { snapshot.preferences.readerDark = .app }
        return snapshot
    }
    func saveThemes(_ value: ThemePreferences) async throws -> ThemeSnapshot {
        var snapshot = try await themes(); snapshot.preferences = value
        _ = try resolveThemes(value: snapshot, system: .light, highContrast: false)
        sourceDefaults.set(try encodeThemePreferences(value: value), forKey: "Moonread.themePreferences")
        dataChanged(); return snapshot
    }
    func savePalette(_ value: ThemePalette, creating: Bool) async throws -> ThemePalette {
        let snapshot = try await themes()
        guard creating ? snapshot.palettes.filter(\.custom).count < 64 : snapshot.palettes.contains(where: { $0.custom && $0.id == value.id && $0.appearance == value.appearance }) else { throw ReaderError.InvalidSettings }
        let palette = try makeThemePalette(id: creating ? "custom-\(UUID().uuidString)" : value.id, name: value.name, appearance: value.appearance, colors: value.colors)
        let json = try encodeThemePalette(value: palette)
        try await userStore().put("palette/\(palette.id)", value: json, device: userDevice)
        dataChanged(); return palette
    }
    func deletePalette(_ id: String) async throws -> ThemeSnapshot {
        guard try await themes().palettes.contains(where: { $0.custom && $0.id == id }) else { throw ReaderError.NotFound }
        try await userStore().put("palette/\(id)", value: "null", device: userDevice)
        dataChanged(); return try await themes()
    }
}
