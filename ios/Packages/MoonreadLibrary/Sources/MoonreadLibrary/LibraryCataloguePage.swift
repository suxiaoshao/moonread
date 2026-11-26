import MoonreadCoreBindings
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI

public struct LibraryCataloguePage<Collection: View>: View {
    let shelfID: String
    let shelfTitle: (String) -> String
    let reportError: (Error) -> Void
    let selectTag: (String, String) -> Void
    let refresh: () async -> Void
    let collection: ([LibraryCollectionSection], String?, @escaping () async -> Void) -> Collection
    let status: LoadingStatus
    @Binding var layout: LibraryLayout
    @Binding var grouping: LibraryGrouping
    @State private var catalogue: CatalogueStore

    public struct LoadingStatus {
        let scan: UUID?
        let refresh: UUID?
        let processingFiles: Bool
        let nativeRefreshing: Bool
        let explicitRefresh: Bool

        public init(scan: UUID?, refresh: UUID?, processingFiles: Bool, nativeRefreshing: Bool, explicitRefresh: Bool) {
            self.scan = scan; self.refresh = refresh; self.processingFiles = processingFiles
            self.nativeRefreshing = nativeRefreshing; self.explicitRefresh = explicitRefresh
        }
    }

    public init(shelfID: String, layout: Binding<LibraryLayout>, grouping: Binding<LibraryGrouping>, status: LoadingStatus,
                catalogue: @autoclosure @escaping () -> CatalogueStore, shelfTitle: @escaping (String) -> String,
                reportError: @escaping (Error) -> Void, selectTag: @escaping (String, String) -> Void,
                refresh: @escaping () async -> Void,
                @ViewBuilder collection: @escaping ([LibraryCollectionSection], String?, @escaping () async -> Void) -> Collection) {
        self.shelfID = shelfID; self._layout = layout; self._grouping = grouping; self.status = status
        self._catalogue = State(initialValue: catalogue()); self.shelfTitle = shelfTitle; self.reportError = reportError
        self.selectTag = selectTag; self.refresh = refresh; self.collection = collection
    }

    private struct CatalogueRequest: Hashable {
        let shelfID: String
        let grouping: LibraryGrouping
        let requestRevision: Int
    }
    private var request: CatalogueRequest {
        .init(shelfID: shelfID, grouping: grouping, requestRevision: catalogue.requestRevision)
    }
    private var shownGrouping: LibraryGrouping { catalogue.snapshot?.grouping ?? grouping }
    private var shownShelfID: String { catalogue.snapshot?.shelfID ?? shelfID }
    private var bookCount: UInt64 { catalogue.snapshot?.bookCount ?? 0 }
    private var groups: [LibraryNameGroup] {
        if case .names(let groups) = catalogue.snapshot?.content { groups } else { [] }
    }
    private var tagGroups: [CatalogueTagSection] {
        if case .tags(let groups, _) = catalogue.snapshot?.content { groups } else { [] }
    }
    private func card(_ fileID: String) -> LibraryEntry? {
        if case .tags(_, let cards) = catalogue.snapshot?.content { cards[fileID] } else { nil }
    }
    @Environment(\.theme) private var theme
    private var sections: [LibraryCollectionSection] {
        let overview = LibraryCollectionSection(id: .catalogueSummary, content: .rows([.init("summary") { summary }]))
        if shownGrouping == .tags {
            return [overview] + tagGroups.map { group in
                let header: LibraryCollectionSection.Header = group.kind == .tag
                    ? .action(AnyView(tagHeading(group)))
                    : .title(group.title, detail: String(localized: "\(UInt64(group.fileIDs.count)) 本小说"))
                return .init(id: .tag(group.id), content: .files(group.fileIDs.compactMap(card), .results), header: header)
            }
        }
        return [overview] + groups.map { group in
            .init(id: .name(group.id), content: .files(group.entries, .results), header: .title(group.id))
        }
    }

    public var body: some View {
        collection(sections, shownGrouping == .tags ? (layout == .grid ? "libraryTagGrid" : "libraryTagList") : nil) {
            catalogue.retryIfFailed()
            await refresh()
        }
        .themedPage()
        .navigationTitle("全部小说").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryDisplayPicker(selection: $layout)
                    Menu("分组方式", systemImage: "rectangle.3.group") {
                        Picker("分组方式", selection: $grouping) {
                            Label("名称", systemImage: "textformat.abc").tag(LibraryGrouping.name)
                            Label("标签", systemImage: "tag").tag(LibraryGrouping.tags)
                        }.pickerStyle(.inline)
                    }.accessibilityIdentifier("libraryGrouping")
                } label: { Label("显示方式", systemImage: "ellipsis") }.toolbarGlyph().accessibilityIdentifier("folderActions")
            }
        }
        .modifier(LibraryFileActivity(active: status.processingFiles))
        .overlay { if catalogue.snapshot != nil && !catalogue.loading.active && status.refresh == nil && status.scan == nil && bookCount == 0 { ContentUnavailableView("暂无小说", systemImage: "books.vertical") } }
        .modifier(PageLoadingOverlay(request: status.processingFiles || status.nativeRefreshing ? nil : status.scan ?? catalogue.loading.request ?? status.refresh,
                                     hasContent: bookCount > 0, label: "正在加载书架", immediate: status.explicitRefresh || status.scan != nil))
        .task(id: request) {
            let input = request
            await catalogue.observe(shelfID: input.shelfID, grouping: input.grouping) { error in
                if input == request { reportError(error) }
            }
        }
    }

    private func tagHeading(_ group: CatalogueTagSection) -> some View {
        Button {
            selectTag(shownShelfID, group.tag)
        } label: {
            HStack {
                Text(verbatim: group.title).font(.subheadline.weight(.semibold))
                Text("\(UInt64(group.fileIDs.count)) 本小说").font(.caption)
                Image(systemName: "chevron.right").font(.caption2)
            }
            .foregroundStyle(Color(uiColor: theme.accent))
            .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading)
            .contentShape(.rect)
        }.buttonStyle(.plain).accessibilityIdentifier("library-tag-\(group.tag)")
    }

    private var summary: some View {
        HStack {
            Text(verbatim: shelfTitle(shownShelfID)).lineLimit(1)
            Spacer()
            Text("\(bookCount) 本小说")
        }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
    }
}
