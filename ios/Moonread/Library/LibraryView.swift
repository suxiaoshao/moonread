import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(AIService.self) private var ai
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    /// The most recent formal reading resumes from its own row; the rest follow as recents:
    /// two rows in the list layout, a scrollable cover row in the grid.
    private var current: LibraryEntry? { model.recents.first }
    private var following: [LibraryEntry] {
        model.layout == .grid ? Array(model.recents.dropFirst()) : Array(model.recents.dropFirst().prefix(2))
    }
    var body: some View {
        Group {
            if model.homeReady { homeList }
            else if let error = model.error {
                ContentUnavailableView { Label("暂时无法加载书架", systemImage: "books.vertical") } description: { Text(error) } actions: { Button("重试") { Task { await model.load() } } }
            } else { ProgressView("正在加载书架").frame(maxWidth: .infinity, maxHeight: .infinity).themedPage() }
        }
        .navigationTitle("书架").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(LibraryLocation(shelfID: "builtin"))) }
                    Button("添加书架", systemImage: "folder.badge.plus") { model.chooseFiles(.folder(nil)) }
                        .accessibilityIdentifier("chooseFolder")
                } label: { Label("书架操作", systemImage: "plus") }.toolbarGlyph().accessibilityIdentifier("libraryActions")
                if ai.availability.isAvailable { AppSettingsLink() }
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.showsImportTip, themes.loaded, model.libraryPath.isEmpty, model.selectedTab == .library {
                TipView(Onboarding.shared.imports).tipViewStyle(ThemedTipStyle()).padding(.horizontal)
                    .accessibilityIdentifier("libraryImportTip")
            }
        }
        .task { await model.load() }
        .modifier(PageLoadingOverlay(request: !themes.loaded || model.busy || model.nativeRefreshing ? nil : (!model.homeReady ? model.loading.request : (model.explicitRefresh ? model.refreshing.request : nil)),
                                     hasContent: !model.shelves.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh))
    }
    private var homeList: some View {
        List {
            if let current {
                // The book read most recently resumes from its own, larger row.
                Section {
                    ContinueReadingRow(model: model, entry: current).contextMenu { recentMenu(current) }
                } header: {
                    homeHeader("继续阅读", showsAll: following.isEmpty)
                }
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 24, bottom: 4, trailing: 24))
            }
            if !following.isEmpty {
                if model.layout == .grid {
                    Section {
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: LayoutTokens.content) {
                                ForEach(following, id: \.id) { entry in
                                    RecentCoverTile(model: model, entry: entry) { recentMenu(entry) }
                                }
                            }.scrollTargetLayout()
                        }
                        .scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                        .contentMargins(.horizontal, 24, for: .scrollContent)
                        .accessibilityIdentifier("recentCoverRow")
                    } header: {
                        // The header follows the row insets, which the edge-to-edge cover row clears.
                        homeHeader("最近阅读", showsAll: true).padding(.horizontal, 24)
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                } else {
                    Section {
                        ForEach(following, id: \.id) { entry in
                            RecentBookRow(model: model, entry: entry).contextMenu { recentMenu(entry) }
                        }
                    } header: {
                        homeHeader("最近阅读", showsAll: true)
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
                }
            }
            Section {
                ForEach(model.shelves, id: \.id) { shelf in
                    NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: shelf.id))) { ShelfRow(shelf: shelf) }
                        .contextMenu { ShelfMenu(model: model, shelf: shelf) }.accessibilityIdentifier("shelf-\(shelf.id)")
                        .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                }
            } header: {
                homeHeader("书架与文件夹", showsAll: false)
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 24, bottom: 2, trailing: 24))
        }
        .listStyle(.plain).themedPage()
        .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
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

    @ViewBuilder private func recentMenu(_ entry: LibraryEntry) -> some View {
        Button("小说详情", systemImage: "info.circle") { model.path.append(.statistics(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))) }
        Button("从最近移除", systemImage: "minus.circle") { Task { await model.hideRecent(entry) } }
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
    private var position: Double { min(1, Double(entry.positionUtf8) / Double(max(1, entry.byteCount))) }
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing: 16) {
                LibraryBookCover(title: entry.title, compact: true, cover: entry.metadata?.cover).frame(width: 60, height: 84)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: entry.title).font(.title3.weight(.semibold)).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(2)
                    Text(entry.chapterTitle ?? String(localized: "继续阅读")).font(.subheadline)
                        .foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                    HStack(spacing: 10) {
                        ProgressView(value: position).tint(Color(uiColor: theme.accent))
                        Text(position, format: .percent.precision(.fractionLength(1))).monospacedDigit()
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }
            }.padding(.vertical, 6).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
            .overlay(alignment: .leading) {
                LibraryFileLoading(model: model, entry: entry, compact: true).frame(width: 60, height: 84)
            }
    }
}

