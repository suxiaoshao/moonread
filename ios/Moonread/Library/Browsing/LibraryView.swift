import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(AIService.self) private var ai
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The most recently opened book resumes from its own row; the rest follow as recents:
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
        .navigationTitle("书架").navigationBarTitleDisplayMode(.large)
        .background(Color(uiColor: theme.canvas).ignoresSafeArea(.container))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("导入小说", systemImage: "square.and.arrow.down") { model.chooseFiles(.novels(LibraryLocation(shelfID: "builtin"))) }
                    Button("添加书架", systemImage: "folder.badge.plus") { model.chooseFiles(.folder(nil)) }
                        .accessibilityIdentifier("chooseFolder")
                } label: { Label("书架操作", systemImage: "plus") }.toolbarGlyph().accessibilityIdentifier("libraryActions")
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
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let current {
                        VStack(alignment: .leading, spacing: 12) {
                            homeHeader("继续阅读", showsAll: following.isEmpty)
                            ContinueReadingRow(model: model, entry: current).contextMenu { recentMenu(current) }
                        }
                    }
                    ShelfRecoverySummary(model: model)
                    if sizeClass == .regular && geometry.size.width >= 720 {
                        HStack(alignment: .top, spacing: 24) {
                            shelves.frame(maxWidth: .infinity, alignment: .topLeading)
                            recentBooks.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        shelves
                        recentBooks
                    }
                }.padding([.horizontal, .top], 20).padding(.bottom).frame(maxWidth: 1040).frame(maxWidth: .infinity)
            }
            .refreshable { await model.refresh(showIndicator: false, userInitiated: true) }
        }.themedPage()
    }

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 12) {
            homeHeader("我的书架", showsAll: false)
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
                homeHeader("最近阅读", showsAll: true)
                if model.layout == .grid {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: LayoutTokens.content) {
                            ForEach(following, id: \.id) { entry in
                                RecentCoverTile(model: model, entry: entry) { recentMenu(entry) }
                            }
                        }.scrollTargetLayout()
                    }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                        .accessibilityIdentifier("recentCoverRow")
                } else {
                    ForEach(following, id: \.id) { entry in
                        RecentBookRow(model: model, entry: entry).contextMenu { recentMenu(entry) }
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

    @ViewBuilder private func recentMenu(_ entry: LibraryEntry) -> some View {
        Button("小说详情", systemImage: "info.circle") { model.path.append(.statistics(StatisticsRoute(target: .file(fileId: entry.id), title: entry.title))) }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                BookCoverView(title: entry.title, compact: true, cover: entry.metadata?.cover, contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.metadata?.author).frame(width: 60, height: 84)
                    .overlay { LibraryFileAvailability(entry: entry, compact: true) }
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: entry.title).font(.title3.weight(.semibold)).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(2)
                    Text(entry.chapterTitle ?? String(localized: "继续阅读")).font(.subheadline)
                        .foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                    ProgressView(value: position).tint(Color(uiColor: theme.accent))
                    HStack(spacing: 6) {
                        Text(position, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                        if entry.lastRead > 0 {
                            Text("·")
                            let lastRead = Date(timeIntervalSince1970: Double(entry.lastRead) / 1000)
                            if Date.now.timeIntervalSince(lastRead) < 60 { Text("刚刚") }
                            else { Text(lastRead, format: .relative(presentation: .named)) }
                        }
                    }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
            Button { model.systemReading.submit(.continueReading) } label: {
                Text("继续阅读").frame(maxWidth: .infinity)
            }.buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("library-file-\(entry.name)")
        }.padding(16).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 20))
    }
}

struct RecentBookRow: View {
    let model: LibraryModel
    let entry: LibraryEntry
    @Environment(\.theme) private var theme
    var body: some View {
        Button { model.open(entry) } label: {
            HStack(spacing: 15) {
                BookCoverView(title: entry.title, compact: true, cover: entry.metadata?.cover, contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.metadata?.author).frame(width: 44, height: 62)
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
                LibraryFileAvailability(entry: entry, compact: true).frame(width: 44, height: 62)
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
                BookCoverView(title: entry.title, cover: entry.metadata?.cover, contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.metadata?.author).aspectRatio(0.7, contentMode: .fit)
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
            .overlay(alignment: .top) { LibraryFileAvailability(entry: entry).aspectRatio(0.7, contentMode: .fit) }
    }
}
