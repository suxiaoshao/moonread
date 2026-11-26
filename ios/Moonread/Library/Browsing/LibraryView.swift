import MoonreadDesign
import MoonreadData
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var recentUse: RecentReadingUse?
    @State private var editingHome = false
    @AccessibilityFocusState(for: .voiceOver) private var actionsFocused: Bool
    @Environment(AIHost.self) private var ai
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    private var enabledSections: [LibraryHomeSection] { model.homeSections.visible }
    private var current: LibraryEntry? {
        enabledSections.contains(.resume) ? model.recents.first : nil
    }
    private var following: [LibraryEntry] {
        guard enabledSections.contains(.recent) else { return [] }
        let entries = model.recents.dropFirst(current == nil ? 0 : 1)
        return model.layout == .grid ? Array(entries) : Array(entries.prefix(2))
    }
    private var retrySection: LibraryHomeSection? {
        guard model.recentReading.failure != nil else { return nil }
        return enabledSections.first { $0 == .resume || $0 == .recent }
    }

    private func showsSection(_ section: LibraryHomeSection) -> Bool {
        if section == retrySection { return true }
        switch section {
        case .resume: return current != nil
        case .shelves: return true
        case .saved: return !model.savedFilters.entries.isEmpty
        case .recent: return !following.isEmpty
        }
    }

    var body: some View {
        Group {
            if model.homeReady {
                LibraryHomeLayout(enabledSections: enabledSections, showsSection: showsSection,
                                  editHome: { editingHome = true },
                                  refresh: { await model.refresh(showIndicator: false, userInitiated: true) },
                                  section: homeSection)
            }
            else if let error = model.error {
                ContentUnavailableView { Label("暂时无法加载书架", systemImage: "books.vertical") } description: { Text(error) } actions: { Button("重试") { Task { await model.load() } } }
            } else { ProgressView("正在加载书架").frame(maxWidth: .infinity, maxHeight: .infinity).themedPage() }
        }
        .navigationTitle("书架").navigationBarTitleDisplayMode(.large)
        .background(Color(uiColor: theme.canvas).ignoresSafeArea(.container))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(LibraryLocation(shelfID: "builtin"))) }
                    Button("添加书架", systemImage: "folder.badge.plus") { model.chooseFiles(.folder(nil)) }
                        .accessibilityIdentifier("chooseFolder")
                    if model.homeReady {
                        Divider()
                        Button("编辑首页", systemImage: "pencil") { editingHome = true }
                    }
                } label: {
                    Label("书架操作", systemImage: "ellipsis")
                }
                .menuOrder(.fixed)
                .toolbarGlyph()
                .accessibilityIdentifier("libraryActions")
                .accessibilityFocused($actionsFocused)
                #if DEBUG
                if ReaderSmokeFixture.enabled {
                    Menu("测试接收") {
                        Button("导入TXT") { Task { await model.receiveSmokeTXT(shared: false) } }.accessibilityIdentifier("smokeImportTXT")
                        Button("分享TXT") { Task { await model.receiveSmokeTXT(shared: true) } }.accessibilityIdentifier("smokeShareTXT")
                    }.accessibilityIdentifier("smokeReceive")
                }
                #endif
            }
        }
        .sheet(isPresented: $editingHome, onDismiss: { actionsFocused = true }) {
            LibraryHomeEditor(sections: model.homeSections, detent: homeEditorDetent) { model.homeSections = $0 }
                .themeScope(theme)
        }
        .modifier(LibraryFileActivity(active: model.processingFiles))
        .safeAreaInset(edge: .top, spacing: 0) {
            if !enabledSections.isEmpty, model.showsImportTip, themes.loaded, model.shell.libraryPath.isEmpty, model.shell.selectedTab == .library {
                TipView(Onboarding.shared.imports).tipViewStyle(ThemedTipStyle()).padding(.horizontal)
                    .accessibilityIdentifier("libraryImportTip")
            }
        }
        .task {
            if recentUse == nil { recentUse = model.recentReading.use(limit: RecentReadingStore.homeLimit) }
            await model.load()
        }
        .modifier(PageLoadingOverlay(request: !themes.loaded || model.busy || model.nativeRefreshing ? nil : (!model.homeReady ? model.loading.request : (model.explicitRefresh ? model.refreshing.request : nil)),
                                     hasContent: !model.shelves.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh))
    }
    private var homeEditorDetent: PresentationDetent {
        #if DEBUG
        if let capture = StoreShotCapture.requested,
           capture.scene == StoreShotScene.homeEditor.rawValue, capture.group.hasPrefix("duo-") { return .large }
        #endif
        return .medium
    }

    private func homeSection(_ section: LibraryHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch section {
            case .resume:
                if let current {
                    homeHeader(section.title, showsAll: following.isEmpty)
                    ContinueReadingRow(model: model, entry: current)
                        .contextMenu { recentMenu(current) }
                        .accessibilityActions { recentMenu(current) }
                }
            case .shelves:
                ShelfRecoverySummary(model: model)
                shelves
            case .saved:
                SavedFilterSection(model: model, onHome: true)
            case .recent:
                recentBooks
            }
            if section == retrySection, let error = model.recentReading.failure {
                RecentReadingRetry(message: error) { model.recentReading.retry() }
            }
        }
    }

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 12) {
            homeHeader(LibraryHomeSection.shelves.title, showsAll: false)
            ForEach(model.shelves, id: \.id) { shelf in
                NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: shelf.id))) {
                    HStack {
                        ShelfRow(shelf: shelf)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
                        .contentShape(.rect)
                }.buttonStyle(.plain)
                    .contextMenu { ShelfMenu(model: model, shelf: shelf) }.accessibilityIdentifier("shelf-\(shelf.id)")
                    .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                ShelfIndexGuidance(model: model, shelfID: shelf.id)
            }
        }
    }

    @ViewBuilder private var recentBooks: some View {
        if !following.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                homeHeader(LibraryHomeSection.recent.title, showsAll: true)
                if model.layout == .grid {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: LayoutTokens.content) {
                            ForEach(following, id: \.id) { entry in
                                RecentBookItem(model: model, entry: entry, layout: .grid)
                            }
                        }.scrollTargetLayout()
                    }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                        .accessibilityIdentifier("recentCoverRow")
                } else {
                    ForEach(following, id: \.id) { entry in
                        RecentBookItem(model: model, entry: entry, layout: .list)
                    }
                }
            }
        }
    }

    /// One header style for every home section; 查看全部 opens the full recent list.
    private func homeHeader(_ title: LocalizedStringKey, showsAll: Bool) -> some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(Color(uiColor: theme.ink))
            Spacer()
            if showsAll {
                NavigationLink(value: LibraryRoute.recent) { HStack(spacing: 4) { Text("查看全部"); Image(systemName: "chevron.right") }.font(.subheadline) }
                    .foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("allRecents")
            }
        }
        .textCase(nil).accessibilityElement(children: .contain)
    }

    private func recentMenu(_ entry: LibraryEntry) -> some View {
        RecentBookActions(model: model, entry: entry)
    }
}