private struct RecentBookRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    @Environment(\.theme) private var theme
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing: 15) {
                LibraryBookCover(title: entry.title, compact: true, cover: entry.metadata?.cover).frame(width: 44, height: 62)
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: entry.title).font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(1)
                    HStack {
                        Text(entry.chapterTitle ?? String(localized: "继续阅读")).lineLimit(1); Spacer(minLength: 8)
                        Text(Double(entry.positionUtf8) / Double(max(1, entry.byteCount)), format: .percent.precision(.fractionLength(1))).monospacedDigit()
                    }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.padding(.vertical, 6).contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
            .overlay(alignment: .leading) {
                LibraryFileLoading(model: model, entry: entry, compact: true).frame(width: 44, height: 62)
            }
    }
}

/// A recent book in the grid layout's home row: its cover, title and reading progress.
/// A List lifts a row's context menu to the whole row, which would highlight every
/// cover at once; a menu button with a primary action highlights only this book.
private struct RecentCoverTile<Actions: View>: View {
    let model: LibraryModel
    let entry: LibraryEntry
    @ViewBuilder let actions: Actions
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var width = 96.0
    var body: some View {
        Menu { actions } label: {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                LibraryBookCover(title: entry.title, cover: entry.metadata?.cover).aspectRatio(0.7, contentMode: .fit)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: entry.title).font(.subheadline.weight(.medium))
                        .foregroundStyle(Color(uiColor: theme.ink)).lineLimit(2, reservesSpace: true)
                    Text(Double(entry.positionUtf8) / Double(max(1, entry.byteCount)), format: .percent.precision(.fractionLength(1)))
                        .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                }
            }.frame(width: width).contentShape(.rect)
        } primaryAction: { model.open(entry) }
            .buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
            // The cancel control sits beside the button, never inside its label.
            .overlay(alignment: .top) { LibraryFileLoading(model: model, entry: entry).aspectRatio(0.7, contentMode: .fit) }
    }
}

