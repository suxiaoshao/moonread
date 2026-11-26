import MoonreadReader
import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI
import UIKit

@MainActor @Observable
final class ThemeStore {
    private(set) var snapshot: ThemeSnapshot
    private(set) var loaded = false
    // Explicit palette creation/deletion can lock its editor. Ordinary
    // preference writes must never disable or dim the surrounding controls.
    private(set) var saving = false
    var error: String?
    var system: ThemeAppearance = .light
    var highContrast = false
    private let cacheKey: String
    private var pendingPreferences: ThemePreferences?
    private var preferencesTask: Task<Void, Never>?
    private let persistPreferences: @MainActor (ThemePreferences) async throws -> ThemeSnapshot

    convenience init() {
        self.init { preferences in try await AppDataService.shared.saveThemes(preferences) }
    }

    init(persistPreferences: @escaping @MainActor (ThemePreferences) async throws -> ThemeSnapshot) {
        self.persistPreferences = persistPreferences
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let session = args.firstIndex(of: "--ui-test-session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        #else
        let session: String? = nil
        #endif
        cacheKey = "Moonread.appearanceCache.\(session ?? "library")"
        snapshot = UserDefaults.standard.string(forKey: cacheKey).flatMap { try? decodeThemeSnapshot(json: $0) } ?? defaultThemeSnapshot()
        #if DEBUG
        if args.contains("--ui-testing"), let index = args.firstIndex(of: "--ui-test-app-appearance"), args.indices.contains(index + 1) {
            snapshot.preferences.appMode = args[index + 1] == "dark" ? .dark : .light
            // Seed both the first frame and the normal asynchronous preferences load.
            UserDefaults.standard.set(try? encodeThemePreferences(value: snapshot.preferences), forKey: "Moonread.themePreferences")
        }
        #endif
    }

    var resolved: ResolvedThemes {
        // Preferences have already been validated by the core at load/save.
        (try? resolveThemes(value: snapshot, system: system, highContrast: highContrast))
            ?? (try! resolveThemes(value: defaultThemeSnapshot(), system: system, highContrast: highContrast))
    }
    var app: ThemeSurface { ThemeSurface(plan: resolved.app) }
    var reader: ThemeSurface {
        let plan = resolved.reader
        return ThemeSurface(plan: plan, readerTexture: resolved.readerTexture)
    }

    func load() async {
        await preferencesTask?.value
        do { accept(try await AppDataService.shared.themes()); loaded = true }
        catch { self.error = ReaderMessages.error(error) }
    }
    private func accept(_ value: ThemeSnapshot) {
        if snapshot != value { snapshot = value }
        cache(value)
    }
    private func cache(_ value: ThemeSnapshot) {
        if let json = try? encodeThemeSnapshot(value: value) { UserDefaults.standard.set(json, forKey: cacheKey) }
    }
    func update(_ edit: (inout ThemePreferences) -> Void) {
        guard !saving else { return }
        var preferences = snapshot.preferences
        edit(&preferences)
        guard preferences != snapshot.preferences else { return }
        let previous = snapshot
        let motion = UIAccessibility.isReduceMotionEnabled || preferences.reduceMotion
        withAnimation(motion ? nil : MotionTokens.color) { snapshot.preferences = preferences }
        pendingPreferences = preferences
        guard preferencesTask == nil else { return }
        preferencesTask = Task {
            defer { preferencesTask = nil }
            var persisted = previous
            while let next = pendingPreferences {
                pendingPreferences = nil
                do {
                    persisted = try await persistPreferences(next)
                    // A finished older write must not undo a newer selection.
                    if pendingPreferences == nil { accept(persisted) }
                    else { cache(persisted) }
                } catch {
                    if pendingPreferences == nil { accept(persisted) }
                    self.error = ReaderMessages.error(error)
                }
            }
        }
    }
    func paletteDeletionImpact(_ id: String) -> PaletteDeletionImpact { AppDataService.paletteDeletionImpact(id, in: snapshot.preferences) }
    var paletteCreationIssue: PaletteSaveIssue? { AppDataService.paletteSaveIssue(in: snapshot) }
    func flushPreferences() async { await preferencesTask?.value }
    func savePalette(_ palette: ThemePalette, creating: Bool) async throws {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        await flushPreferences()
        _ = try await AppDataService.shared.savePalette(palette, creating: creating)
        accept(try await AppDataService.shared.themes())
    }
    func deletePalette(_ id: String) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        await flushPreferences()
        do { accept(try await AppDataService.shared.deletePalette(id)) }
        catch { self.error = ReaderMessages.error(error) }
    }
}

/// Override only this hosting controller. The parent continues observing true
/// system appearance, even when the App or a reader sheet forces another mode.