/// The book to resume: a larger cover, its chapter and the current reading position.
private struct ContinueReadingRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    @Environment(\.theme) private var theme
    private var position: Double { ReadingProgress.fraction(entry.positionUtf8, of: entry.byteCount) }
    private var progress: String { position.formatted(.percent.precision(.fractionLength(0))) }
    private var lastRead: String? {
        guard entry.lastRead > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(entry.lastRead) / 1000)
        if Date.now.timeIntervalSince(date) < 60 { return String(localized: "刚刚") }
        return date.formatted(.relative(presentation: .named))
    }

    var body: some View {
        let lastRead = lastRead
        Button { model.openRecent(entry) } label: {
            HStack(spacing: 16) {
                BookCoverView(title: entry.title, compact: true, cover: entry.displayMetadata?.cover, contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.displayMetadata?.author).frame(width: 60, height: 84)
                    .overlay { LibraryFileAvailability(entry: entry, compact: true) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: entry.title).font(.title3.weight(.semibold)).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(2)
                    Text(entry.chapterTitle ?? String(localized: "继续阅读")).font(.subheadline)
                        .foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                    ProgressView(value: position).tint(Color(uiColor: theme.accent))
                    HStack(spacing: 6) {
                        Text(verbatim: progress).monospacedDigit()
                        if let lastRead {
                            Text("·")
                            Text(verbatim: lastRead)
                        }
                    }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
            .padding(16)
            .contentShape(.rect(cornerRadius: 20))
            .accessibilityElement(children: .ignore)
        }
        .buttonStyle(ContinueReadingButtonStyle())
        .accessibilityLabel(Text("\(Text("继续阅读"))，\(entry.title)"))
        .accessibilityValue(Text(verbatim: [
            entry.chapterTitle, progress, lastRead,
            entry.needsDownload ? String(localized: "待下载") : nil,
        ].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityIdentifier("library-file-\(entry.name)")
    }
}

private struct ContinueReadingButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color(uiColor: configuration.isPressed ? theme.ui(\.pressed, system: .tertiarySystemFill) : theme.surface),
                in: .rect(cornerRadius: 20)
            )
    }
}