struct LibraryFolderView: View {
    @Bindable var model: LibraryModel
    let location: LibraryLocation
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var entries: [LibraryEntry] = []
    @State private var loaded = false
    @State private var loading = LoadingState()
    @State private var selection = Set<String>()
    @State private var editing = EditMode.inactive
    private var shelf: LibraryShelf? { model.shelves.first { $0.id == location.shelfID } }
    private var title: String { location.path.isEmpty ? model.shelfTitle(location.shelfID) : URL(fileURLWithPath: location.path).lastPathComponent }
    private var selectedEntries: [LibraryEntry] { entries.filter { selection.contains($0.id) } }
    private var allSelected: Bool { !entries.isEmpty && selection.count == entries.count }
    private var selectionTitle: String { String(localized: "已选 \(selection.count) 项") }
    private var fileActionsDisabled: Bool { !model.canAcceptFileWork }
    private var canCopySelection: Bool {
        !selectedEntries.isEmpty && selectedEntries.allSatisfy { !$0.directory && $0.shelfId != "builtin" }
    }
    var body: some View {
        browser
        .navigationTitle(editing.isEditing ? selectionTitle : title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(editing.isEditing)
        // Selection is a focused file task; its bottom toolbar takes the place
        // of app navigation until Done returns to ordinary browsing.
        .toolbarVisibility(editing.isEditing ? .hidden : .automatic, for: .tabBar)
        .toolbar {
            if editing.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allSelected ? LocalizedStringKey("取消全选") : LocalizedStringKey("全选")) {
                        selection = allSelected ? [] : Set(entries.map(\.id))
                    }
                    .disabled(entries.isEmpty || fileActionsDisabled)
                    .accessibilityIdentifier("librarySelectAll")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if editing.isEditing {
                    Button("完成", systemImage: "checkmark") { editing = .inactive; selection = [] }
                        .labelStyle(.titleOnly).accessibilityIdentifier("librarySelectionDone")
                        .disabled(fileActionsDisabled)
                }
                else {
                    Menu {
                        Button { model.sheet = .fullIndex(location.shelfID) } label: { Label { Text("建立索引", tableName: "FullIndex") } icon: { Image(systemName: "text.badge.checkmark") } }.accessibilityIdentifier("buildShelfIndex")
                        Button("选择项目", systemImage: "checkmark.circle") { editing = .active }
                        Button("新建文件夹", systemImage: "folder.badge.plus") { model.sheet = .create(location) }
                        if location.shelfID == "builtin" { Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(location)) } }
                        if ai.availability.isAvailable {
                            Button("整理…", systemImage: "folder.badge.gearshape") { model.aiRequest = .folder(location, title: title) }
                                .accessibilityIdentifier("organizeFolder")
                        }
                        Divider()
                        Picker("显示方式", selection: $model.layout) {
                            Label("列表", systemImage: "list.bullet").tag(LibraryLayout.list)
                            Label("网格", systemImage: "square.grid.3x3").tag(LibraryLayout.grid)
                        }.pickerStyle(.inline)
                        Divider()
                        if !location.path.isEmpty {
                            NavigationLink(value: LibraryRoute.allBooks(location.shelfID)) {
                                Label("全部小说", systemImage: "books.vertical")
                            }
                        }
                        Button("在此书架中搜索", systemImage: "magnifyingglass") { model.path.append(.search(AppSearchScope(tokens: [.shelf(location.shelfID)]))) }
                            .accessibilityIdentifier("searchShelf")
                    } label: { Label("文件夹操作", systemImage: "ellipsis") }.menuOrder(.fixed).toolbarGlyph().accessibilityIdentifier("folderActions").disabled(fileActionsDisabled)
                }
            }
            if editing.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu {
                        Button("分享", systemImage: "square.and.arrow.up") {
                            model.export(selectedEntries, sharing: true)
                        }
                        Button("导出", systemImage: "square.and.arrow.down") {
                            model.export(selectedEntries, sharing: false)
                        }
                    } label: { Label("分享与导出", systemImage: "square.and.arrow.up") }
                        .disabled(selectedEntries.isEmpty || selectedEntries.contains(where: \.directory) || fileActionsDisabled)
                        .accessibilityIdentifier("libraryShareSelection")
                    if location.shelfID != "builtin" {
                        Button("复制到我的书架", systemImage: "doc.on.doc") {
                            model.runBatch(selectedEntries.map { .copy($0) }) { command in
                                if case let .copy(entry) = command { selection.remove(entry.id) }
                            }
                        }.disabled(!canCopySelection || fileActionsDisabled).accessibilityIdentifier("libraryCopySelection")
                    }
                    Button("移动", systemImage: "folder") { model.sheet = .move(selectedEntries) }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                    if ai.availability.isAvailable {
                        Menu {
                            Button("完善资料", systemImage: "sparkles") { model.aiRequest = .library(selectedEntries, family: .metadata) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                            Button("整理所选", systemImage: "folder.badge.gearshape") { model.aiRequest = .library(selectedEntries, family: .organization) }
                                .disabled(!selectedEntries.contains { !$0.directory })
                        } label: { Label("AI 助手", systemImage: "sparkles") }
                            .disabled(selection.isEmpty || fileActionsDisabled).accessibilityIdentifier("libraryAISelection")
                    }
                    Button("删除", systemImage: "trash", role: .destructive) { model.deletion = selectedEntries }
                        .disabled(selection.isEmpty || fileActionsDisabled)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
            }
        }
        .task(id: model.revision) {
            let request = loading.begin(); defer { loading.finish(request) }
            let cloudGeneration = model.discoveryGeneration, cloudRevision = model.discoveryRevision
            do {
                try await ReaderService.libraryTestLatency()
                let value = try await ReaderService.shared.libraryEntries(location)
                try Task.checkCancellation(); entries = value
                selection.formIntersection(Set(value.map(\.id))); loaded = true
                if location.shelfID == "builtin", location.path.isEmpty {
                    model.builtinDirectoryLoaded(generation: cloudGeneration, snapshotRevision: cloudRevision)
                }
            } catch is CancellationError { } catch {
                if location.shelfID == "builtin", location.path.isEmpty { model.failCloudDiscovery(cloudGeneration); loaded = true }
                model.error = ReaderMessages.error(error)
            }
        }

        .onChange(of: model.recents) { _, values in
            let updates = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
            let next = entries.enumerated().map { index, original in
                var entry = updates[original.id] ?? original
                if entry.directory {
                    let children = values.filter { $0.shelfId == entry.shelfId && $0.relativePath.hasPrefix(entry.relativePath + "/") }
                    entry.lastRead = max(entry.lastRead, children.map(\.lastRead).max() ?? 0)
                }
                return (index, entry)
            }.sorted { a, b in
                let aEmpty = a.1.directory && a.1.childBookCount == 0
                let bEmpty = b.1.directory && b.1.childBookCount == 0
                if aEmpty != bEmpty { return !aEmpty }
                if a.1.lastRead != b.1.lastRead { return a.1.lastRead > b.1.lastRead }
                return a.0 < b.0 // Preserve the existing natural-name/modified tie order.
            }.map { $0.1 }
            if next != entries { entries = next }
        }
        .onChange(of: editing) { _, value in if value.isEditing { model.cancelOpening() } }
        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.shelfScans[location.shelfID] ?? loading.request ?? model.refreshing.request,
                                     hasContent: !entries.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh || model.shelfScans[location.shelfID] != nil))
    }

    private var browser: some View {
        LibraryCollection(ai: ai, model: model, location: location, entries: entries, shelf: shelf,
                          layout: model.layout, theme: theme, disabled: fileActionsDisabled,
                          showsEmpty: loaded && !loading.active && !model.refreshing.active && model.shelfScans[location.shelfID] == nil && entries.isEmpty && (shelf?.error == nil || (location.shelfID == "builtin" && location.path.isEmpty && model.builtinDiscovery == .unavailable)),
                          editing: $editing, selection: $selection)
            // UIKit applies the tab/toolbar safe inset to the scroll content.
            // Let its viewport draw behind the bar, as native SwiftUI lists do.
            .ignoresSafeArea(.container, edges: .bottom)
            .themedPage()
    }
}

