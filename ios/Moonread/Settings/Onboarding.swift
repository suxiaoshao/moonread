import SwiftUI
import TipKit

/// Static help: it never opens a reader or accesses a book's data.
struct UsageGuideView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("开始读", "在书架右上角点“＋”，选择“导入小说”，或从“文件”App 把 TXT 拖进“我的书架”。在书架文件夹里导入时，小说会留在当前文件夹。第一次打开大文件时，月读会边准备边显示正文。")
                section("设置", "在书架、统计等主页面点右上角的齿轮，即可进入设置。阅读、外观、书架与同步都在这里调整。")
                section("翻页和工具栏", "轻点屏幕中间，显示或隐藏阅读工具。分页模式下，点左右两侧或左右滑动翻页；滚动模式下，上下滑动即可。")
                if ai.availability.isAvailable {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝、全文搜索或问 AI。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                } else {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝或全文搜索。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                }
                section("目录、书签和搜索", "显示阅读工具后，可以打开目录和全文搜索；书签与批注在“更多”中。退出阅读时会自动保存位置。")
                section("外观", "在阅读设置里调整字号、行距、段距和配色，上方会预览排版效果。")
                if ai.availability.isAvailable {
                    section("AI 助手", "在设置的“AI 助手”中添加连接并选择模型后，可以针对当前页面或选中的文字提问。只有你主动使用 AI 时，才会发送相应上下文。")
                }
                section("iCloud", "开启系统 iCloud Drive 后，“我的书架”的小说文件由 iCloud Drive 同步。阅读进度、书签和批注由设置中的“阅读数据 iCloud 同步”控制；更换账户时可能需要确认。")
            }.padding().frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle("月读使用指南").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("usageGuide")
    }
    private func section(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(Color(uiColor: theme.ink)).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(text).font(.body).foregroundStyle(Color(uiColor: theme.ink)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(LayoutTokens.content)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).stroke(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
    }
}

