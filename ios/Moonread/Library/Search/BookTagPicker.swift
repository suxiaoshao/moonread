import MoonreadCoreBindings
import Combine
import SwiftUI
import UIKit

/// Both entry points select original strings. Their parent owns when the draft commits.
struct BookTagPicker<Controls: View, Status: View>: View {
    enum Purpose {
        case filter, metadata
    }

    let service: AppDataService
    let purpose: Purpose
    var showsChoices = true
    var match: BookSearchMatch?
    @Binding var selection: [String]
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let status: () -> Status

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var options: [LibraryMetadataOptions.Tag]?
    @State private var error: String?
    @State private var reload = 0
    @State private var expanded: Set<BookTagCategory> = []
    @State private var foldedCounts: [BookTagCategory: Int] = [:]
    @State private var position = ScrollPosition()
    @State private var activeGroup: BookTagCategory?
    @State private var viewport = BookTagViewport()
    @State private var horizontalMargins: NSDirectionalEdgeInsets?

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
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
        let browsesCategories = showsChoices && browsing && options != nil && error == nil
        let currentGroup = browsesCategories ? groups.first { $0.id == activeGroup } : nil
        // The system toolbar applies its own scroll-edge material to this page.
        ScrollViewReader { scroll in
            Group {
                if showsChoices {
                    catalogue(groups)
                } else {
                    VStack(spacing: 0) {
                        controls()
                        ScrollView { status().frame(maxWidth: .infinity) }
                            .defaultScrollAnchor(.center, for: .alignment)
                    }
                    .padding(.leading, horizontalMargins?.leading)
                    .padding(.trailing, horizontalMargins?.trailing)
                }
            }
            .background {
                BookTagSystemMargins { horizontalMargins = $0 }.allowsHitTesting(false)
            }
            .toolbar {
                if #unavailable(iOS 26), let currentGroup {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("标签").font(.headline)
                            Text(currentGroup.category.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                    }
                }
                if browsesCategories && !groups.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            if let currentGroup, canExpand(currentGroup) {
                                let category = currentGroup.category
                                if expanded.contains(category) {
                                    Button("收起「\(category.title)」") {
                                        expanded.remove(category)
                                        jump(to: category, using: scroll)
                                    }
                                } else {
                                    Button("展开「\(category.title)」") {
                                        expanded.insert(category)
                                    }
                                }
                            }
                            Section("跳到分类") {
                                ForEach(groups) { group in
                                    Button {
                                        jump(to: group.id, using: scroll)
                                    } label: {
                                        if group.id == (currentGroup?.id ?? groups.first?.id) {
                                            Label(group.category.title, systemImage: "checkmark")
                                        } else {
                                            Text(group.category.title)
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("跳到分类", systemImage: "list.bullet").labelStyle(.iconOnly)
                        }
                    }
                }
            }
        }
        .modifier(BookSearchOptionSearch(enabled: showsChoices, query: $query,
                                         prompt: purpose == .filter ? "搜索选项" : "搜索或新建标签"))
        .themedPage()
        .navigationTitle("标签")
        .navigationBarTitleDisplayMode(.inline)
        .tagCategorySubtitle(currentGroup?.category.title)
        .onChange(of: term) { _, _ in scrollToTop() }
        .onChange(of: selectedOnly) { _, _ in scrollToTop() }
        .onChange(of: selection.isEmpty) { _, empty in if empty { selectedOnly = false } }
        .onChange(of: match) { _, _ in resetSearch() }
        .onChange(of: showsChoices) { _, _ in resetSearch() }
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

    private func resetSearch() {
        query = ""
        selectedOnly = false
        scrollToTop()
    }

    private func scrollToTop() {
        viewport.pending = nil
        activeGroup = nil
        position.scrollTo(edge: .top)
    }

    private func jump(to category: BookTagCategory, using scroll: ScrollViewProxy) {
        viewport.pending = nil
        withAnimation(reduceMotion ? nil : .default) {
            scroll.scrollTo(category, anchor: .top)
        }
    }