/// A catalogue of one real shelf, grouped by name or projected tags.
struct LibraryAllBooksView: View {
    @Bindable var model: LibraryModel
    let shelfID: String
    @State private var groups: [LibraryNameGroup] = []
    @State private var books: [LibraryEntry] = []
    @State private var tagGroups: [LibraryTagGroup] = []
    @State private var bookCount: UInt64 = 0
    @State private var loaded = false
    @State private var loading = LoadingState()
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var minimumBookWidth = 96.0

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if model.grouping == .tags {
                    tagBrowser
                } else if model.layout == .list {
                    List {
                        summary.modifier(LibraryListHeading())
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.entries, id: \.id) { entry in
                                    LibraryFileRow(model: model, entry: entry, showPath: true)
                                        .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
                                        .listRowInsets(EdgeInsets(top: 0, leading: LayoutTokens.page, bottom: 0, trailing: LayoutTokens.page))
                                        .alignmentGuide(.listRowSeparatorLeading) { _ in LibraryFileRow.textLeading }
                                        .listRowBackground(Color.clear)
                                }
                            } header: {
                                Text(verbatim: group.id).font(.caption.weight(.semibold))
                                    .foregroundStyle(Color(uiColor: theme.secondary)).id(group.id)
                                    .listRowInsets(EdgeInsets(top: LayoutTokens.compact, leading: LayoutTokens.page, bottom: 4, trailing: LayoutTokens.page))
                            }.modifier(LibraryNativeIndexLabel(letter: group.id))
                        }
                    }.listStyle(.plain).themedPage()
                        .listSectionSpacing(.compact)
                        .environment(\.defaultMinListHeaderHeight, 24)
                        .contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
                        .modifier(LibraryNativeIndexVisibility()).accessibilityIdentifier("libraryList")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LayoutTokens.content) {
                            summary
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumBookWidth), spacing: LayoutTokens.content)], alignment: .leading, spacing: LayoutTokens.section) {
                                ForEach(books, id: \.id) { entry in
                                    LibraryBookTile(model: model, entry: entry, showPath: true)
                                        .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
                                        .id(entry.id)
                                }
                            }
                        }.padding(.leading, LayoutTokens.page).padding(.trailing, LayoutTokens.page + 20)
                            .padding(.vertical, LayoutTokens.control)
                    }.themedPage().accessibilityIdentifier("libraryGrid")
                        .modifier(LibraryGridTestGeometry())
                }
            }
            .overlay(alignment: .trailing) {
                if model.grouping == .name && (model.layout == .grid || !LibraryNativeIndexVisibility.available) {
                    LibraryAlphabetIndex(letters: groups.map(\.id)) { letter in
                        let target = model.layout == .grid ? groups.first(where: { $0.id == letter })?.entries.first?.id : letter
                        if let target { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
        }
        .navigationTitle("全部小说").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("显示方式", selection: $model.layout) {
                        Label("列表", systemImage: "list.bullet").tag(LibraryLayout.list)
                        Label("网格", systemImage: "square.grid.3x3").tag(LibraryLayout.grid)
                    }.pickerStyle(.inline)
                    Menu("分组方式", systemImage: "rectangle.3.group") {
                        Picker("分组方式", selection: $model.grouping) {
                            Label("名称", systemImage: "textformat.abc").tag(LibraryGrouping.name)
                            Label("标签", systemImage: "tag").tag(LibraryGrouping.tags)
                        }.pickerStyle(.inline)
                    }.accessibilityIdentifier("libraryGrouping")
                } label: { Label("显示方式", systemImage: "ellipsis") }.toolbarGlyph().accessibilityIdentifier("folderActions")
            }
        }
        .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
        .overlay { if loaded && !loading.active && !model.refreshing.active && model.shelfScans[shelfID] == nil && bookCount == 0 { ContentUnavailableView("暂无小说", systemImage: "books.vertical") } }
        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.shelfScans[shelfID] ?? loading.request ?? model.refreshing.request,
                                     hasContent: bookCount > 0, label: "正在加载书架", immediate: model.explicitRefresh || model.shelfScans[shelfID] != nil))
        .task(id: "\(model.revision):\(model.grouping.rawValue)") {
            let request = loading.begin(); defer { loading.finish(request) }
            do {
                try await ReaderService.libraryTestLatency()
                if model.grouping == .tags {
                    let catalogue = try await ReaderService.shared.libraryTagGroups(shelfID)
                    try Task.checkCancellation()
                    tagGroups = catalogue.groups; bookCount = catalogue.bookCount
                } else {
                    let values = try await ReaderService.shared.allLibraryBooks(shelfID)
                    let grouped = await Task.detached(priority: .userInitiated) { LibraryNameGroup.group(values) }.value
                    try Task.checkCancellation()
                    groups = grouped; books = grouped.flatMap(\.entries); bookCount = UInt64(values.count)
                }
                loaded = true
            } catch is CancellationError { } catch { model.error = ReaderMessages.error(error) }
        }

        .animation(MotionTokens.controls(reduced: reduceMotion), value: model.layout)
    }

    @ViewBuilder private var tagBrowser: some View {
        if model.layout == .list {
            List {
                summary.modifier(LibraryListHeading())
                ForEach(tagGroups) { group in
                    Section {
                        ForEach(group.entries, id: \.id) { entry in
                            LibraryFileRow(model: model, entry: entry, showPath: true)
                                .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
                                .listRowInsets(EdgeInsets(top: 0, leading: LayoutTokens.page, bottom: 0, trailing: LayoutTokens.page))
                                .alignmentGuide(.listRowSeparatorLeading) { _ in LibraryFileRow.textLeading }
                                .listRowBackground(Color.clear)
                        }
                    } header: { tagHeading(group) }
                }
            }.listStyle(.plain).themedPage().listSectionSpacing(.compact)
                .contentMargins(.top, LayoutTokens.compact, for: .scrollContent)
                .accessibilityIdentifier("libraryTagList")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    summary
                    ForEach(tagGroups) { group in
                        VStack(alignment: .leading, spacing: LayoutTokens.content) {
                            tagHeading(group)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumBookWidth), spacing: LayoutTokens.content)], alignment: .leading, spacing: LayoutTokens.section) {
                                ForEach(group.entries, id: \.id) { entry in
                                    LibraryBookTile(model: model, entry: entry, showPath: true)
                                        .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, LayoutTokens.page).padding(.vertical, LayoutTokens.control)
            }.themedPage().accessibilityIdentifier("libraryTagGrid")
        }
    }

    @ViewBuilder private func tagHeading(_ group: LibraryTagGroup) -> some View {
        if group.kind == .tag {
            Button {
                model.path.append(.search(AppSearchScope(tokens: [.shelf(shelfID), .tag(group.tag)])))
            } label: {
                tagHeadingLabel(group)
            }.buttonStyle(.plain).accessibilityIdentifier("library-tag-\(group.tag)")
        } else {
            tagHeadingLabel(group)
        }
    }

    private func tagHeadingLabel(_ group: LibraryTagGroup) -> some View {
        HStack {
            Text(verbatim: group.title).font(.subheadline.weight(.semibold))
            Text("\(UInt64(group.entries.count)) 本小说").font(.caption)
            if group.kind == .tag { Image(systemName: "chevron.right").font(.caption2) }
        }.foregroundStyle(Color(uiColor: group.kind == .tag ? theme.accent : theme.secondary))
            .textCase(nil).accessibilityElement(children: .combine)
    }

    private var summary: some View {
        HStack {
            Text(verbatim: model.shelfTitle(shelfID)).lineLimit(1)
            Spacer()
            Text("\(bookCount) 本小说")
        }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
    }
}

