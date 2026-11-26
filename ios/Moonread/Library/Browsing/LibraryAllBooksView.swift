import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI

struct LibraryAllBooksView: View {
    @Bindable var model: LibraryModel
    let shelfID: String
    let host: LibraryBrowsingHost
    @State private var catalogue = CatalogueStore(service: .shared)

    private struct CatalogueRequest: Hashable {
        let shelfID: String
        let grouping: LibraryGrouping
        let requestRevision: Int
    }
    private var request: CatalogueRequest {
        .init(shelfID: shelfID, grouping: model.grouping, requestRevision: catalogue.requestRevision)
    }
    private var shownGrouping: LibraryGrouping { catalogue.snapshot?.grouping ?? model.grouping }
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

    var body: some View {
        LibraryCollection(model: model, host: host, sections: sections,
                          accessibilityID: shownGrouping == .tags ? (model.layout == .grid ? "libraryTagGrid" : "libraryTagList") : nil,
                          onRefresh: {
            catalogue.retryIfFailed()
            await model.refresh(showIndicator: false, userInitiated: true)
        })
        .themedPage()
        .navigationTitle("全部小说").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryDisplayPicker(selection: $model.layout)
                    Menu("分组方式", systemImage: "rectangle.3.group") {
                        Picker("分组方式", selection: $model.grouping) {
                            Label("名称", systemImage: "textformat.abc").tag(LibraryGrouping.name)
                            Label("标签", systemImage: "tag").tag(LibraryGrouping.tags)
                        }.pickerStyle(.inline)
                    }.accessibilityIdentifier("libraryGrouping")
                } label: { Label("显示方式", systemImage: "ellipsis") }.toolbarGlyph().accessibilityIdentifier("folderActions")
            }
        }
        .modifier(LibraryFileActivity(model: model))
        .overlay { if catalogue.snapshot != nil && !catalogue.loading.active && !model.refreshing.active && model.shelfScans[shelfID] == nil && bookCount == 0 { ContentUnavailableView("暂无小说", systemImage: "books.vertical") } }
        .modifier(PageLoadingOverlay(request: model.processingFiles || model.nativeRefreshing ? nil : model.shelfScans[shelfID] ?? catalogue.loading.request ?? model.refreshing.request,
                                     hasContent: bookCount > 0, label: "正在加载书架", immediate: model.explicitRefresh || model.shelfScans[shelfID] != nil))
        .task(id: request) {
            let input = request
            await catalogue.observe(shelfID: input.shelfID, grouping: input.grouping) { error in
                if input == request { model.error = ReaderMessages.error(error) }
            }
        }
    }

    private func tagHeading(_ group: CatalogueTagSection) -> some View {
        Button {
            host.navigate(.search(AppSearchScope(seeds: [.shelf(shownShelfID), .tag(group.tag)])), in: model)
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
            Text(verbatim: model.shelfTitle(shownShelfID)).lineLimit(1)
            Spacer()
            Text("\(bookCount) 本小说")
        }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
    }
}
