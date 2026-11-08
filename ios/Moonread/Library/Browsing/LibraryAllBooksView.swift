import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryAllBooksView: View {
    private enum ScrollTarget: Hashable { case nameGroup(String) }
    private struct NameGroupBounds: PreferenceKey {
        static var defaultValue: [String: [Anchor<CGRect>]] { [:] }
        static func reduce(value: inout [String: [Anchor<CGRect>]], nextValue: () -> [String: [Anchor<CGRect>]]) {
            for (letter, bounds) in nextValue() { value[letter, default: []].append(contentsOf: bounds) }
        }
    }
    @Bindable var model: LibraryModel
    let shelfID: String
    @State private var groups: [LibraryNameGroup] = []
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
                                    .foregroundStyle(Color(uiColor: theme.secondary)).id(ScrollTarget.nameGroup(group.id))
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
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumBookWidth), spacing: LayoutTokens.content)], alignment: .leading, spacing: 0) {
                                ForEach(groups) { group in
                                    Section {
                                        ForEach(group.entries, id: \.id) { entry in
                                            LibraryBookTile(model: model, entry: entry, showPath: true)
                                                .contextMenu { LibraryItemMenu(model: model, entry: entry); LibraryLocationAction(model: model, entry: entry) }
                                                .padding(.bottom, LayoutTokens.section)
                                                .id(entry.id)
                                                .anchorPreference(key: NameGroupBounds.self, value: .bounds) { [group.id: [$0]] }
                                        }
                                    } header: {
                                        Text(verbatim: group.id)
                                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.bottom, LayoutTokens.compact)
                                            .accessibilityAddTraits(.isHeader)
                                            .id(ScrollTarget.nameGroup(group.id))
                                            .anchorPreference(key: NameGroupBounds.self, value: .bounds) { [group.id: [$0]] }
                                    }
                                }
                            }
                        }.padding(.leading, LayoutTokens.page).padding(.trailing, LayoutTokens.page + 20)
                            .padding(.top, LayoutTokens.control).padding(.bottom)
                    }
                    .themedPage().accessibilityIdentifier("libraryGrid")
                    .overlayPreferenceValue(NameGroupBounds.self) { bounds in
                        GeometryReader { geometry in
                            LibraryAlphabetIndex(letters: groups.map(\.id), current: currentNameGroup(bounds, in: geometry)) { letter in
                                proxy.scrollTo(ScrollTarget.nameGroup(letter), anchor: .top)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        }
                    }
                }
            }
            .overlay(alignment: .trailing) {
                if model.grouping == .name && model.layout == .list && !LibraryNativeIndexVisibility.available {
                    LibraryAlphabetIndex(letters: groups.map(\.id)) { letter in
                        proxy.scrollTo(ScrollTarget.nameGroup(letter), anchor: .top)
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
                try await AppDataService.libraryTestLatency()
                if model.grouping == .tags {
                    let catalogue = try await AppDataService.shared.libraryTagGroups(shelfID)
                    try Task.checkCancellation()
                    tagGroups = catalogue.groups; bookCount = catalogue.bookCount
                } else {
                    let values = try await AppDataService.shared.allLibraryBooks(shelfID)
                    let grouped = await Task.detached(priority: .userInitiated) { LibraryNameGroup.group(values) }.value
                    try Task.checkCancellation()
                    groups = grouped; bookCount = UInt64(values.count)
                }
                loaded = true
            } catch is CancellationError { } catch { model.error = ReaderMessages.error(error) }
        }

        .animation(MotionTokens.controls(reduced: reduceMotion), value: model.layout)
    }

    private func currentNameGroup(_ bounds: [String: [Anchor<CGRect>]], in geometry: GeometryProxy) -> String? {
        // Include tiles: a long group's header can be unloaded while its books
        // still fill the viewport. Resolve live anchors only in the index overlay;
        // no per-frame state writes or retained geometry/last-tapped letter.
        let starts = groups.compactMap { group -> (id: String, y: CGFloat)? in
            guard let y = bounds[group.id]?.map({ geometry[$0].minY }).min() else { return nil }
            return (group.id, y)
        }
        return starts.last(where: { $0.y <= geometry.safeAreaInsets.top })?.id ?? starts.first?.id ?? groups.first?.id
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
                }.padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.control).padding(.bottom)
            }.themedPage().accessibilityIdentifier("libraryTagGrid")
        }
    }

    @ViewBuilder private func tagHeading(_ group: LibraryTagGroup) -> some View {
        if group.kind == .tag {
            Button {
                model.path.append(.search(AppSearchScope(seeds: [.shelf(shelfID), .tag(group.tag)])))
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