struct ImportNovelTip: Tip {
    var title: Text { Text("点右上角“＋”导入 TXT，也可从“文件”App 拖进来") }
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
    private var tipsEnabled: Bool
    var enabled: Bool { completed && tipsEnabled }
    static let completionKey = "Moonread.onboarding.completed.v1"
    private(set) var completed: Bool
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
    init(defaults: UserDefaults = .standard, enabled: Bool? = nil, showIntroduction: Bool? = nil) {
        let args = ProcessInfo.processInfo.arguments
        self.tipsEnabled = enabled ?? (!args.contains("--disable-tips") && (!args.contains("--ui-testing") || args.contains("--ui-test-tips")))
        let session = args.firstIndex(of: "--ui-test-session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        self.defaults = session.flatMap { UserDefaults(suiteName: "Moonread.Onboarding." + $0) } ?? defaults
        completed = !(showIntroduction ?? (!args.contains("--ui-testing") || args.contains("--ui-test-introduction"))) || self.defaults.bool(forKey: Self.completionKey)
        imported = self.defaults.bool(forKey: Key.imported)
        revealedControls = self.defaults.bool(forKey: Key.controls)
        selectedText = self.defaults.bool(forKey: Key.selection)
        guard tipsEnabled else { return }
        do {
            var config: [Tips.ConfigurationOption] = [.displayFrequency(.immediate)]
            if let session {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Tips-" + session)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                config.append(.datastoreLocation(.url(url)))
            }
            try Tips.configure(config)
        } catch { tipsEnabled = false }
    }
    func completeIntroduction(destination: Destination? = nil, savingChoices: () async -> Void) async {
        await savingChoices()
        self.destination = destination
        completed = true; defaults.set(true, forKey: Self.completionKey)
    }
    func takeDestination() -> Destination? {
        defer { destination = nil }
        return destination
    }
    func didImport() { guard !imported else { return }; imported = true; defaults.set(true, forKey: Key.imported); if enabled { imports.invalidate(reason: .actionPerformed) } }
    func didShowControls() { guard !revealedControls else { return }; revealedControls = true; defaults.set(true, forKey: Key.controls); if enabled { controls.invalidate(reason: .actionPerformed) } }
    func didSelectText() { guard !selectedText else { return }; selectedText = true; defaults.set(true, forKey: Key.selection); if enabled { selection.invalidate(reason: .actionPerformed) } }
}

/// Own the entire TipKit card so its close control follows the same palette.
struct ThemedTipStyle: TipViewStyle {
    var titleOverride: Text? = nil
    func makeBody(configuration: Configuration) -> some View {
        ThemedTipCard(title: titleOverride ?? configuration.title, message: configuration.message, image: configuration.image) {
            configuration.tip.invalidate(reason: .tipClosed)
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

/// First-run configuration only. File discovery and both cloud transports remain
/// owned by their existing services, including account-change confirmation.
struct FirstRunOnboarding: View {
    @Environment(LibraryModel.self) private var library
    @Environment(CloudStore.self) private var cloud
    @Environment(AIService.self) private var ai
    @Environment(ThemeStore.self) private var themes
    private var theme: ThemeSurface { themes.app }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var syncReadingData = true
    @State private var enableAI = false
    @State private var contents: [LibraryEntry]?
    @State private var contentsKey: String?
    @State private var working = false
    @State private var error: String?
    @State private var showDiscoveryWait = false
    private var hasCloudAccount: Bool { library.builtinDiscovery != .notRequired }
    private var directoryKey: String { "\(library.homeReady)-\(library.revision)-\(library.discoveryGeneration)-\(library.discoveryRevision)" }
    private var directoryLoaded: Bool { library.homeReady && contentsKey == directoryKey && contents != nil }
    private var canFinishWithLibrary: Bool {
        directoryLoaded && (hasBooks || library.builtinDiscovery == .ready || library.builtinDiscovery == .notRequired)
    }
    private var hasBooks: Bool { library.hasUserImportedBooks || (contents?.contains(where: \.directory) ?? false) }
    private var title: LocalizedStringKey {
        switch page {
        case 0: "月读"
        case 1: "书和进度存在哪里"
        case 2: "AI 助手（可选）"
        default: "开始阅读"
        }
    }
    private var symbol: String {
        switch page { case 1: hasCloudAccount ? "icloud" : "iphone"; case 2: "sparkles"; default: "book.closed" }
    }
    private var waitingForDiscovery: Bool { page == 3 && !canFinishWithLibrary && library.builtinDiscovery != .unavailable && error == nil }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if page == 0 {
                            Image("LaunchSeal").resizable().scaledToFit().frame(width: 100, height: 100).accessibilityHidden(true)
                        } else {
                            Image(systemName: symbol).resizable().scaledToFit().frame(width: 100, height: 100, alignment: .topLeading).foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
                        }
                        Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader).accessibilityIdentifier("introductionTitle")
                        pageContent
                        if scrollsProgress { progress }
                    }
                    .foregroundStyle(Color(uiColor: theme.ink))
                    .padding(.horizontal, 24)
                    .padding(.top, dynamicTypeSize.isAccessibilitySize ? 24 : 64)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
                }
                .scrollPosition($scrollPosition)
                actions
            }
            .onChange(of: page) { _, _ in scrollPosition.scrollTo(edge: .top) }
            .themedPage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar {
                if page > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") { page -= 1 }.accessibilityIdentifier("introductionBack").disabled(working)
                    }
                }
            }
            .task { if !themes.loaded { await themes.load() } }
            .task(id: directoryKey) { await loadDirectory() }
            .task(id: waitingForDiscovery) {
                showDiscoveryWait = false
                guard waitingForDiscovery else { return }
                do {
                    try await Task.sleep(for: .seconds(1))
                    try Task.checkCancellation()
                    showDiscoveryWait = true
                } catch { }
            }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }
        .themeScope(theme)
        .preferredColorScheme(theme.scheme)
    }
    @ViewBuilder private var pageContent: some View {
        switch page {
        case 0:
            Text("安静阅读你的 TXT 小说。没有广告，不需要账号。")
        case 1:
            if hasCloudAccount {
                Text("你的书保存在 iCloud 云盘的“月读”文件夹，在你的设备间同步。")
                Toggle("同步阅读进度、书签和批注", isOn: $syncReadingData)
                    .accessibilityIdentifier("introductionReadingSync")
            } else {
                Text("书保存在本机。登录 iCloud 后会自动同步书架，并可在设置中开启阅读数据同步。")
            }
        case 2:
            Text("可以连接你自己选择的 AI 服务，讨论书中内容。第一次发送前会征得你同意。")
            Toggle("启用 AI 功能", isOn: $enableAI).accessibilityIdentifier("introductionAI")
            Text("以后可在设置中更改。").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
        default:
            Text("导入自己的 TXT，或先读一篇原创示例故事。")
                .accessibilityIdentifier("introductionReadingExplanation")
            if !canFinishWithLibrary {
                if library.builtinDiscovery == .unavailable || error != nil {
                    Text("暂未完成书架发现，可先导入小说或重试。").foregroundStyle(Color(uiColor: theme.secondary))
                    Button("重试") { library.retryCloudDiscovery() }
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud"),
                   !ProcessInfo.processInfo.arguments.contains("--ui-test-introduction-screenshots") {
                    Button("交付云端测试快照") { library.receiveCloudDiscovery(.init(generation: library.discoveryGeneration, revision: 1, gathered: true, items: [])) }
                        .accessibilityIdentifier("introductionDeliverCloud")
                }
                #endif
            }
        }
    }
    private var scrollsProgress: Bool { dynamicTypeSize.isAccessibilitySize && page == 3 }
    private var progress: some View {
        VStack(spacing: 16) {
            if waitingForDiscovery && showDiscoveryWait {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Color(uiColor: theme.secondary))
                    Text("正在发现书架").font(.footnote)
                }
                .foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("introductionDiscoveryWait")
            }
            HStack(spacing: 8) {
                ForEach(0..<4) { step in
                    Circle().fill(Color(uiColor: step == page ? theme.accent : theme.secondary).opacity(step == page ? 1 : 0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("第 \(page + 1) 步，共 4 步"))
            .accessibilityIdentifier("introductionProgress")
        }
    }
    private var actions: some View {
        VStack(spacing: 16) {
            if !scrollsProgress { progress }
            if page < 3 {
                Button(action: next) { Text(page == 0 ? "开始" : "onboarding.continue").frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true) }
                    .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("introductionContinue")
            } else {
                Button { Task { await finishImport() } } label: {
                    Text("导入第一本书").frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("introductionImport")
                Button { Task { await finishSample() } } label: {
                    Text(hasBooks ? "打开书架" : "先读示例故事").frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(ThemedSecondaryButtonStyle()).controlSize(.large).disabled(!canFinishWithLibrary)
                    .accessibilityIdentifier("introductionSample")
            }
        }.fixedSize(horizontal: false, vertical: true).disabled(working).tint(Color(uiColor: theme.accent))
            .padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            .background(Color(uiColor: theme.canvas))
    }
    private func next() { page += 1 }
    private func complete(destination: Onboarding.Destination) async {
        await Onboarding.shared.completeIntroduction(destination: destination) {
            if hasCloudAccount { await cloud.setEnabledAndWait(syncReadingData) }
            ai.availability.setEnabled(enableAI)
        }
    }
    private func finishImport() async {
        guard !working else { return }
        working = true; defer { working = false }
        await complete(destination: .importBook)
        library.selectedTab = .library
    }
    private func finishSample() async {
        guard canFinishWithLibrary, !working else { return }
        working = true; defer { working = false }
        do {
            let entry = hasBooks ? nil : try await library.welcomeStoryForIntroduction()
            library.selectedTab = .library
            await complete(destination: entry.map { .story($0) } ?? .library)
        } catch { self.error = ReaderMessages.error(error) }
    }
    private func loadDirectory() async {
        guard library.homeReady else { return }
        // A revision may advance while a directory read is suspended.
        // Keep reading until a current snapshot can be acknowledged.
        while !Task.isCancelled {
            let key = directoryKey, generation = library.discoveryGeneration, revision = library.discoveryRevision
            do {
                let entries = try await ReaderService.shared.libraryEntries(LibraryLocation(shelfID: "builtin"))
                try Task.checkCancellation()
                guard key == directoryKey else { continue }
                contents = entries; contentsKey = key
                library.builtinDirectoryLoaded(generation: generation, snapshotRevision: revision)
                return
            } catch is CancellationError { return }
            catch { self.error = ReaderMessages.error(error); return }
        }
    }
}