struct LibraryEmptyFolder: View {
    let model: LibraryModel
    let location: LibraryLocation
    @State private var guide = false
    private var builtinRoot: Bool { location.shelfID == "builtin" && location.path.isEmpty }
    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 16) {
                MoonView(size: 64).accessibilityHidden(true)
                if builtinRoot && model.builtinDiscovery == .discovering {
                    ProgressView("正在发现云端小说").accessibilityIdentifier("builtinDiscoveryLoading")
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") {
                        Button { model.receiveCloudDiscovery(.init(generation: model.discoveryGeneration, revision: 1, gathered: true, items: [])) } label: { Text(verbatim: "Deliver injected discovery snapshot") }
                            .accessibilityIdentifier("onboardingDeliverSnapshot")
                    }
                    #endif
                } else if builtinRoot && model.builtinDiscovery == .unavailable {
                    Text("暂未完成发现").font(.headline)
                    Button("重试") { model.retryCloudDiscovery() }
                } else {
                    Text(builtinRoot ? "还没有小说" : "空文件夹").font(.headline)
                        .accessibilityIdentifier(builtinRoot ? "builtinEmptyLibrary" : "emptyFolder")
                    if builtinRoot { Text("导入 TXT，或从“文件”App 拖进来").multilineTextAlignment(.center) }
                }
                if location.shelfID == "builtin" {
                    Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(location)) }
                        .buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("emptyFolderImport")
                    if builtinRoot {
                        Button("使用指南") { guide = true }.accessibilityIdentifier("emptyLibraryGuide")
                    }
                }
            }.padding().frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
        }
        }.sheet(isPresented: $guide) {
            NavigationStack { UsageGuideView().toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { guide = false } }
            } }
        }.allowsHitTesting(location.shelfID == "builtin")
    }
}

