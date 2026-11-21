import Combine
import SwiftUI

private enum BookTagPickerCoordinates: Hashable { case content }

/// Both entry points select original strings. Their parent owns when the draft commits.
struct BookTagPicker<Controls: View, Footer: View>: View {
    enum Purpose {
        case filter, metadata
    }

    let service: AppDataService
    let purpose: Purpose
    var showsChoices = true
    @Binding var selection: [String]
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let footer: () -> Footer

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var options: [LibraryMetadataOptions.Tag]?
    @State private var error: String?
    @State private var reload = 0
    @State private var expanded: Set<BookTagCategory> = []
    @State private var position = ScrollPosition()
    @State private var offsets: [BookTagCategory: CGFloat] = [:]
    @State private var visibleGroup: BookTagCategory?
    @State private var pinnedHeight: CGFloat = 0
    @State private var jumpedTo: BookTagCategory?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var selectedIDs: Set<Data> { Set(selection.map { Data($0.utf8) }) }
    private var browsing: Bool { term.isEmpty && !selectedOnly }
    private var groups: [BookTagGroup] {
        let library = (options ?? []).map {
            BookTagChoice(name: $0.name, bookCount: $0.bookCount, category: BookTagCategory.category(for: $0.name))
        }
        let libraryIDs = Set(library.map(\.id))
        let selected = selection.filter { !libraryIDs.contains(Data($0.utf8)) }.map { name in
            BookTagChoice(name: name, bookCount: 0,
                          category: purpose == .filter ? .uncategorized : BookTagCategory.category(for: name))
        }
        return BookTagCategory.groups(library + selected)
    }

