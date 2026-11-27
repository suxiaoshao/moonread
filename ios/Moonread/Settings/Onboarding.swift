import MoonreadAI
import MoonreadSettings
import MoonreadDesign
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import TipKit

struct UsageGuideView: View {
    @Environment(AIHost.self) private var ai
    var body: some View { SettingsUsageGuide(aiAvailable: ai.availability.isAvailable) }
}

struct ImportNovelTip: Tip {
    var title: Text { Text("从右上角“…”菜单导入 TXT，也可从“文件”App 拖进来") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}
struct ReaderControlsTip: Tip {
    var title: Text { Text("轻点屏幕中间显示工具栏") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}
struct ReaderSelectionTip: Tip {
    var title: Text { Text("长按文字可以标注、写批注、拷贝或问 AI") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

/// Eligibility is device-local; TipKit owns dismissal and presentation history.
@MainActor @Observable final class Onboarding {
    static let shared = Onboarding()
    let imports = ImportNovelTip()
    let controls = ReaderControlsTip()
    let selection = ReaderSelectionTip()
    enum TipTarget: Equatable { case imports, controls, selection }
    private let invalidation: ((TipTarget) -> Void)?
    private var tipsEnabled: Bool
    var enabled: Bool { completed && tipsEnabled }
    static let completionKey = "Moonread.onboarding.completed.v1"
    private(set) var completed: Bool
    var hasCompletedIntroduction: Bool { defaults.bool(forKey: Self.completionKey) }
    enum Destination { case importBook, story(LibraryEntry), library }
    private var destination: Destination?
    private enum Key {
        static let imported = "Moonread.onboarding.imported"
        static let controls = "Moonread.onboarding.controls"
        static let selection = "Moonread.onboarding.selection"
    }
    private let defaults: UserDefaults
    private(set) var imported: Bool
    private(set) var revealedControls: Bool
    private(set) var selectedText: Bool
    init(defaults: UserDefaults = .standard, enabled: Bool? = nil, showIntroduction: Bool? = nil, invalidate: ((TipTarget) -> Void)? = nil) {
        self.invalidation = invalidate
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        self.tipsEnabled = enabled ?? (!args.contains("--disable-tips") && (!args.contains("--ui-testing") || args.contains("--ui-test-tips")))
        let session = args.firstIndex(of: "--ui-test-session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        self.defaults = session.flatMap { UserDefaults(suiteName: "Moonread.Onboarding." + $0) } ?? defaults
        completed = !(showIntroduction ?? (!args.contains("--ui-testing") || args.contains("--ui-test-introduction"))) || self.defaults.bool(forKey: Self.completionKey)
        #else
        self.tipsEnabled = enabled ?? true
        self.defaults = defaults
        completed = !(showIntroduction ?? true) || defaults.bool(forKey: Self.completionKey)
        #endif
        imported = self.defaults.bool(forKey: Key.imported)
        revealedControls = self.defaults.bool(forKey: Key.controls)
        selectedText = self.defaults.bool(forKey: Key.selection)
        guard tipsEnabled, invalidate == nil else { return }
        do {
            var config: [Tips.ConfigurationOption] = [.displayFrequency(.immediate)]
            #if DEBUG
            if let session {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Tips-" + session)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                config.append(.datastoreLocation(.url(url)))
            }
            #endif
            try Tips.configure(config)
        } catch { tipsEnabled = false }
    }
    func completeIntroduction(destination: Destination? = nil, savingChoices: () -> Void) {
        savingChoices()
        self.destination = destination
        completed = true; defaults.set(true, forKey: Self.completionKey)
    }
    func takeDestination() -> Destination? {
        defer { destination = nil }
        return destination
    }
    func didImport() { guard !imported else { return }; imported = true; defaults.set(true, forKey: Key.imported); invalidate(.imports) }
    func didShowControls() { guard !revealedControls else { return }; revealedControls = true; defaults.set(true, forKey: Key.controls); invalidate(.controls) }
    func didSelectText() { guard !selectedText else { return }; selectedText = true; defaults.set(true, forKey: Key.selection); invalidate(.selection) }
    private func invalidate(_ target: TipTarget) {
        guard enabled else { return }
        if let invalidation { invalidation(target); return }
        switch target {
        case .imports: imports.invalidate(reason: .actionPerformed)
        case .controls: controls.invalidate(reason: .actionPerformed)
        case .selection: selection.invalidate(reason: .actionPerformed)
        }
    }

}

/// Own the entire TipKit card so its close control follows the same palette.
struct ThemedTipStyle: TipViewStyle {
    var titleOverride: Text? = nil
    static func close(invalidate: () -> Void) { invalidate() }
    func makeBody(configuration: Configuration) -> some View {
        ThemedTipCard(title: titleOverride ?? configuration.title, message: configuration.message, image: configuration.image) {
            Self.close { configuration.tip.invalidate(reason: .tipClosed) }
        }
    }
}

struct ThemedTipCard: View {
    let title: Text?
    var message: Text? = nil
    var image: Image? = nil
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(alignment: .center, spacing: LayoutTokens.control) {
            image.foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                title.font(.subheadline.weight(.semibold))
                message.font(.subheadline)
            }.foregroundStyle(Color(uiColor: theme.ink)).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                    .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
            }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityLabel("关闭提示")
        }.padding(LayoutTokens.control)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).stroke(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
    }
}

/// Wires the first-run UI to the current scene, account, and authorized bookshelf.
struct FirstRunOnboarding: View {
    @Environment(LibraryModel.self) private var library
    @Environment(CloudStore.self) private var cloud
    @Environment(AIHost.self) private var ai
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        SettingsIntroduction(theme: themes.app, aiAllowed: ai.availability.regionAllowsAI, actions: .init(
            directory: {
                let discovery: IntroductionDirectory.Discovery = switch library.builtinDiscovery {
                case .notRequired: .notRequired
                case .discovering: .discovering
                case .ready: .ready
                case .unavailable: .unavailable
                }
                return IntroductionDirectory(homeReady: library.homeReady, libraryRevision: library.revision,
                    generation: library.discoveryGeneration, snapshotRevision: library.discoveryRevision,
                    discovery: discovery, hasImportedBooks: library.hasUserImportedBooks)
            },
            loadTheme: { if !themes.loaded { await themes.load() } },
            readDirectory: { try await AppDataService.shared.libraryEntries(LibraryLocation(shelfID: "builtin")) },
            acknowledgeDirectory: { library.builtinDirectoryLoaded(generation: $0, snapshotRevision: $1) },
            retryDiscovery: { library.retryCloudDiscovery() },
            deliverTestDiscovery: {
                #if DEBUG
                library.receiveCloudDiscovery(.init(generation: library.discoveryGeneration, revision: 1, gathered: true, items: []))
                #endif
            },
            welcomeStory: { try await library.welcomeStoryForIntroduction() },
            selectLibrary: { library.shell.selectedTab = .library },
            complete: { destination, syncReadingData, enableAI in
                let route: Onboarding.Destination = switch destination {
                case .importBook: .importBook
                case .story(let entry): .story(entry)
                case .library: .library
                }
                Onboarding.shared.completeIntroduction(destination: route) {
                    if let syncReadingData { cloud.saveIntroductionChoice(syncReadingData) }
                    ai.availability.saveIntroductionChoice(enableAI)
                }
            },
            errorMessage: { ReaderMessages.error($0) }
        ))
    }
}
