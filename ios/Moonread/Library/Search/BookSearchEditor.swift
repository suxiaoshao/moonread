import Combine
import SwiftUI
import UIKit

/// One in-memory transaction. Nested pages edit this draft, never the live search.
@MainActor @Observable final class BookSearchDraft: Identifiable {
    let id = UUID()
    let original: BookSearchConfiguration
    var value: BookSearchConfiguration
    var pendingRuleChanged = false

    private struct PendingGroup {
        let parent: UUID
        var node: BookSearchNode
    }
    private var pendingGroups: [UUID: PendingGroup] = [:]
    init(_ value: BookSearchConfiguration) { original = value; self.value = value }
    var changed: Bool { value != original || pendingRuleChanged }
    func node(_ id: UUID) -> BookSearchNode? {
        pendingGroups[id]?.node ?? find(value.root, id)
    }

    func beginGroup(parent: UUID) -> UUID {
        let node = BookSearchNode()
        pendingGroups[node.id] = PendingGroup(parent: parent, node: node)
        return node.id
    }

    func keepPendingGroups(_ ids: Set<UUID>) {
        pendingGroups = pendingGroups.filter { ids.contains($0.key) }
    }
    private func find(_ node: BookSearchNode, _ id: UUID) -> BookSearchNode? {
        if node.id == id { return node }
        for child in node.children { if let found = find(child, id) { return found } }
        return nil
    }
    func edit(_ id: UUID, _ mutation: (inout BookSearchNode) -> Void) {
        if var pending = pendingGroups[id] {
            mutation(&pending.node)
            pendingGroups[id] = pending
        } else {
            edit(&value.root, id: id, mutation)
        }
    }
    private func edit(_ node: inout BookSearchNode, id: UUID, _ mutation: (inout BookSearchNode) -> Void) {
        if node.id == id { mutation(&node); return }
        for index in node.children.indices { edit(&node.children[index], id: id, mutation) }
    }
    func save(_ node: BookSearchNode, parent: UUID) {
        edit(parent) { group in
            if let i = group.children.firstIndex(where: { $0.id == node.id }) { group.children[i] = node }
            else { group.children.append(node) }
        }
        // A first valid condition also completes any pending ancestor groups.
        if let pending = pendingGroups[parent], pending.node.validation() == nil {
            save(pending.node, parent: pending.parent)
            pendingGroups.removeValue(forKey: parent)
        }
    }
}
private enum BookSearchEditorRoute: Hashable {
    case group(UUID), rule(parent: UUID, node: BookSearchNode)
}
struct BookSearchEditor: View {
    let search: AppSearch
    let model: LibraryModel
    @Bindable var draft: BookSearchDraft
    var virtualShelf = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var discard = false
    @State private var path: [BookSearchEditorRoute] = []
    var body: some View {
        NavigationStack(path: $path) { mainPage }
            .onChange(of: path) { _, routes in
                let groupIDs = routes.compactMap { route in
                    if case .group(let id) = route { return id }
                    return nil
                }
                draft.keepPendingGroups(Set(groupIDs))
            }
            .tint(Color(uiColor: theme.accent))
            .presentationSizing(.form)
            .presentationDetents([.large])
            .background(BookSearchDismissalGuard(changed: draft.changed) { discard = true })
            .alert("放弃筛选更改？", isPresented: $discard) {
                Button("放弃更改", role: .destructive) { dismiss() }
                Button("取消", role: .cancel) {}
            }
    }