    var body: some View {
        let groups = groups
        ScrollView {
            LazyVStack(alignment: .leading, spacing: LayoutTokens.control, pinnedViews: [.sectionHeaders]) {
                controls()
                if showsChoices {
                    if let error {
                        ContentUnavailableView {
                            Label("无法加载选项", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("重试") { reload += 1 }
                        }
                    } else if options == nil {
                        ProgressView().frame(maxWidth: .infinity).padding(.vertical, LayoutTokens.section)
                    } else {
                        Section {
                            candidates(groups, selected: selectedIDs)
                        } header: {
                            pinnedHeader(browsing ? groups.map(\.id) : [])
                        }
                    }
                }
                footer()
            }
            .coordinateSpace(name: BookTagPickerCoordinates.content)
            .padding(.horizontal, LayoutTokens.content)
            .padding(.bottom, LayoutTokens.content)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: BookTagCategory?.self) { geometry in
            let edge = geometry.contentOffset.y + geometry.contentInsets.top + pinnedHeight + LayoutTokens.compact
            return groups.last { (offsets[$0.id] ?? .infinity) <= edge }?.id
        } action: { _, category in
            visibleGroup = category
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { jumpedTo = nil }
        }
        .scrollDismissesKeyboard(.interactively)
        .modifier(BookSearchOptionSearch(enabled: showsChoices, query: $query,
                                         prompt: purpose == .filter ? "搜索选项" : "搜索或新建标签"))
        .themedPage()
        .navigationTitle("标签")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: term) { _, _ in scrollToTop() }
        .onChange(of: selectedOnly) { _, _ in scrollToTop() }
        .onChange(of: selection.isEmpty) { _, empty in if empty { selectedOnly = false } }
        .onChange(of: showsChoices) { _, visible in
            if !visible { query = ""; selectedOnly = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated, object: service)
            .receive(on: DispatchQueue.main)) { _ in
            options = nil
            reload += 1
        }
        .task(id: showsChoices ? reload : nil) {
            guard showsChoices else { return }
            let request = reload
            error = nil
            do {
                let updates = try await service.metadataOptionsUpdates(shelfID: nil)
                for try await value in updates {
                    guard !Task.isCancelled, request == reload else { return }
                    options = value.tags
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, request == reload { self.error = ReaderMessages.error(error) }
            }
        }
    }

    private func scrollToTop() {
        jumpedTo = nil
        position.scrollTo(edge: .top)
    }

    private func pinnedHeader(_ categories: [BookTagCategory]) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            HStack {
                Group {
                    if selection.isEmpty { Text("已选标签") }
                    else { Text("已选 \(selection.count) 项") }
                }
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityAddTraits(.isHeader)
                Spacer()
                if purpose == .filter, !selection.isEmpty {
                    Button(selectedOnly ? "显示全部" : "只看已选") { selectedOnly.toggle() }
                        .font(.subheadline)
                }
            }
            if selection.isEmpty {
                Text("尚未选择")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: theme.secondary))
            } else {
                BookTagSelectionStrip(words: selection, remove: toggle)
            }
            if !categories.isEmpty {
                categoryIndex(categories)
                ThemedDivider()
            }
        }
        .padding(.vertical, LayoutTokens.compact)
        .background(Color(uiColor: theme.canvas).padding(.horizontal, -LayoutTokens.content))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pinnedHeight = $0 }
    }

    private func categoryIndex(_ categories: [BookTagCategory]) -> some View {
        let active = jumpedTo ?? visibleGroup.flatMap { categories.contains($0) ? $0 : nil } ?? categories.first
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: LayoutTokens.content) {
                    ForEach(categories) { category in
                        Button {
                            guard let y = offsets[category] else { return }
                            jumpedTo = category
                            withAnimation(reduceMotion ? nil : .default) {
                                position.scrollTo(y: max(0, y - pinnedHeight))
                            }
                        } label: {
                            Text(category.title).font(.subheadline)
                                .fontWeight(active == category ? .semibold : .regular)
                                .fixedSize()
                                .padding(.vertical, LayoutTokens.compact)
                                .overlay(alignment: .bottom) {
                                    if active == category {
                                        Rectangle().fill(Color(uiColor: theme.accent)).frame(height: LayoutTokens.border)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(uiColor: active == category ? theme.accent : theme.secondary))
                        .accessibilityAddTraits(active == category ? .isSelected : [])
                        .id(category)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityLabel("跳到分类")
            .onChange(of: active) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func candidates(_ groups: [BookTagGroup], selected: Set<Data>) -> some View {
        let missing = missingSelection
        if browsing {
            if groups.isEmpty {
                ContentUnavailableView("暂无标签", systemImage: "tag")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        if group.id != groups.first?.id { ThemedDivider() }
                        BookTagCategorySection(group: group, selected: selected, expanded: expanded.contains(group.id),
                                               missing: missing, toggle: toggle) {
                            if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                        }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.frame(in: .named(BookTagPickerCoordinates.content)).minY
                        } action: { offsets[group.id] = $0 }
                    }
                }
                .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            }
        } else {
            let matches = groups.flatMap(\.tags).filter {
                (!selectedOnly || selected.contains($0.id)) && LibraryQueryRules.selectionMatches($0.name, query: term)
            }
            let canCreate = purpose == .metadata && !term.isEmpty && !groups.contains { group in
                group.tags.contains { $0.name.utf8.elementsEqual(term.utf8) }
            }
            VStack(alignment: .leading, spacing: LayoutTokens.control) {
                if !matches.isEmpty {
                    Text(term.isEmpty ? "已选标签" : "搜索结果")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    BookTagFlow {
                        ForEach(matches) { choice in
                            BookTagOptionButton(choice: choice, selected: selected.contains(choice.id), toggle: toggle)
                        }
                    }
                    if matches.contains(where: { missing.contains($0.id) }) { unavailableNote }
                } else if !canCreate {
                    ContentUnavailableView.search(text: term)
                }
                if canCreate {
                    Button {
                        toggle(term)
                        query = ""
                    } label: {
                        Label("新建标签“\(term)”", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("createBookTag")
                }
            }
            .padding(LayoutTokens.control)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        }
    }

    private var missingSelection: Set<Data> {
        guard purpose == .filter else { return [] }
        let known = Set((options ?? []).map { Data($0.name.utf8) })
        return selectedIDs.subtracting(known)
    }

    private func toggle(_ name: String) {
        if let index = selection.firstIndex(where: { $0.utf8.elementsEqual(name.utf8) }) {
            selection.remove(at: index)
        } else {
            selection.append(name)
        }
    }
}

private struct BookTagSelectionStrip: View {
    let words: [String]
    let remove: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: LayoutTokens.compact) {
                    ForEach(words.map { Data($0.utf8) }, id: \.self) { word in
                        let name = String(decoding: word, as: UTF8.self)
                        Button { remove(name) } label: {
                            BookTagCapsule(name: name, style: .removable)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除标签 \(name)")
                        .id(word)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: words.count) { old, new in
                if new > old, let latest = words.last { proxy.scrollTo(Data(latest.utf8), anchor: .trailing) }
            }
        }
    }
}

private struct BookTagCategorySection: View {
    let group: BookTagGroup
    let selected: Set<Data>
    let expanded: Bool
    let missing: Set<Data>
    let toggle: (String) -> Void
    let toggleExpanded: () -> Void
    @State private var firstTwoRows: Int?

    private var visible: ArraySlice<BookTagChoice> {
        group.tags.prefix(expanded ? group.tags.count : (firstTwoRows ?? 2))
    }

    private var overflows: Bool {
        if let firstTwoRows { return firstTwoRows < group.tags.count }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            HStack {
                Text(group.category.title).font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if overflows {
                    Button(expanded ? "收起" : "展开", action: toggleExpanded)
                        .font(.subheadline)
                        .accessibilityLabel(expanded ? "收起\(group.category.title)" : "展开\(group.category.title)")
                        .accessibilityValue(expanded ? "已展开" : "已收起")
                }
            }
            BookTagFlow {
                ForEach(visible) { choice in
                    BookTagOptionButton(choice: choice, selected: selected.contains(choice.id), toggle: toggle)
                }
            }
            .background(alignment: .topLeading) {
                if group.tags.count > 2 {
                    BookTagFlow {
                        ForEach(group.tags) { choice in
                            BookTagCapsule(name: choice.name, style: selected.contains(choice.id) ? .selected : .option)
                                .anchorPreference(key: BookTagChipBounds.self, value: .bounds) { [$0] }
                        }
                    }
                    .overlayPreferenceValue(BookTagChipBounds.self) { anchors in
                        GeometryReader { proxy in
                            let count = twoRows(anchors.map { proxy[$0].minY })
                            Color.clear.onChange(of: count, initial: true) { _, count in firstTwoRows = count }
                        }
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
            if visible.contains(where: { missing.contains($0.id) }) { unavailableNote }
        }
        .padding(LayoutTokens.control)
    }

    private func twoRows(_ positions: [CGFloat]) -> Int {
        guard let first = positions.first, let second = positions.first(where: { $0 > first }) else {
            return positions.count
        }
        return positions.prefix { $0 <= second }.count
    }
}

private var unavailableNote: some View {
    Text("当前不可用，保留已选值").font(.caption).foregroundStyle(.secondary)
}

private struct BookTagChipBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct BookTagOptionButton: View {
    let choice: BookTagChoice
    let selected: Bool
    let toggle: (String) -> Void

    var body: some View {
        Button { toggle(choice.name) } label: {
            BookTagCapsule(name: choice.name, style: selected ? .selected : .option)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BookTagCapsule: View {
    enum Style { case option, selected, removable, summary }

    let name: String
    let style: Style
    @Environment(\.theme) private var theme

    private var background: Color {
        switch style {
        case .option: Color(uiColor: theme.ink).opacity(0.07)
        case .selected: Color(uiColor: theme.accent)
        case .removable, .summary: Color(uiColor: theme.accentSurface)
        }
    }

    private var foreground: Color {
        switch style {
        case .option: Color(uiColor: theme.ink)
        case .selected: Color(uiColor: theme.onAccent)
        case .removable, .summary: Color(uiColor: theme.accent)
        }
    }

    var body: some View {
        HStack(spacing: LayoutTokens.compact / 2) {
            if style == .selected { Image(systemName: "checkmark").font(.caption).accessibilityHidden(true) }
            Text(verbatim: name).lineLimit(style == .summary ? 1 : nil)
                .fixedSize(horizontal: style == .removable, vertical: true)
            if style == .removable { Image(systemName: "xmark").font(.caption).accessibilityHidden(true) }
        }
        .font(style == .summary || style == .removable ? .subheadline : .body)
        .foregroundStyle(foreground)
        .padding(.vertical, LayoutTokens.compact / 2)
        .padding(.horizontal, LayoutTokens.control)
        .background(background, in: .capsule)
        .padding(.vertical, style == .summary ? 0 : LayoutTokens.compact / 2)
        .frame(minHeight: style == .summary ? nil : LayoutTokens.hit)
        .contentShape(.rect)
    }
}

/// Wraps each pill at its own width and gives exceptionally long tags a whole row.
private struct BookTagFlow: Layout {
    let spacing = LayoutTokens.compact

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        return subviews.map { view in
            let preferred = view.sizeThatFits(.unspecified)
            let size = preferred.width <= width ? preferred : view.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight
                rowHeight = 0
            }
            let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            return frame
        }
    }
}

struct BookSearchTagRulePage: View {
    private enum Relation: CaseIterable, Hashable {
        case any, all, none, untagged

        init(_ match: BookSearchMatch) {
            switch match {
            case .any: self = .any
            case .all: self = .all
            case .none: self = .none
            }
        }

        var match: BookSearchMatch {
            switch self {
            case .any, .untagged: .any
            case .all: .all
            case .none: .none
            }
        }

        var title: String {
            self == .untagged ? String(localized: "无标签") : match.title
        }

        var explanation: LocalizedStringKey {
            switch self {
            case .any: "显示带有任一所选标签的小说"
            case .all: "显示同时带有全部所选标签的小说"
            case .none: "不显示带有所选标签的小说"
            case .untagged: "显示没有任何标签的小说"
            }
        }
    }

    let initial: BookSearchNode
    let onChange: (Bool) -> Void
    let complete: (BookSearchNode) -> Void
    let remove: (() -> Void)?
    @State private var relation: Relation
    @State private var words: [String]
    @State private var preservesExistingUntagged: Bool
    @Environment(\.theme) private var theme

    init(initial: BookSearchNode, onChange: @escaping (Bool) -> Void,
         complete: @escaping (BookSearchNode) -> Void, remove: (() -> Void)?) {
        self.initial = initial
        self.onChange = onChange
        self.complete = complete
        self.remove = remove
        let isUntagged = initial.match == .any && initial.values == [.untagged]
        _relation = State(initialValue: isUntagged ? .untagged : Relation(initial.match))
        _words = State(initialValue: initial.values.compactMap { if case .text(let word) = $0 { word } else { nil } })
        _preservesExistingUntagged = State(initialValue: !isUntagged && initial.values.contains(.untagged))
    }

    private var node: BookSearchNode {
        if preservesExistingUntagged, relation != .untagged { return initial }
        var node = initial
        node.match = relation.match
        node.values = relation == .untagged ? [.untagged] : words.map(BookSearchValue.text)
        return node
    }

    var body: some View {
        BookTagPicker(service: .shared, purpose: .filter,
                      showsChoices: relation != .untagged && !preservesExistingUntagged, selection: $words) {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                Picker("标签关系", selection: $relation) {
                    ForEach(Relation.allCases, id: \.self) { relation in
                        Text(relation.title).tag(relation)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(preservesExistingUntagged)
                if preservesExistingUntagged {
                    // A saved mixed or negative predicate keeps its exact meaning until explicitly edited.
                    Text(initial.expression { $0 }).font(.footnote)
                    Button("移除无标签选项") { preservesExistingUntagged = false }
                } else {
                    Text(relation.explanation).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.top, LayoutTokens.compact)
        } footer: {
            if let remove {
                Button("移除标签条件", role: .destructive, action: remove)
                    .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading)
                    .padding(.horizontal, LayoutTokens.control)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            }
        }
        .onChange(of: node) { _, value in onChange(value != initial) }
        .onDisappear { onChange(false) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SystemToolbarButton("完成", role: .confirm) { complete(node) }
                    .disabled(node.validation() != nil)
                    .accessibilityIdentifier("saveSearchCondition")
            }
        }
    }
}
