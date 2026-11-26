import MoonreadCoreBindings
import MoonreadData
import MoonreadDesign
import SwiftUI

public struct LibraryHomePage<Route: Hashable, Resume: View, Recovery: View, Shelves: View, Saved: View, Recent: View, Tip: View, DebugToolbar: View>: View {
    @Binding var homeSections: LibraryHomeSections
    let layout: LibraryLayout
    let recents: [LibraryEntry]
    let recentFailure: String?
    let hasSavedFilters: Bool
    let ready: Bool
    let error: String?
    let processingFiles: Bool
    let hasShelves: Bool
    let loading: UUID?
    let immediate: Bool
    let detent: PresentationDetent
    let recentRoute: Route
    let load: () async -> Void
    let refresh: () async -> Void
    let retryRecent: () -> Void
    let importNovels: () -> Void
    let addShelf: () -> Void
    let resume: (LibraryEntry) -> Resume
    let recovery: () -> Recovery
    let shelves: () -> Shelves
    let saved: () -> Saved
    let recent: (LibraryEntry, LibraryLayout) -> Recent
    let tip: () -> Tip
    let debugToolbar: () -> DebugToolbar
    @State private var editingHome = false
    @AccessibilityFocusState(for: .voiceOver) private var actionsFocused: Bool
    @Environment(\.theme) private var theme

    public init(homeSections: Binding<LibraryHomeSections>, layout: LibraryLayout, recents: [LibraryEntry],
                recentFailure: String?, hasSavedFilters: Bool, ready: Bool, error: String?, processingFiles: Bool,
                hasShelves: Bool, loading: UUID?, immediate: Bool, detent: PresentationDetent, recentRoute: Route,
                load: @escaping () async -> Void, refresh: @escaping () async -> Void, retryRecent: @escaping () -> Void,
                importNovels: @escaping () -> Void, addShelf: @escaping () -> Void,
                @ViewBuilder resume: @escaping (LibraryEntry) -> Resume,
                @ViewBuilder recovery: @escaping () -> Recovery, @ViewBuilder shelves: @escaping () -> Shelves, @ViewBuilder saved: @escaping () -> Saved,
                @ViewBuilder recent: @escaping (LibraryEntry, LibraryLayout) -> Recent,
                @ViewBuilder tip: @escaping () -> Tip, @ViewBuilder debugToolbar: @escaping () -> DebugToolbar) {
        _homeSections = homeSections
        self.layout = layout
        self.recents = recents
        self.recentFailure = recentFailure
        self.hasSavedFilters = hasSavedFilters
        self.ready = ready
        self.error = error
        self.processingFiles = processingFiles
        self.hasShelves = hasShelves
        self.loading = loading
        self.immediate = immediate
        self.detent = detent
        self.recentRoute = recentRoute
        self.load = load
        self.refresh = refresh
        self.retryRecent = retryRecent
        self.importNovels = importNovels
        self.addShelf = addShelf
        self.resume = resume
        self.recovery = recovery
        self.shelves = shelves
        self.saved = saved
        self.recent = recent
        self.tip = tip
        self.debugToolbar = debugToolbar
    }

    private var enabledSections: [LibraryHomeSection] { homeSections.visible }
    private var current: LibraryEntry? {
        enabledSections.contains(.resume) ? recents.first : nil
    }
    private var following: [LibraryEntry] {
        guard enabledSections.contains(.recent) else { return [] }
        let entries = recents.dropFirst(current == nil ? 0 : 1)
        return layout == .grid ? Array(entries) : Array(entries.prefix(2))
    }
    private var retrySection: LibraryHomeSection? {
        guard recentFailure != nil else { return nil }
        return enabledSections.first { $0 == .resume || $0 == .recent }
    }

    private func showsSection(_ section: LibraryHomeSection) -> Bool {
        if section == retrySection { return true }
        switch section {
        case .resume: return current != nil
        case .shelves: return true
        case .saved: return hasSavedFilters
        case .recent: return !following.isEmpty
        }
    }

