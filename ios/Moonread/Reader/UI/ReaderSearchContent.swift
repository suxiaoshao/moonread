import SwiftUI
import UIKit

struct ReaderSearchContent: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    @Binding var expanded: Bool
    let showsDetails: Bool
    let readyForInput: Bool
    let compactHeight: CGFloat
    let showsHistory: Bool
    let showHistory: () -> Void
    let closeSearch: () -> Void
    var inspector = false
    var focusChanged: (Bool) -> Void = { _ in }
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @FocusState private var queryFocused: Bool
    private var panelAnimation: Animation { MotionTokens.panel(reduced: reduceMotion) }
    private var activeIndex: Int? {
        guard let range = session.focusRange else { return nil }
        return model.hits.firstIndex { $0.startUtf8 == range.startUtf8 && $0.endUtf8 == range.endUtf8 }
    }

    var body: some View {
        Group {
            if showsDetails { searchDetails }
            else { searchCapsule }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerSearchPanel")
        .dismissKeyboardOnOutsideTap($queryFocused)
        .task(id: readyForInput) {
            guard showsDetails else { return }
            if let id = session.readingID { await model.prepare(bookID: id, currentChapter: 0, library: false) }
            if !Task.isCancelled, readyForInput, expanded, model.query.isEmpty { queryFocused = true }
        }
        .onChange(of: queryFocused) { _, focused in focusChanged(focused) }
        .onChange(of: expanded) { _, value in
            if !value { queryFocused = false }
        }
        .onChange(of: model.query) { _, _ in searchChanged() }
        .onChange(of: model.regex) { _, _ in searchChanged() }
        .onChange(of: model.caseSensitive) { _, _ in searchChanged() }
    }

    private var searchDetails: some View {
        VStack(spacing: 0) {
            if !inspector { HStack {
                Button("收起搜索结果", systemImage: "chevron.down", action: collapse)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("collapseSearch")
                Spacer()
                Text("搜索").font(.headline)
                Spacer()
                Button("关闭搜索", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .tint(Color(uiColor: theme.ink))
                    .accessibilityIdentifier("closeSearch")
            }
            .padding(.horizontal, 12).padding(.top, 16) }
            searchField.padding(.horizontal, 16).padding(.top, 4)
            if !model.query.isEmpty || model.error != nil {
                searchStatus.padding(.horizontal, 20)
                ThemedDivider().padding(.horizontal, 20)
            }
            searchList
            if inspector {
                HStack {
                    Button("上一个结果", systemImage: "chevron.up") { moveResult(-1) }
                        .disabled(activeIndex == nil || activeIndex == 0)
                    Spacer()
                    Button("下一个结果", systemImage: "chevron.down") { moveResult(1) }
                        .disabled(model.hits.isEmpty || (activeIndex.map { $0 + 1 >= model.hits.count } ?? false))
                }.labelStyle(.iconOnly).padding().tint(Color(uiColor: theme.accent))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary)).padding(.trailing, 4)
            TextField("搜索这本书", text: $model.query)
                .textFieldStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("bookSearchQuery")
                .focused($queryFocused)
                .submitLabel(.search)
                .onSubmit {
                    queryFocused = false
                    if !model.searching && !model.searchFinished { model.startSearch() }
                }
            if !model.query.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { model.query = ""; queryFocused = true }
                    .labelStyle(.iconOnly).foregroundStyle(Color(uiColor: theme.secondary)).frame(width: 32, height: 44)
            }
            ThemedDivider().frame(height: 22).padding(.horizontal, 3)
            optionButton("正则", value: $model.regex, id: "searchRegex") {
                Text(verbatim: ".*").font(.system(.body, design: .monospaced).weight(.semibold))
            }
            optionButton("区分大小写", value: $model.caseSensitive, id: "searchMatchCase") {
                Text(verbatim: "Aa").font(.system(.body, design: .serif).weight(.semibold))
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
        .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).strokeBorder(Color(uiColor: queryFocused ? theme.focus : theme.border), lineWidth: LayoutTokens.border))
        .keyboardInputRegion()
    }

    private func optionButton<Icon: View>(_ title: LocalizedStringKey, value: Binding<Bool>, id: String,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            icon().frame(width: 44, height: 44)
                .foregroundStyle(Color(uiColor: value.wrappedValue ? theme.accent : theme.secondary))
                .background(value.wrappedValue ? Color(uiColor: theme.accentSurface) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value.wrappedValue ? Text("开启") : Text("停用"))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(id)
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
        if model.partialSearch || model.truncatedSearch {
            VStack(alignment: .leading, spacing: 4) {
                if model.partialSearch { Text("搜索范围：已准备的正文") }
                if model.truncatedSearch { Text("部分超长段落未执行正则搜索，其他结果仍可查看。") }
            }.accessibilityIdentifier("searchCoverageNotice")
        }
        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive)) }
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
            if !model.query.isEmpty && model.hits.isEmpty && !model.searching && model.error == nil {
                ThemedEmptyState(title: searchEmptyTitle, symbol: "magnifyingglass")
            }
        }
    }

    private func isCurrent(_ hit: SearchHit) -> Bool {
        session.focusRange?.startUtf8 == hit.startUtf8 && session.focusRange?.endUtf8 == hit.endUtf8
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = isCurrent(hit)
        return Button { select(hit) } label: {
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

    private var searchCapsule: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { withAnimation(panelAnimation) { expanded = true } } label: {
                    HStack(spacing: 10) {
                        Group {
                            if model.searching {
                                LoadingActivity(size: 18, fraction: model.searchProgress, progressLabel: "搜索进度")
                            } else {
                                Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.accent))
                            }
                        }.frame(width: 44, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.query.isEmpty ? String(localized: "搜索这本书") : model.query)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let index = activeIndex {
                                Text("第 \(index + 1) 处，共 \(model.hits.count) 处")
                                    .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                            } else {
                                Text("已找到 \(model.hits.count) 处").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityLabel("展开搜索结果").accessibilityIdentifier("expandSearch")
                Button("上一个结果", systemImage: "chevron.up") { moveResult(-1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || (activeIndex ?? 0) == 0).accessibilityIdentifier("previousSearchHit")
                Button("下一个结果", systemImage: "chevron.down") { moveResult(1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || model.hits.isEmpty || (activeIndex.map { $0 + 1 >= model.hits.count } ?? false))
                    .accessibilityIdentifier("nextSearchHit")
            }
            if session.browseOrigin != nil {
                ReaderBrowseActions(session: session, showsHistory: showsHistory, showHistory: showHistory, finished: close)
            } else {
                HStack {
                    Spacer()
                    Button("关闭搜索", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        .tint(Color(uiColor: theme.ink))
                        .accessibilityIdentifier("closeCollapsedSearch")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("searchCapsule")
    }

    private func searchChanged() {
        guard showsDetails else { return }
        session.focusRange = nil
        model.searchListPosition = nil
        model.startSearch()
    }
    private func collapse() {
        queryFocused = false
        withAnimation(panelAnimation) { expanded = false }
    }
    private func close() { queryFocused = false; closeSearch() }
    private func select(_ hit: SearchHit) {
        model.searchListPosition = hit.startUtf8
        session.browse(to: hit.startUtf8, end: hit.endUtf8, bottomObstruction: compactHeight)
        if inspector { queryFocused = false } else { collapse() }
    }
    private func moveResult(_ direction: Int) {
        let index = activeIndex.map { $0 + direction } ?? 0
        guard model.hits.indices.contains(index) else { return }
        let hit = model.hits[index]
        model.searchListPosition = hit.startUtf8
        select(hit)
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