struct LibraryFileRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    var showPath = false
    var query = ""
    var select: (() -> Void)? = nil
    static let coverSize = CGSize(width: 32, height: 44)
    private var coverSize: CGSize { Self.coverSize }
    static let textLeading: CGFloat = 32 + LayoutTokens.control
    @ScaledMetric(relativeTo: .body) private var rowHeight = 60.0
    @Environment(\.theme) private var theme
    var body: some View {
            HStack(spacing: 4) {
                Button { if let select { select() } else { model.open(entry) } } label: {
                    HStack(spacing: LayoutTokens.control) {
                        if entry.directory {
                            LibraryFolderCover(previews: entry.coverPreviews).frame(width: coverSize.width, height: coverSize.height)
                        } else { LibraryBookCover(title: entry.title, compact: true, cover: entry.metadata?.cover).frame(width: coverSize.width, height: coverSize.height) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(highlighted).font(.body.weight(.medium)).lineLimit(1)
                            if showPath {
                                HStack(spacing: 6) {
                                    Text(verbatim: entry.directory ? entry.libraryDetail : entry.libraryProgress)
                                        .fixedSize(horizontal: true, vertical: false)
                                    Text("·").accessibilityHidden(true)
                                    HStack(spacing: 4) {
                                        Image(systemName: "folder").accessibilityHidden(true)
                                        Text(verbatim: model.shelfTitle(entry.shelfId) + (entry.parentPath.isEmpty ? "" : " / " + entry.parentPath))
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    .lineLimit(1)
                            } else {
                                Text(verbatim: entry.libraryDetail).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, LayoutTokens.compact).contentShape(.rect)
                }.buttonStyle(.plain).accessibilityIdentifier("library-file-\(entry.name)")
                    .overlay(alignment: .leading) {
                        if select == nil && !entry.directory {
                            LibraryFileLoading(model: model, entry: entry, compact: true).frame(width: coverSize.width, height: coverSize.height)
                        }
                    }
                if select == nil {
                    Menu {
                        LibraryItemMenu(model: model, entry: entry)
                        if showPath { LibraryLocationAction(model: model, entry: entry) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: LayoutTokens.hit, height: LayoutTokens.hit).foregroundStyle(Color(uiColor: theme.secondary))
                    }.accessibilityLabel(String(localized: "\(entry.name)的操作"))
                }
            }.frame(height: rowHeight)
    }
    private var highlighted: AttributedString {
        var text = AttributedString(entry.title); text.foregroundColor = Color(uiColor: theme.ink)
        if !query.isEmpty, let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].backgroundColor = Color(uiColor: theme.search); text[range].foregroundColor = Color(uiColor: theme.accent)
        }
        return text
    }
}

struct RecentLibraryView: View {
    @Bindable var model: LibraryModel
    @State private var loading = LoadingState()
    @State private var entries: [LibraryEntry] = []
    var body: some View {
        List(entries, id: \.id) { entry in
            RecentBookRow(model: model, entry: entry)
                .contextMenu {
                    Button("小说详情", systemImage: "info.circle") { model.path.append(.statistics(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))) }
                    Button("从最近移除", systemImage: "minus.circle") { Task { await model.hideRecent(entry); await loadEntries() } }
                }.listRowBackground(Color.clear)
        }.listStyle(.plain).themedPage().navigationTitle("最近阅读")
            .refreshable { await model.refresh(showIndicator: false, userInitiated: true); await loadEntries() }
            .modifier(PageLoadingOverlay(request: loading.request, hasContent: !entries.isEmpty, label: "正在加载"))
            .task { let request = loading.begin(); defer { loading.finish(request) }; await loadEntries() }
            .onChange(of: model.recents) { _, recents in updateEntries(recents) }
    }
    private func updateEntries(_ recents: [LibraryEntry]) {
        let updates = Dictionary(uniqueKeysWithValues: recents.map { ($0.id, $0) })
        var next = entries.map { updates[$0.id] ?? $0 }
        next.sort { a, b in a.lastRead == b.lastRead ? a.id < b.id : a.lastRead > b.lastRead }
        if next != entries { entries = next }
    }
    private func loadEntries() async {
        do { let next = try await ReaderService.shared.recentLibrary(); if next != entries { entries = next } }
        catch { model.error = ReaderMessages.error(error) }
    }
}

