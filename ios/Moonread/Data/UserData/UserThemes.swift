import Foundation

enum PaletteSaveIssue: LocalizedError, Equatable {
    case customLimit, missingTarget
    var errorDescription: String? {
        switch self {
        case .customLimit: String(localized: "最多可保存 64 个自定义配色，请先删除不需要的配色。")
        case .missingTarget: String(localized: "这个配色已被删除，无法保存更改。")
        }
    }
}

struct PaletteDeletionImpact: Equatable {
    let appSlots: Bool
    let readerSlots: Bool
    var message: String? {
        switch (appSlots, readerSlots) {
        case (false, false): nil
        case (true, false): String(localized: "使用此配色的应用槽位将恢复纸色。")
        case (false, true): String(localized: "使用此配色的阅读槽位将恢复跟随应用。")
        case (true, true): String(localized: "使用此配色的应用槽位将恢复纸色，阅读槽位将恢复跟随应用。")
        }
    }
}

extension AppDataService {
    nonisolated static func paletteDeletionImpact(_ id: String, in preferences: ThemePreferences) -> PaletteDeletionImpact {
        let app = [preferences.appLight, preferences.appDark].contains { source in
            if case let .palette(value) = source { return value == id }; return false
        }
        let reader = [preferences.readerLight, preferences.readerDark].contains { source in
            if case let .palette(value) = source { return value == id }; return false
        }
        return .init(appSlots: app, readerSlots: reader)
    }

    nonisolated static func paletteSaveIssue(in snapshot: ThemeSnapshot, editing value: ThemePalette? = nil) -> PaletteSaveIssue? {
        if let value {
            return snapshot.palettes.contains { $0.custom && $0.id == value.id && $0.appearance == value.appearance } ? nil : .missingTarget
        }
        return snapshot.palettes.filter(\.custom).count < 64 ? nil : .customLimit
    }
    func themes() async throws -> ThemeSnapshot {
        var snapshot = defaultThemeSnapshot()
        if let stored = sourceDefaults.object(forKey: "Moonread.themePreferences") {
            guard let json = stored as? String else { throw ReaderError.InvalidSettings }
            snapshot.preferences = try decodeThemePreferences(json: json)
        }
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
        if let issue = Self.paletteSaveIssue(in: snapshot, editing: creating ? nil : value) { throw issue }
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
