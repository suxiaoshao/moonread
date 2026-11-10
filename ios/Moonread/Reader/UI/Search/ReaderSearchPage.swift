import SwiftUI

/// The expanded search owns only native page/focus state; the same tools model
/// and reader session continue to own the job, hits and browsing origin.
struct ReaderSearchPage: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let expanded: Bool
    let readyForInput: Bool
    let selectHit: (SearchHit) -> Void
    let collapseSearch: () -> Void
    let closeSearch: () -> Void
    @Environment(\.theme) private var theme
    @FocusState private var queryFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.query.isEmpty || model.searchError != nil {
                    searchStatus.padding(.horizontal, 20)
                    ThemedDivider()
                }
                searchList
            }
            .background(Color(uiColor: theme.surface))
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("收起搜索结果", systemImage: "chevron.down") {
                        queryFocused = false; collapseSearch()
                    }.accessibilityIdentifier("collapseSearch")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Toggle("正则", isOn: $model.regex).accessibilityIdentifier("searchRegex")
                        Toggle("区分大小写", isOn: $model.caseSensitive).accessibilityIdentifier("searchMatchCase")
                    } label: { Label("搜索选项", systemImage: "line.3.horizontal.decrease") }
                    .accessibilityIdentifier("searchOptions")
                    SystemToolbarButton("结束搜索", role: .close) {
                        queryFocused = false; closeSearch()
                    }.accessibilityIdentifier("closeSearch")
                }
            }
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索这本书")
            .searchFocused($queryFocused)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                queryFocused = false
                if !model.searching && !model.searchFinished { model.startSearch() }
            }
        }
        .task(id: readyForInput) {
            if let id = session.readingID { await model.prepare(bookID: id, currentChapter: 0, library: false) }
            if !Task.isCancelled, readyForInput, expanded, model.query.isEmpty { queryFocused = true }
        }
        .onChange(of: expanded) { _, value in if !value { queryFocused = false } }
        .onChange(of: model.query) { _, _ in searchChanged() }
        .onChange(of: model.regex) { _, _ in searchChanged() }
        .onChange(of: model.caseSensitive) { _, _ in searchChanged() }
    }

    private func searchChanged() {
        session.clearSearchFocus()
        model.searchListPosition = nil
        model.startSearch()
    }

    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            if model.searching {
                LoadingActivity(size: 18, fraction: model.searchProgress, progressLabel: "搜索进度")
            }
            if !model.query.isEmpty { Text("已找到 \(model.hits.count) 处").monospacedDigit() }
            Spacer()
            if !model.query.isEmpty {
                Button(model.searching ? String(localized: "停止") : String(localized: "重新搜索"),
                       systemImage: model.searching ? "stop.fill" : "arrow.clockwise") {
                    if model.searching { model.stopSearch() } else { searchChanged() }
                }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                .accessibilityIdentifier("refreshSearch")
            }
        }
        .frame(minHeight: 44)
        if model.regex || model.caseSensitive {
            HStack {
                if model.regex { Text("正则") }
                if model.caseSensitive { Text("区分大小写") }
            }.accessibilityIdentifier("searchOptionsSummary")
        }
        if model.partialSearch || model.truncatedSearch {
            VStack(alignment: .leading, spacing: 4) {
                if model.partialSearch { Text("搜索范围：已准备的正文") }
                if model.truncatedSearch { Text("部分超长段落未执行正则搜索，其他结果仍可查看。") }
            }.accessibilityIdentifier("searchCoverageNotice")
        }
        if let error = model.searchError { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive)) }
        }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).padding(.bottom, 8).accessibilityIdentifier("searchStatus")
    }

    private var searchList: some View {
        let restorePosition = model.searchListPosition
        return ScrollViewReader { proxy in
            List {
                ForEach(model.hits, id: \.startUtf8) { hit in
                    resultRow(hit).id(hit.startUtf8)
                        .onGeometryChange(for: Bool.self) { geometry in
                            let frame = geometry.frame(in: .named("searchResultsViewport"))
                            return frame.minY <= 1 && frame.maxY > 1
                        } action: { atTop in
                            if atTop && expanded { model.searchListPosition = hit.startUtf8 }
                        }
                        // List reads traits on the outer row. Putting them
                        // inside the geometry adapter leaves system backgrounds.
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        .listRowBackground(Color(uiColor: isCurrent(hit) ? theme.selected : theme.surface))
                        .listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: theme.surface))
            .contentMargins(.top, 0)
            .coordinateSpace(name: "searchResultsViewport")
            .onAppear { if let restorePosition { proxy.scrollTo(restorePosition, anchor: .top) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("searchResults")
        .overlay {
            if !model.query.isEmpty && model.hits.isEmpty && !model.searching && model.searchError == nil {
                ThemedEmptyState(title: searchEmptyTitle, symbol: "magnifyingglass")
            }
        }
    }

    private func isCurrent(_ hit: SearchHit) -> Bool {
        session.focusRange?.startUtf8 == hit.startUtf8 && session.focusRange?.endUtf8 == hit.endUtf8
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = isCurrent(hit)
        return Button { queryFocused = false; selectHit(hit) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let chapter = hit.chapter { Text(verbatim: chapter).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                    Spacer(minLength: 8)
                    if selected { Image(systemName: "location.fill").font(.caption).foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true) }
                }
                Text(searchExcerpt(hit)).font(.body).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(session.navigating)
        .accessibilityIdentifier("searchHit-\(hit.startUtf8)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func searchExcerpt(_ hit: SearchHit) -> AttributedString {
        let coordinates = TextCoordinates(hit.excerpt)
        let start = coordinates.utf16Offset(atUTF8: Int(hit.highlightStart))
        let end = coordinates.utf16Offset(atUTF8: Int(hit.highlightEnd))
        var value = AttributedString(hit.excerpt)
        value.foregroundColor = Color(uiColor: theme.ink)
        if let lower = AttributedString.Index(String.Index(utf16Offset: start, in: hit.excerpt), within: value),
           let upper = AttributedString.Index(String.Index(utf16Offset: end, in: hit.excerpt), within: value) {
            value[lower..<upper].backgroundColor = Color(uiColor: isCurrent(hit) ? theme.searchCurrent : theme.search)
            value[lower..<upper].font = .body.weight(.semibold)
        }
        return value
    }
    private var searchEmptyTitle: String {
        return model.searchFinished ? String(localized: "没有找到匹配内容") : String(localized: "搜索已停止")
    }

}