struct LibraryManagementView: View {
    @Bindable var model: LibraryModel
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                ForEach(model.shelves, id: \.id) { shelf in
                    NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: shelf.id))) {
                        ManagedShelfRow(shelf: shelf)
                    }
                    .accessibilityIdentifier("shelf-\(shelf.id)")
                    .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                    .contextMenu { ShelfMenu(model: model, shelf: shelf) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !shelf.builtin {
                            // Confirm before removing; a destructive swipe role
                            // would animate the row away before confirmation.
                            Button("移除", systemImage: "minus.circle") { model.removingShelf = shelf }
                                .tint(Color(uiColor: theme.destructive))
                                .accessibilityLabel("移除书架")
                                .accessibilityIdentifier("removeShelf-\(shelf.id)")
                        }
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: LayoutTokens.compact, leading: LayoutTokens.content,
                                     bottom: LayoutTokens.compact, trailing: LayoutTokens.content))
            .listRowBackground(Color(uiColor: theme.surface))
            .listRowSeparatorTint(Color(uiColor: theme.separator))
        }
        .listStyle(.insetGrouped).themedPage()
        .contentMargins(.top, LayoutTokens.content, for: .scrollContent)
        .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
        .navigationTitle("书架管理").navigationBarTitleDisplayMode(.inline)
        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.loading.request ?? model.refreshing.request ?? model.shelfScans.values.first ?? model.summaries.request,
                                     hasContent: !model.shelves.isEmpty, label: "正在加载书架", immediate: model.explicitRefresh))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加书架", systemImage: "plus") { model.chooseFiles(.folder(nil)) }
                    .labelStyle(.iconOnly).toolbarGlyph().accessibilityIdentifier("addLibraryShelf")
            }
        }
    }
}