    private var mainPage: some View {
        ThemedGroupedList(sections: sections, theme: theme, reordered: reorder)
            .themedPage()
            .navigationTitle("筛选与排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { rootActions }
            .navigationDestination(for: BookSearchEditorRoute.self) { route in destination(route) }
    }

    @ToolbarContentBuilder private var rootActions: some ToolbarContent {
        if path.isEmpty {
            ToolbarItem(placement: .cancellationAction) {
                SystemToolbarButton("取消", role: .cancel) { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                SystemToolbarButton("应用", role: .confirm) {
                    var value = draft.value
                    if value.root.children.isEmpty { value.root = BookSearchNode(id: value.root.id) }
                    search.configuration = value
                    dismiss()
                }.disabled(draft.value.validation != nil).accessibilityIdentifier("applySearchFilters")
            }
        }
    }

    @ViewBuilder private func destination(_ route: BookSearchEditorRoute) -> some View {
        switch route {
        case .group(let id):
            BookSearchGroupPage(draft: draft, id: id, model: model, navigate: { path.append($0) })
                .navigationTitle(id == draft.value.root.id ? Text("组合条件") : Text("条件组"))
        case .rule(let parent, let node):
            BookSearchRulePage(draft: draft, parent: parent, initial: node, model: model, path: $path)
        }
    }

    private func cancel() { if draft.changed { discard = true } else { dismiss() } }
    private var root: BookSearchNode { draft.value.root }
    private var sections: [ThemedGroupedList.Section] {
        let quick = root.supportsQuickEditing
        // Keep the section slots stable while UIKit updates the list's layout and snapshot.
        let conditionRows = quick ? BookSearchField.allCases.map(quickConditionRow) : []
        let resetRows: [ThemedGroupedList.Row] = draft.value.booksOnly ? [
            .init("resetSearchFilters", action: {
                draft.value = BookSearchConfiguration(root: BookSearchNode(id: draft.original.root.id))
            }) {
                BookSearchActionLabel(title: "重置筛选与排序", systemImage: "arrow.counterclockwise")
            }
        ] : []
        let result: [ThemedGroupedList.Section] = [
            .init(id: "conditions", title: quick ? String(localized: "筛选条件") : nil, rows: conditionRows),
            .init(id: "combination", footer: quick ? nil : root.expression(shelfTitle: model.shelfTitle), rows: [
                .init("openSearchCombination", action: { path.append(.group(root.id)) }, disclosure: true) {
                    Text(quick ? "组合条件" : "编辑组合条件")
                }
            ]),
            sortSection,
            .init(id: "reset", footer: draft.value.validation, rows: resetRows)
        ]
        return result
    }

    private func quickConditionRow(_ field: BookSearchField) -> ThemedGroupedList.Row {
        if field == .status {
            return .init("quickSearchStatusRow") {
                BookSearchStatusMenu(values: Binding(get: { statusValues }, set: setStatusValues))
            }
        }

        let existing = root.children.first { $0.field == field }
        let detail = existing.map { node in
            node.values.map { node.valueTitle($0, shelfTitle: model.shelfTitle) }.joined(separator: "、")
        } ?? String(localized: "不限")
        return .init("quickSearch-\(field.rawValue)", action: {
            path.append(.rule(parent: root.id, node: existing ?? BookSearchNode(field: field)))
        }, disclosure: true) {
            HStack {
                Text(field.title).layoutPriority(1)
                Spacer()
                Text(detail).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }

    private var sortSection: ThemedGroupedList.Section {
        let sorts = draft.value.sorts
        var rows = sorts.enumerated().map { index, item in sortRow(item, index: index) }
        let available = BookSearchSortField.allCases.filter { field in
            (!virtualShelf || !field.requiresSearchText) && !sorts.contains { $0.field == field }
        }
        let defaultOrder = virtualShelf
            ? String(localized: "默认：最近阅读 → 自然名称")
            : String(localized: "默认：匹配程度 → 最近阅读 → 自然名称")
        if !available.isEmpty {
            rows.append(.init("addSearchSortRow") {
                Menu {
                    ForEach(available) { field in
                        Button(field.title) { draft.value.sorts.append(.init(field: field, descending: field == .recent)) }
                    }
                } label: {
                    BookSearchActionLabel(title: "添加排序", systemImage: "plus")
                }.accessibilityIdentifier("addSearchSort")
            })
        }
        return .init(id: "sorts", title: String(localized: "排序"),
                     footer: sorts.isEmpty ? defaultOrder : nil,
                     rows: rows)
    }

    private func sortRow(_ item: BookSearchSort, index: Int) -> ThemedGroupedList.Row {
        .init(item.field.rawValue, actions: [
            .init(title: String(localized: "删除"), destructive: true,
                  perform: { draft.value.sorts.removeAll { $0.field == item.field } })
        ], reorderable: true) {
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                HStack {
                    Text(item.field.title)
                        .accessibilityLabel(Text("排序 \(index + 1)，\(item.field.title)"))
                    Spacer()
                    Picker("排序方向", selection: Binding(get: {
                        draft.value.sorts.first(where: { $0.field == item.field })?.descending ?? item.descending
                    }, set: { direction in
                        if let i = draft.value.sorts.firstIndex(where: { $0.field == item.field }) {
                            draft.value.sorts[i].descending = direction
                        }
                    })) {
                        Text("升序").tag(false)
                        Text("降序").tag(true)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                if item.field == .rank && search.term.isEmpty {
                    Text("无文字时跳过").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: Text("上移")) { move(item.field, by: -1) }
            .accessibilityAction(named: Text("下移")) { move(item.field, by: 1) }
        }
    }

    private var statusValues: [BookSearchValue] {
        root.children.first { $0.field == .status }?.values ?? []
    }

    private func setStatusValues(_ values: [BookSearchValue]) {
        var node = root.children.first { $0.field == .status } ?? BookSearchNode(field: .status)
        if values.isEmpty {
            let removing = node.id
            draft.edit(root.id) { $0.children.removeAll { $0.id == removing } }
        } else {
            node.values = values
            draft.save(node, parent: root.id)
        }
    }

    private func reorder(_ ids: [String]) {
        let keys = Dictionary(uniqueKeysWithValues: draft.value.sorts.map { ($0.field.rawValue, $0) })
        draft.value.sorts = ids.compactMap { keys[$0] }
    }

    private func move(_ field: BookSearchSortField, by offset: Int) {
        guard let i = draft.value.sorts.firstIndex(where: { $0.field == field }), draft.value.sorts.indices.contains(i + offset) else { return }
        draft.value.sorts.swapAt(i, i + offset)
    }
}
private struct BookSearchActionLabel: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Environment(\.theme) private var theme

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(Color(uiColor: theme.accent))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
    }
}

private struct BookSearchStatusMenu: View {
    @Binding var values: [BookSearchValue]
    @Environment(\.theme) private var theme

    private let displayOrder: [BookSearchStatus] = [.unread, .reading, .finished, .paused]

    var body: some View {
        let selected = displayOrder.filter { values.contains(.text($0.rawValue)) }
        let summary = selected.isEmpty ? String(localized: "不限") : ListFormatter.localizedString(byJoining: selected.map(\.title))
        Menu {
            Button("不限") { values = [] }
            ForEach(displayOrder, id: \.self) { status in
                Toggle(status.title, isOn: selection(for: status))
                    .menuActionDismissBehavior(.disabled)
                    .accessibilityIdentifier("quickSearchStatus-\(status.rawValue)")
            }
        } label: {
            HStack {
                Text("阅读状态").foregroundStyle(Color(uiColor: theme.ink))
                Spacer()
                Text(summary)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color(uiColor: theme.secondary))
            .contentShape(.rect)
        }
        .accessibilityLabel(Text("阅读状态"))
        .accessibilityValue(Text(summary))
        .accessibilityIdentifier("quickSearchStatusMenu")
    }

    private func selection(for status: BookSearchStatus) -> Binding<Bool> {
        let value = BookSearchValue.text(status.rawValue)
        return Binding {
            values.contains(value)
        } set: { isSelected in
            if isSelected {
                if !values.contains(value) { values.append(value) }
            } else {
                values.removeAll { $0 == value }
            }
        }
    }
}

private struct BookSearchGroupPage: View {
    @Bindable var draft: BookSearchDraft
    let id: UUID
    let model: LibraryModel
    let navigate: (BookSearchEditorRoute) -> Void
    @Environment(\.theme) private var theme
    @State private var deleting: [UUID] = []
    private var node: BookSearchNode { draft.node(id) ?? BookSearchNode(id: id) }
    private var deletionCount: Int {
        func count(_ node: BookSearchNode) -> Int { node.field == nil ? node.children.reduce(0) { $0 + count($1) } : 1 }
        return node.children.filter { deleting.contains($0.id) }.reduce(0) { $0 + count($1) }
    }
    var body: some View {
        ThemedGroupedList(sections: groupSections, theme: theme).themedPage()
        .navigationBarTitleDisplayMode(.inline)
        .alert("删除条件及其子条件？", isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("删除条件", role: .destructive) { let ids = Set(deleting); draft.edit(id) { $0.children.removeAll { ids.contains($0.id) } }; deleting = [] }
            Button("取消", role: .cancel) { deleting = [] }
        } message: { Text("将删除 \(deletionCount) 条条件（含子条件），仅修改当前草稿。") }
    }
    private var groupSections: [ThemedGroupedList.Section] {
        let options = ThemedGroupedList.Section(id: "options", footer: node.excluded ? String(localized: "排除：满足本组的小说不显示") : nil, rows: [
            .init("relation") {
                Picker("匹配关系", selection: Binding(get: { node.group }, set: { value in draft.edit(id) { $0.group = value } })) {
                    ForEach(BookSearchGroup.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            },
            .init("exclude") {
                Toggle("排除本组", isOn: Binding(get: { node.excluded }, set: { value in draft.edit(id) { $0.excluded = value } }))
            }
        ])
        let rows: [ThemedGroupedList.Row] = node.children.map { child in
            .init(child.id.uuidString, action: {
                navigate(child.field == nil ? .group(child.id) : .rule(parent: id, node: child))
            }, disclosure: true, actions: [
                .init(title: String(localized: "删除"), destructive: true, perform: {
                    if child.field == nil { deleting = [child.id] }
                    else { draft.edit(id) { $0.children.removeAll { $0.id == child.id } } }
                })
            ]) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.expression(shelfTitle: model.shelfTitle))
                    if let error = child.validation() { Text(error).font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                }.padding(.vertical, 4)
            }
        }
        var additions: [ThemedGroupedList.Row] = BookSearchField.allCases.map { field in
            .init("addSearchCondition-\(field.rawValue)", action: { navigate(.rule(parent: id, node: BookSearchNode(field: field))) },
                  disclosure: true) { Text(field.title) }
        }
        additions.append(.init("addGroup", action: {
            navigate(.group(draft.beginGroup(parent: id)))
        }) { BookSearchActionLabel(title: "添加子组", systemImage: "plus") })
        var sections = [options]
        if !rows.isEmpty {
            sections.append(.init(id: "children", title: String(localized: "本组条件"), rows: rows))
        }
        sections.append(.init(id: "additions", title: String(localized: "添加条件"),
                              footer: node.children.isEmpty ? node.validation(isRoot: id == draft.value.root.id) : nil,
                              rows: additions))
        return sections
    }

}
private struct BookSearchRulePage: View {
    let draft: BookSearchDraft
    let parent: UUID
    let initial: BookSearchNode
    let model: LibraryModel
    @Binding var path: [BookSearchEditorRoute]
    @State private var node: BookSearchNode
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var options: BookFilterOptions?
    @State private var error: String?
    @State private var loading = false
    @State private var retry = 0
    @Environment(\.theme) private var theme
    init(draft: BookSearchDraft, parent: UUID, initial: BookSearchNode, model: LibraryModel, path: Binding<[BookSearchEditorRoute]>) {
        self.draft = draft; self.parent = parent; self.initial = initial; self.model = model; _path = path; _node = State(initialValue: initial)
    }
    private var field: BookSearchField { node.field ?? .status }
    private var available: [BookSearchValue] {
        switch field {
        case .status: BookSearchStatus.allCases.map { .text($0.rawValue) }
        case .tag: [.untagged] + (options?.tags ?? []).map(BookSearchValue.text)
        case .author: (options?.authors ?? []).map(BookSearchValue.text)
        case .shelf: model.shelves.filter { $0.error == nil }.map { .text($0.id) }
        }
    }
    private var concreteValues: [BookSearchValue] {
        let values = available + node.values.filter { !available.contains($0) }
        return values.filter { $0 != .untagged }
    }
    private var choices: [BookSearchValue] {
        concreteValues.filter { value in
            (!selectedOnly || node.values.contains(value))
                && LibraryQueryRules.selectionMatches(node.valueTitle(value, shelfTitle: model.shelfTitle), query: query)
        }
    }
    private var hasTagOptions: Bool { field == .tag && !concreteValues.isEmpty }
    private var canLimitChoices: Bool {
        concreteValues.count > 1 && node.values.contains { $0 != .untagged }
    }
    private var tagConflict: String? {
        guard hasTagOptions, node.match == .all, node.values.contains(.untagged) else { return nil }
        return node.validation()
    }
    private var tagExplanation: LocalizedStringKey {
        switch node.match {
        case .any: "显示带有任一所选标签的小说"
        case .all: "显示同时带有全部所选标签的小说"
        case .none: "不显示带有所选标签的小说"
        }
    }
    private var removalTitle: LocalizedStringKey? {
        switch field {
        case .tag: "移除标签条件"
        case .author: "移除作者条件"
        case .shelf: "移除书架条件"
        case .status: nil
        }
    }
    private var isExisting: Bool { draft.node(initial.id) != nil }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("无法加载选项", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { retry += 1 }
                }
            } else if loading || (options == nil && (field == .tag || field == .author)) {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                optionList
            }
        }
        .themedPage()
        .navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: node) { _, value in draft.pendingRuleChanged = value != initial }
        .onDisappear { draft.pendingRuleChanged = false }
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            SystemToolbarButton("完成", role: .confirm) {
                draft.save(node, parent: parent)
                if !path.isEmpty { path.removeLast() }
            }.disabled(node.validation() != nil)
                .accessibilityIdentifier("saveSearchCondition")
        } }
        .onReceive(NotificationCenter.default.publisher(for: .readingContinuationInvalidated, object: AppDataService.shared)
            .receive(on: DispatchQueue.main)) { _ in
            options = nil; retry += 1
        }
        .task(id: retry) {
            guard field == .tag || field == .author else { return }
            let request = retry
            loading = true; error = nil
            defer { if request == retry { loading = false } }
            do {
                let updates = try await AppDataService.shared.metadataOptionsUpdates(shelfID: nil)
                for try await value in updates {
                    guard request == retry, !Task.isCancelled else { return }
                    options = value
                    loading = false
                }
            } catch is CancellationError { }
            catch { if request == retry, !Task.isCancelled { self.error = ReaderMessages.error(error) } }
        }
    }

    private var optionList: some View {
        List {
            if hasTagOptions {
                Section {
                    Picker("标签关系", selection: $node.match) {
                        ForEach([BookSearchMatch.any, .all, .none], id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color(uiColor: theme.surface))
                } footer: {
                    if let tagConflict {
                        Text(tagConflict).foregroundStyle(Color(uiColor: theme.destructive))
                    } else {
                        Text(tagExplanation)
                    }
                }
            }
            if !concreteValues.isEmpty {
                Section {
                    ForEach(choices, id: \.self) { choiceRow($0) }
                } header: {
                    if !node.values.isEmpty {
                        HStack {
                            Text("已选 \(node.values.count) 项")
                            Spacer()
                            if canLimitChoices {
                                Button(selectedOnly ? "显示全部" : "只看已选") { selectedOnly.toggle() }
                            }
                        }
                    }
                } footer: {
                    if choices.isEmpty && !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
            if field == .tag {
                Section {
                    choiceRow(.untagged)
                } footer: {
                    Text(hasTagOptions ? "没有任何标签的小说" : "书库中还没有标签，只能筛选没有标签的小说。")
                }
            }
            if isExisting, let removalTitle {
                Section {
                    Button(removalTitle, role: .destructive) {
                        draft.edit(parent) { $0.children.removeAll { $0.id == initial.id } }
                        path.removeLast()
                    }
                    .listRowBackground(Color(uiColor: theme.surface))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .overlay {
            if field != .tag && concreteValues.isEmpty && !isExisting {
                ContentUnavailableView("暂无可选项", systemImage: "line.3.horizontal.decrease")
            }
        }
        .onChange(of: canLimitChoices) { _, canLimit in
            if !canLimit { selectedOnly = false }
        }
        .modifier(BookSearchOptionSearch(enabled: !concreteValues.isEmpty && field != .status, query: $query))
    }

    private func choiceRow(_ value: BookSearchValue) -> some View {
        let selected = node.values.contains(value)
        return Button {
            if selected { node.values.removeAll { $0 == value } } else { node.values.append(value) }
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(node.valueTitle(value, shelfTitle: model.shelfTitle))
                        .foregroundStyle(Color(uiColor: theme.ink))
                    if !available.contains(value) {
                        Text("当前不可用，保留已选值").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
            }
            .contentShape(.rect)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .listRowBackground(Color(uiColor: theme.surface))
        .listRowSeparatorTint(Color(uiColor: theme.separator))
    }
}

private struct BookSearchOptionSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: "搜索选项")
        } else {
            content
        }
    }
}

/// SwiftUI exposes disabling interactive dismissal but not the attempted-dismiss
/// callback. Use UIKit's public sheet delegate only for this draft confirmation.
private struct BookSearchDismissalGuard: UIViewControllerRepresentable {
    let changed: Bool
    let attempted: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.changed = changed; controller.attempted = attempted
        controller.attach()
    }
    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var changed = false
        var attempted: () -> Void = {}
        weak var previous: (any UIAdaptivePresentationControllerDelegate)?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        func attach() {
            var candidate: UIViewController? = self
            while let current = candidate {
                if current.presentingViewController?.presentedViewController === current {
                    if current.isModalInPresentation != changed { current.isModalInPresentation = changed }
                    if let presentation = current.presentationController, presentation.delegate !== self {
                        previous = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                candidate = current.parent
            }
        }
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !changed && (previous?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if changed { attempted() } else { previous?.presentationControllerDidAttemptToDismiss?(presentationController) }
        }
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previous?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previous?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
