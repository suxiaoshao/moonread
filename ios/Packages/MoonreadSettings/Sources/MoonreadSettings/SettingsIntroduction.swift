import MoonreadDataTypes
import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

/// First-run configuration only. File discovery and both cloud transports remain
/// owned by their existing services, including account-change confirmation.
public struct SettingsIntroduction: View {
    private let host: IntroductionActions
    private let theme: ThemeSurface
    private let aiAllowed: Bool
    private var directory: IntroductionDirectory { host.directory() }

    public init(theme: ThemeSurface, aiAllowed: Bool, actions: IntroductionActions) {
        self.theme = theme
        self.aiAllowed = aiAllowed
        host = actions
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var syncReadingData = true
    @State private var enableAI = false
    @State private var contents: [LibraryEntry]?
    @State private var contentsKey: String?
    @State private var directoryFailed = false
    @State private var working = false
    @State private var error: String?
    @State private var showDiscoveryWait = false
    private var hasCloudAccount: Bool { directory.discovery != .notRequired }
    private var directoryKey: String { directory.key }
    private var directoryLoaded: Bool { directory.homeReady && contentsKey == directoryKey && contents != nil }
    private var canFinishWithLibrary: Bool {
        directoryFailed || (directoryLoaded && (hasBooks || directory.discovery == .ready || directory.discovery == .notRequired))
    }
    private var hasBooks: Bool { directory.hasImportedBooks || (contents?.contains(where: \.directory) ?? false) }
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
    private var waitingForDiscovery: Bool { page == 3 && !canFinishWithLibrary && directory.discovery != .unavailable && error == nil }
    public var body: some View {
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
            .onChange(of: aiAllowed) { _, allowed in if !allowed && page == 2 { page = 3 } }
            .themedPage()
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbar {
                if page > 0 {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") { page = page == 3 && !aiAllowed ? 1 : page - 1 }.accessibilityIdentifier("introductionBack").disabled(working)
                    }
                }
            }
            .task { await host.loadTheme() }
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
                if directory.discovery == .unavailable || error != nil {
                    Text("暂未完成书架发现，可先导入小说或重试。").foregroundStyle(Color(uiColor: theme.secondary))
                    Button("重试") { host.retryDiscovery() }
                }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud"),
                   !ProcessInfo.processInfo.arguments.contains("--ui-test-introduction-screenshots") {
                    Button("交付云端测试快照") { host.deliverTestDiscovery() }
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
                ForEach((0..<4).filter { aiAllowed || $0 != 2 }, id: \.self) { step in
                    Circle().fill(Color(uiColor: step == page ? theme.accent : theme.secondary).opacity(step == page ? 1 : 0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("第 \(page + 1 - (!aiAllowed && page > 2 ? 1 : 0)) 步，共 \(aiAllowed ? 4 : 3) 步"))
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
                    Text(hasBooks || directoryFailed ? "打开书架" : "先读示例故事").frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(ThemedSecondaryButtonStyle()).controlSize(.large).disabled(!canFinishWithLibrary)
                    .accessibilityIdentifier("introductionSample")
            }
        }.fixedSize(horizontal: false, vertical: true).disabled(working).tint(Color(uiColor: theme.accent))
            .padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            .background(Color(uiColor: theme.canvas))
    }
    private func next() { page += page == 1 && !aiAllowed ? 2 : 1 }
    private func complete(destination: IntroductionDestination) {
        host.complete(destination, hasCloudAccount ? syncReadingData : nil, enableAI)
    }
    private func finishImport() async {
        guard !working else { return }
        working = true; defer { working = false }
        complete(destination: .importBook)
        host.selectLibrary()
    }
    private func finishSample() async {
        guard canFinishWithLibrary, !working else { return }
        working = true; defer { working = false }
        do {
            let entry = hasBooks || directoryFailed ? nil : try await host.welcomeStory()
            host.selectLibrary()
            complete(destination: entry.map { .story($0) } ?? .library)
        } catch { self.error = host.errorMessage(error) }
    }
    private func loadDirectory() async {
        guard directory.homeReady else { return }
        // A revision may advance while a directory read is suspended.
        // Keep reading until a current snapshot can be acknowledged.
        while !Task.isCancelled {
            let snapshot = directory
            let key = snapshot.key
            do {
                let entries = try await host.readDirectory()
                try Task.checkCancellation()
                guard key == directoryKey else { continue }
                contents = entries; contentsKey = key; directoryFailed = false
                host.acknowledgeDirectory(snapshot.generation, snapshot.snapshotRevision)
                return
            } catch is CancellationError { return }
            catch { directoryFailed = true; self.error = host.errorMessage(error); return }
        }
    }
}


public enum IntroductionDestination {
    case importBook, story(LibraryEntry), library
}

public struct IntroductionDirectory {
    public enum Discovery { case notRequired, discovering, ready, unavailable }

    let homeReady: Bool
    let libraryRevision: Int
    let generation: UUID
    let snapshotRevision: Int
    let discovery: Discovery
    let hasImportedBooks: Bool
    var key: String { "\(homeReady)-\(libraryRevision)-\(generation)-\(snapshotRevision)" }

    public init(homeReady: Bool, libraryRevision: Int, generation: UUID, snapshotRevision: Int,
                discovery: Discovery, hasImportedBooks: Bool) {
        self.homeReady = homeReady
        self.libraryRevision = libraryRevision
        self.generation = generation
        self.snapshotRevision = snapshotRevision
        self.discovery = discovery
        self.hasImportedBooks = hasImportedBooks
    }
}

@MainActor public struct IntroductionActions {
    let directory: () -> IntroductionDirectory
    let loadTheme: () async -> Void
    let readDirectory: () async throws -> [LibraryEntry]
    let acknowledgeDirectory: (UUID, Int) -> Void
    let retryDiscovery: () -> Void
    let deliverTestDiscovery: () -> Void
    let welcomeStory: () async throws -> LibraryEntry?
    let selectLibrary: () -> Void
    let complete: (IntroductionDestination, Bool?, Bool) -> Void
    let errorMessage: (any Error) -> String

    public init(
        directory: @escaping () -> IntroductionDirectory, loadTheme: @escaping () async -> Void,
        readDirectory: @escaping () async throws -> [LibraryEntry],
        acknowledgeDirectory: @escaping (UUID, Int) -> Void, retryDiscovery: @escaping () -> Void,
        deliverTestDiscovery: @escaping () -> Void, welcomeStory: @escaping () async throws -> LibraryEntry?,
        selectLibrary: @escaping () -> Void, complete: @escaping (IntroductionDestination, Bool?, Bool) -> Void,
        errorMessage: @escaping (any Error) -> String
    ) {
        self.directory = directory
        self.loadTheme = loadTheme
        self.readDirectory = readDirectory
        self.acknowledgeDirectory = acknowledgeDirectory
        self.retryDiscovery = retryDiscovery
        self.deliverTestDiscovery = deliverTestDiscovery
        self.welcomeStory = welcomeStory
        self.selectLibrary = selectLibrary
        self.complete = complete
        self.errorMessage = errorMessage
    }
}