    private var selectionHeader: some View {
        let words = Array(selection.reversed())
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("已选 \(words.count)").font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if purpose == .filter, !words.isEmpty {
                    Button(selectedOnly ? "显示全部" : "只看已选") { selectedOnly.toggle() }
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.ink))
                }
            }
            .padding(.vertical, LayoutTokens.compact)
            Group {
                if words.isEmpty {
                    Text("尚未选择标签").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    selectionChips(words)
                }
            }
            .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading)

        }
    }

    private func selectionChips(_ words: [String]) -> some View {
        BookTagFlow {
            ForEach(words.map { Data($0.utf8) }, id: \.self) { id in
                let name = String(decoding: id, as: UTF8.self)
                Button { setSelected(false, name: name, fromSelection: true) } label: {
                    HStack(spacing: LayoutTokens.compact / 2) {
                        Text(verbatim: name).lineLimit(1)
                        Image(systemName: "xmark").font(.caption).accessibilityHidden(true)
                    }
                    .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .frame(minHeight: LayoutTokens.hit)
                .accessibilityLabel("移除标签 \(name)")
            }
        }
    }

    private func catalogue(_ groups: [BookTagGroup]) -> some View {
        let selectionIDs = selection.map { Data($0.utf8) }
        let selected = Set(selectionIDs)
        let known = Set((options ?? []).map { Data($0.name.utf8) })
        let missing = purpose == .filter ? selected.subtracting(known) : []
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                controls()
                selectionHeader
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
                } else if browsing {
                    if groups.isEmpty {
                        ContentUnavailableView("暂无标签", systemImage: "tag")
                    }
                    ForEach(groups) { group in
                        categorySection(group, selected: selected, missing: missing)
                    }
                } else {
                    filteredChoices(groups, selected: selected, missing: missing)
                }
            }
            .padding(.bottom, LayoutTokens.content)
            .transformAnchorPreference(key: BookTagViewportAnchors.self, value: .bounds) { $0.content = $1 }
        }
        .contentMargins(.leading, horizontalMargins?.leading, for: .scrollContent)
        .contentMargins(.trailing, horizontalMargins?.trailing, for: .scrollContent)
        .scrollPosition($position)
        .onScrollGeometryChange(for: BookTagViewport.ScrollMetrics.self) { geometry in
            .init(insets: geometry.contentInsets, offset: geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, metrics in
            viewport.metrics = metrics
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { viewport.pending = nil }
        }
        .overlayPreferenceValue(BookTagViewportAnchors.self) { anchors in
            GeometryReader { proxy in
                if let content = anchors.content {
                    let frames = BookTagViewport.Frames(
                        selection: selectionIDs, content: proxy[content], height: proxy.size.height,
                        choices: anchors.choices.mapValues { proxy[$0] },
                        groupBodies: anchors.groupBodies.mapValues { proxy[$0] },
                        headers: anchors.headers.mapValues { proxy[$0] })
                    Color.clear.onChange(of: frames, initial: true) { _, frames in
                        updateViewport(frames, categories: groups.map(\.id))
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func categorySection(_ group: BookTagGroup, selected: Set<Data>, missing: Set<Data>) -> some View {
        let opened = expanded.contains(group.id)
        let foldedCount = foldedCounts[group.id] ?? 2
        let visible = group.tags.prefix(opened ? group.tags.count : foldedCount)
        return Section {
            VStack(alignment: .leading, spacing: 0) {
                choiceChips(visible, selected: selected)
                    .background(alignment: .topLeading) {
                        if group.tags.count > 2 {
                            BookTagWrapProbe(choices: group.tags, selected: selected) { count in
                                foldedCounts[group.id] = count
                            }
                        }
                    }
                if visible.contains(where: { missing.contains($0.id) }) { unavailableNote }
            }
            .padding(.bottom, LayoutTokens.page)
            // The menu scrolls to the body so the heading can hand off to the subtitle.
            .id(group.id)
            .transformAnchorPreference(key: BookTagViewportAnchors.self, value: .bounds) {
                $0.groupBodies[group.id] = $1
            }
        } header: {
            HStack {
                Text(group.category.title).font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if canExpand(group) {
                    Button(opened ? "收起" : "展开") {
                        if !expanded.insert(group.id).inserted { expanded.remove(group.id) }
                    }
                    .font(.subheadline)
                    .accessibilityLabel(opened ? "收起\(group.category.title)" : "展开\(group.category.title)")
                    .accessibilityValue(opened ? "已展开" : "已收起")
                }
            }
            .padding(.vertical, LayoutTokens.compact)
            .anchorPreference(key: BookTagViewportAnchors.self, value: .bounds) {
                .init(headers: [group.id: $0])
            }
        }
    }

    private func canExpand(_ group: BookTagGroup) -> Bool {
        foldedCounts[group.id].map { $0 < group.tags.count } ?? false
    }

    @ViewBuilder private func filteredChoices(_ groups: [BookTagGroup], selected: Set<Data>, missing: Set<Data>) -> some View {
        let matches = groups.flatMap(\.tags).filter {
            (!selectedOnly || selected.contains($0.id)) && LibraryQueryRules.selectionMatches($0.name, query: term)
        }
        let canCreate = purpose == .metadata && !term.isEmpty && !groups.contains { group in
            group.tags.contains { $0.name.utf8.elementsEqual(term.utf8) }
        }
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            if !matches.isEmpty {
                Text(selectedOnly ? "已选标签" : "搜索结果")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                choiceChips(matches, selected: selected)
                if matches.contains(where: { missing.contains($0.id) }) { unavailableNote }
            } else if !canCreate {
                ContentUnavailableView.search(text: term)
            }
            if canCreate {
                Button {
                    setSelected(true, name: term)
                    query = ""
                } label: {
                    Label("新建标签“\(term)”", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("createBookTag")
            }
        }
        .padding(.top, LayoutTokens.control)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceChips<Choices: RandomAccessCollection>(_ choices: Choices, selected: Set<Data>) -> some View
        where Choices.Element == BookTagChoice
    {
        BookTagFlow {
            ForEach(choices) { choice in
                BookTagOptionToggle(name: choice.name, isOn: Binding(
                    get: { selected.contains(choice.id) },
                    set: { setSelected($0, name: choice.name) }
                ))
                    .anchorPreference(key: BookTagViewportAnchors.self, value: .bounds) {
                        .init(choices: [choice.id: $0])
                    }
            }
        }
    }

    private func setSelected(_ isSelected: Bool, name: String, fromSelection: Bool = false) {
        let id = Data(name.utf8)
        var next = selection
        let removing = next.firstIndex { $0.utf8.elementsEqual(name.utf8) }
        guard (removing == nil) == isSelected else { return }
        if let removing { next.remove(at: removing) } else { next.append(name) }

        let candidateStays = removing == nil || (!selectedOnly && (options ?? []).contains {
            $0.name.utf8.elementsEqual(name.utf8)
        })
        if !fromSelection && candidateStays, let y = viewport.frames?.choices[id]?.minY {
            viewport.anchor(id, y: y, selection: next)
        } else if let (target, frame) = viewport.firstVisibleChoice(excluding: id) {
            viewport.anchor(target, y: frame.minY, selection: next)
        } else {
            viewport.pending = nil
        }
        selection = next
    }

    private func updateViewport(_ frames: BookTagViewport.Frames, categories: [BookTagCategory]) {
        viewport.frames = frames
        let insets = viewport.metrics.insets
        let top = insets.top
        let active = frames.category(above: top, orderedBy: categories)
        if activeGroup != active { activeGroup = active }
        guard let pending = viewport.pending, frames.selection == pending.selection else { return }
        viewport.pending = nil
        guard let newY = frames.choices[pending.id]?.minY else { return }
        guard abs(newY - pending.y) > 0.5 else { return }
        // The viewport can extend under the toolbar. Compute the target from
        // the tapped offset and the chip's movement within scroll content.
        let newContentY = newY - frames.content.minY
        let maxOffset = max(0, frames.content.height + insets.top + insets.bottom - frames.height)
        let offset = min(maxOffset, max(0, pending.scrollOffset + newContentY - pending.contentY))
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(y: offset) }
    }
}

private extension View {
    @ViewBuilder
    func tagCategorySubtitle(_ title: String?) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(title ?? "")
        } else {
            self
        }
    }
}

/// UIKit supplies the navigation host's current system margins for this viewport.
private struct BookTagSystemMargins: UIViewControllerRepresentable {
    let report: (NSDirectionalEdgeInsets) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.report = report }

    final class Controller: UIViewController {
        var report: ((NSDirectionalEdgeInsets) -> Void)?
        private var previous: NSDirectionalEdgeInsets?

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            let margins = parent?.systemMinimumLayoutMargins ?? systemMinimumLayoutMargins
            guard view.window != nil, margins != previous else { return }
            previous = margins
            // Layout may run synchronously during a SwiftUI update.
            Task { @MainActor [weak self] in
                guard let self, previous == margins else { return }
                report?(margins)
            }
        }
    }
}

/// Geometry during a drag is local bookkeeping. It only changes view state
/// when the active category changes or a selection compensation is needed.
@MainActor private final class BookTagViewport {
    struct Frames: Equatable {
        let selection: [Data]
        let content: CGRect
        let height: CGFloat
        let choices: [Data: CGRect]
        let groupBodies: [BookTagCategory: CGRect]
        let headers: [BookTagCategory: CGRect]

        func category(above top: CGFloat, orderedBy categories: [BookTagCategory]) -> BookTagCategory? {
            // The body's top is the heading's bottom, even if the lazy stack has recycled the heading.
            let firstMeasured = categories.firstIndex { headers[$0] != nil || groupBodies[$0] != nil }
            let lastCrossed = categories.lastIndex {
                guard let bottom = headers[$0]?.maxY ?? groupBodies[$0]?.minY else { return false }
                return bottom <= top + 0.5
            }
            let index = lastCrossed ?? firstMeasured.map { $0 - 1 }
            return index.flatMap { categories.indices.contains($0) ? categories[$0] : nil }
        }
    }

    struct ScrollMetrics: Equatable {
        let insets: EdgeInsets
        let offset: CGFloat
    }

    struct Pending {
        let id: Data
        let y: CGFloat
        let contentY: CGFloat
        let scrollOffset: CGFloat
        let selection: [Data]
    }

    var frames: Frames?
    var metrics = ScrollMetrics(insets: EdgeInsets(), offset: 0)
    var pending: Pending?

    func anchor(_ id: Data, y: CGFloat, selection: [String]) {
        guard let frames else { return }
        pending = Pending(id: id, y: y, contentY: y - frames.content.minY,
                          scrollOffset: metrics.offset, selection: selection.map { Data($0.utf8) })
    }

    func firstVisibleChoice(excluding id: Data) -> (Data, CGRect)? {
        guard let frames else { return nil }
        let insets = metrics.insets
        return frames.choices.filter { entry in
            entry.key != id && entry.value.minY >= insets.top && entry.value.maxY <= frames.height - insets.bottom
        }.min { lhs, rhs in
            (lhs.value.minY, lhs.value.minX) < (rhs.value.minY, rhs.value.minX)
        }
    }
}

private struct BookTagViewportAnchors: PreferenceKey {
    struct Value {
        var content: Anchor<CGRect>?
        var choices: [Data: Anchor<CGRect>] = [:]
        var groupBodies: [BookTagCategory: Anchor<CGRect>] = [:]
        var headers: [BookTagCategory: Anchor<CGRect>] = [:]
    }

    static var defaultValue: Value { Value() }
    static func reduce(value: inout Value, nextValue: () -> Value) {
        let next = nextValue()
        value.content = next.content ?? value.content
        value.choices.merge(next.choices) { _, new in new }
        value.groupBodies.merge(next.groupBodies) { _, new in new }
        value.headers.merge(next.headers) { _, new in new }
    }
}

private struct BookTagWrapProbe: View {
    let choices: [BookTagChoice]
    let selected: Set<Data>
    let onFit: (Int) -> Void

    private struct Measurement: Equatable {
        let ids: [Data]
        let count: Int
    }

    var body: some View {
        BookTagFlow {
            ForEach(choices) { choice in
                BookTagOptionToggle(name: choice.name, isOn: .constant(selected.contains(choice.id)))
                    .anchorPreference(key: BookTagChipBounds.self, value: .bounds) { [$0] }
            }
        }
        .overlayPreferenceValue(BookTagChipBounds.self) { anchors in
            GeometryReader { proxy in
                if !anchors.isEmpty {
                    let positions = anchors.map { proxy[$0].minY }
                    Color.clear.onChange(of: Measurement(ids: choices.map(\.id), count: prefixFitting(positions)), initial: true) {
                        _, result in onFit(result.count)
                    }
                }
            }
        }
        .hidden()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func prefixFitting(_ positions: [CGFloat]) -> Int {
        var row = 0
        var previous: CGFloat?
        for (index, y) in positions.enumerated() where y != previous {
            row += 1
            if row > 2 { return index }
            previous = y
        }
        return positions.count
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

private struct BookTagOptionToggle: View {
    let name: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: name).fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .frame(minHeight: LayoutTokens.hit)
    }
}

/// Read-only summary in the metadata form.
struct BookTagSummaryCapsule: View {
    let name: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(verbatim: name)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .font(.subheadline)
            .foregroundStyle(Color(uiColor: theme.accent))
            .padding(.vertical, LayoutTokens.compact / 2)
            .padding(.horizontal, LayoutTokens.control)
            .background(Color(uiColor: theme.accentSurface), in: .capsule)
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