    public var body: some View {
        Group {
            if ready {
                LibraryHomeLayout(enabledSections: enabledSections, showsSection: showsSection,
                                  editHome: { editingHome = true },
                                  refresh: refresh,
                                  section: homeSection)
            }
            else if let error = error {
                ContentUnavailableView { Label("暂时无法加载书架", systemImage: "books.vertical") } description: { Text(error) } actions: { Button("重试") { Task { await load() } } }
            } else { ProgressView("正在加载书架").frame(maxWidth: .infinity, maxHeight: .infinity).themedPage() }
        }
        .navigationTitle("书架").navigationBarTitleDisplayMode(.large)
        .background(Color(uiColor: theme.canvas).ignoresSafeArea(.container))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("导入小说", systemImage: "square.and.arrow.down", action: importNovels)
                    Button("添加书架", systemImage: "folder.badge.plus", action: addShelf)
                        .accessibilityIdentifier("chooseFolder")
                    if ready {
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
                debugToolbar()
            }
        }
        .sheet(isPresented: $editingHome, onDismiss: { actionsFocused = true }) {
            LibraryHomeEditor(sections: homeSections, detent: detent) { homeSections = $0 }
                .themeScope(theme)
        }
        .modifier(LibraryFileActivity(active: processingFiles))
        .safeAreaInset(edge: .top, spacing: 0) { if !enabledSections.isEmpty { tip() } }
        .task { await load() }
        .modifier(PageLoadingOverlay(request: loading, hasContent: hasShelves,
                                     label: "正在加载书架", immediate: immediate))
    }

    private func homeSection(_ section: LibraryHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch section {
            case .resume:
                if let current {
                    homeHeader(section.title, showsAll: following.isEmpty)
                    resume(current)
                }
            case .shelves:
                recovery()
                VStack(alignment: .leading, spacing: 12) {
                    homeHeader(section.title, showsAll: false)
                    shelves()
                }
            case .saved:
                saved()
            case .recent:
                recentBooks
            }
            if section == retrySection, let error = recentFailure {
                RecentReadingRetry(message: error, retry: retryRecent)
            }
        }
    }

    @ViewBuilder private var recentBooks: some View {
        if !following.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                homeHeader(LibraryHomeSection.recent.title, showsAll: true)
                if layout == .grid {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: LayoutTokens.content) {
                            ForEach(following, id: \.id) { entry in
                                recent(entry, .grid)
                            }
                        }.scrollTargetLayout()
                    }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
                        .accessibilityIdentifier("recentCoverRow")
                } else {
                    ForEach(following, id: \.id) { entry in
                        recent(entry, .list)
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
                NavigationLink(value: recentRoute) { HStack(spacing: 4) { Text("查看全部"); Image(systemName: "chevron.right") }.font(.subheadline) }
                    .foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("allRecents")
            }
        }
        .textCase(nil).accessibilityElement(children: .contain)
    }
}

/// The book to resume: a larger cover, its chapter and the current reading position.
public struct ContinueReadingRow<Cover: View>: View {
    let entry: LibraryEntry
    let open: () -> Void
    let cover: () -> Cover

    public init(entry: LibraryEntry, open: @escaping () -> Void, @ViewBuilder cover: @escaping () -> Cover) {
        self.entry = entry
        self.open = open
        self.cover = cover
    }
    @Environment(\.theme) private var theme
    private var position: Double { ReadingProgress.fraction(entry.positionUtf8, of: entry.byteCount) }
    private var progress: String { position.formatted(.percent.precision(.fractionLength(0))) }
    private var lastRead: String? {
        guard entry.lastRead > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(entry.lastRead) / 1000)
        if Date.now.timeIntervalSince(date) < 60 { return String(localized: "刚刚") }
        return date.formatted(.relative(presentation: .named))
    }

    public var body: some View {
        let lastRead = lastRead
        Button(action: open) {
            HStack(spacing: 16) {
                cover()
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