private struct ManagedShelfRow: View {
    let shelf: LibraryShelf
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconSize = 24.0

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(shelf.builtin ? String(localized: "我的书架") : shelf.name)
                    .font(.body).foregroundStyle(Color(uiColor: theme.ink))
                if shelf.error != nil {
                    Text("需要重新连接").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                } else {
                    Text("\(shelf.bookCount) 本 · \(shelf.location == "icloud" ? "iCloud Drive" : shelf.builtin ? String(localized: "本机") : String(localized: "文件夹"))")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        } icon: {
            Group {
                Image(systemName: shelf.builtin ? "books.vertical" : "folder").resizable().scaledToFit()
                    .foregroundStyle(Color(uiColor: theme.accent))
            }.frame(width: iconSize, height: iconSize).accessibilityHidden(true)
        }
    }
}

struct ShelfMenu: View {
    let model: LibraryModel
    let shelf: LibraryShelf
    var body: some View {
        Group {
            Button { model.sheet = .fullIndex(shelf.id) } label: { Text("建立索引", tableName: "FullIndex") }
            Button("刷新", systemImage: "arrow.clockwise") { Task { await model.refresh(userInitiated: true) } }
            if !shelf.builtin {
                Button("重新连接", systemImage: "folder.badge.questionmark") { model.chooseFiles(.folder(shelf.id)) }
                Button("移除书架", systemImage: "minus.circle", role: .destructive) { model.removingShelf = shelf }
            }
        }.disabled(!model.canAcceptFileWork)
    }
}

/// Private item references can target any available shelf; external files only builtin.
private struct LibraryShelfDropTarget: ViewModifier {
    let model: LibraryModel
    let shelf: LibraryShelf
    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.moonreadLibraryItem, .plainText],
                       delegate: LibraryShelfDropDelegate(model: model, destination: LibraryLocation(shelfID: shelf.id)))
    }
}

/// The system hands providers to performDrop before any application payload loading.
struct LibraryShelfDropDelegate: DropDelegate {
    let model: LibraryModel
    let destination: LibraryLocation
    func validateDrop(info: DropInfo) -> Bool { operation(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])) != .forbidden }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: operation(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])))
    }
    func performDrop(info: DropInfo) -> Bool { accept(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])) }
    func operation(_ providers: [NSItemProvider]) -> DropOperation {
        guard model.canAcceptDrop(at: destination), let request = LibraryDropPolicy.request(providers, at: destination) else { return .forbidden }
        switch request { case .moveIDs, .moveProviders: return .move; case .importProviders: return .copy }
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let request = LibraryDropPolicy.request(providers, at: destination) else { return false }
        return model.acceptDrop(request, at: destination)
    }
}
