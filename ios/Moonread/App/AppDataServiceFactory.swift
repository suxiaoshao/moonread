import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

enum AppDataServiceFactory {
    static func make() -> AppDataService {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-store-screenshots"), arguments.contains("--ui-testing"),
           let i = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(i + 1),
           let session = UUID(uuidString: arguments[i + 1])?.uuidString {
            let suite = "Moonread.StoreShots." + session
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-StoreShots-" + session, isDirectory: true)
            guard let capture = StoreShotCapture.requested else { preconditionFailure("Missing screenshot capture configuration") }
            UserDefaults(suiteName: "Moonread.AI.UITest-" + session)!.set(StoreShotScene.requested == .recap, forKey: "Moonread.ai.enabled.v1")
            UserDefaults.standard.set(ReadingSettingsTab.typography.rawValue, forKey: "readingSettingsTab")
            var snapshot = defaultThemeSnapshot()
            let dark = capture.appearance == "dark"
            snapshot.preferences.appMode = dark ? .dark : .light
            if dark { snapshot.preferences.appDark = .palette(id: capture.appPalette) }
            else { snapshot.preferences.appLight = .palette(id: capture.appPalette) }
            guard let reader = snapshot.palettes.first(where: { $0.id == capture.readerPalette }) else { preconditionFailure("Unknown screenshot reader palette") }
            snapshot.preferences.readerMode = reader.appearance == .dark ? .dark : .light
            if reader.appearance == .dark { snapshot.preferences.readerDark = .palette(id: reader.id) }
            else { snapshot.preferences.readerLight = .palette(id: reader.id) }
            do {
                let supported = builtinReaderTextures().contains { $0.paletteId == capture.readerPalette }
                if supported {
                    snapshot.preferences = try setReaderPaletteTexture(preferences: snapshot.preferences, paletteId: capture.readerPalette, enabled: capture.readerTextureEnabled)
                } else { precondition(!capture.readerTextureEnabled, "Unsupported screenshot texture palette") }
                _ = try encodeThemeSnapshot(value: snapshot)
            } catch { preconditionFailure("Invalid screenshot theme configuration: \(error)") }
            UserDefaults(suiteName: suite)!.set(try! encodeThemePreferences(value: snapshot.preferences), forKey: "Moonread.themePreferences")
            UserDefaults.standard.set(try! encodeThemeSnapshot(value: snapshot), forKey: "Moonread.appearanceCache." + session)
            return AppDataService(libraryDirectory: root, sourceDefaultsSuite: suite)
        }
        if arguments.contains("--ui-testing"),
           let index = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(index + 1),
           let session = UUID(uuidString: arguments[index + 1])?.uuidString {
            let defaults = UserDefaults.standard
            let key = "Moonread.uiTest.readingSettingsSession.v1"
            if defaults.string(forKey: key) != session {
                // A new test starts at the product defaults. Relaunches within the
                // same UUID retain changes so persistence remains testable.
                defaults.removeObject(forKey: "Moonread.readerSettings")
                defaults.removeObject(forKey: "readingSettingsTab")
                defaults.set(session, forKey: key)
            }
        }
        if arguments.contains("--ui-test-library-trash"),
           let index = arguments.firstIndex(of: "--ui-test-session"), arguments.indices.contains(index + 1),
           UUID(uuidString: arguments[index + 1]) != nil {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Library-" + arguments[index + 1])
            return AppDataService(libraryDeletion: { url, permanently in
                // Deterministic A-line UI fixture only. Ordinary launches and
                // provider/system-integration checks always use real trashItem.
                guard !permanently, url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                      !url.pathComponents.contains(".Trash") else { throw LibraryFileError.invalidDestination }
                let trash = root.appendingPathComponent(".Trash", isDirectory: true)
                try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            })
        }
        #endif
        #if READER_OPEN_DIAGNOSTICS
        if ReaderOpenDiagnostics.benchmark, let session = ReaderOpenDiagnostics.session {
            let suite = "Moonread.ReaderOpen." + session
            if let settings = UserDefaults.standard.string(forKey: "Moonread.readerSettings") { UserDefaults(suiteName: suite)?.set(settings, forKey: "Moonread.readerSettings") }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-ReaderOpen-" + session, isDirectory: true)
            return AppDataService(libraryDirectory: directory, sourceDefaultsSuite: suite)
        }
        #endif
        return AppDataService(readingCloudEnvironment: CloudConfiguration.readingEnvironment ?? .production)
    }
}
