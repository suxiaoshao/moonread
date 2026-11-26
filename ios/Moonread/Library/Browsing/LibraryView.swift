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
    @Environment(\.horizontalSizeClass) private var sizeClass
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
            if model.homeReady { homeList }
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
            LibraryHomeEditor(sections: model.homeSections) { model.homeSections = $0 }
                .themeScope(theme)
        }
        .modifier(LibraryFileActivity(model: model))
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
    private var homeList: some View {
        GeometryReader { geometry in
            ScrollView {
                if enabledSections.contains(where: showsSection) {
                    VStack(alignment: .leading, spacing: 24) {
                        if sizeClass == .regular && geometry.size.width >= 720 {
                            wideSections
                        } else {
                            sectionStack(enabledSections)
                        }
                    }
                    .padding([.horizontal, .top], 20).padding(.bottom)
                    .frame(maxWidth: 1040).frame(maxWidth: .infinity)
                } else {
                    ContentUnavailableView {
                        Label(enabledSections.isEmpty ? "首页区块已全部隐藏" : "暂无可显示的区块",
                              systemImage: "rectangle.3.group")
                    } actions: {
                        Button("编辑首页", systemImage: "pencil") { editingHome = true }.buttonStyle(.bordered)
                    }
                    .frame(minHeight: geometry.size.height)
                }
            }
            .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
        }.themedPage()
    }

    @ViewBuilder private var wideSections: some View {
        let enabled = enabledSections
        let hasBanner = enabled.first == .resume
        let columns = hasBanner ? Array(enabled.dropFirst()) : enabled
        let leftCount = (columns.count + 1) / 2
        let left = Array(columns.prefix(leftCount))
        let right = Array(columns.dropFirst(leftCount))
        if hasBanner, showsSection(.resume) { homeSection(.resume) }
        if columns.contains(where: showsSection) {
            HStack(alignment: .top, spacing: 24) {
                if left.contains(where: showsSection) {
                    sectionStack(left).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if right.contains(where: showsSection) {
                    sectionStack(right).frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private func sectionStack(_ sections: [LibraryHomeSection]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(sections.filter(showsSection)) { section in
                homeSection(section)
            }
        }
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

private struct LibraryHomeEditor: View {
    @State private var sections: LibraryHomeSections
    let save: (LibraryHomeSections) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var detent: PresentationDetent = .medium

    init(sections: LibraryHomeSections, save: @escaping (LibraryHomeSections) -> Void) {
        _sections = State(initialValue: sections)
        self.save = save
        #if DEBUG
        if let capture = StoreShotCapture.requested,
           capture.scene == StoreShotScene.homeEditor.rawValue, capture.group.hasPrefix("duo-") {
            _detent = State(initialValue: .large)
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                if !sections.visible.isEmpty {
                    Section("显示") {
                        ForEach(sections.visible) { section in
                            sectionRow(section, visible: true)
                        }
                        .onMove { sections.visible.move(fromOffsets: $0, toOffset: $1) }
                    }
                }
                if !sections.hidden.isEmpty {
                    Section("隐藏") {
                        ForEach(sections.hidden) { section in
                            sectionRow(section, visible: false)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .themedPage()
            .navigationTitle("编辑首页").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SystemToolbarButton("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SystemToolbarButton("完成", role: .confirm) {
                        save(sections)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: typeSize, initial: true) { _, size in
            if size.isAccessibilitySize { detent = .large }
        }
    }

    private func sectionRow(_ section: LibraryHomeSection, visible: Bool) -> some View {
        HStack(spacing: LayoutTokens.compact) {
            Button {
                withAnimation {
                    if visible { sections.hide(section) }
                    else { sections.show(section) }
                }
            } label: {
                Image(systemName: visible ? "minus.circle.fill" : "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(visible ? Color.red : Color.green)
                    .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(visible ? Text("隐藏\(Text(section.title))") : Text("显示\(Text(section.title))"))
            Text(section.title)
        }
        .listRowBackground(Color(uiColor: theme.surface))
    }
}

struct ShelfRow: View {
    let shelf: LibraryShelf
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 14) {
            Group {
                Image(systemName: shelf.builtin ? "books.vertical" : "folder").font(.system(size: 29, weight: .light))
                    .foregroundStyle(Color(uiColor: theme.accent))
            }.frame(width: 46, height: 48)
            VStack(alignment: .leading, spacing: 5) {
                Text(shelf.builtin ? String(localized: "我的书架") : shelf.name).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                if shelf.error != nil { Label("需要重新连接", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                else {
                    Text("\(shelf.bookCount) 本 · \(shelf.location == "icloud" ? "iCloud Drive" : shelf.builtin ? String(localized: "本机") : String(localized: "文件夹"))")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }.padding(.vertical, 12)
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
