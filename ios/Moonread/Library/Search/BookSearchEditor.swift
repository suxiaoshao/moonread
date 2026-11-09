import SwiftUI
import UIKit

/// One in-memory transaction. Nested pages edit this draft, never the live search.
@MainActor @Observable final class BookSearchDraft: Identifiable {
    let id = UUID()
    let original: BookSearchConfiguration
    var value: BookSearchConfiguration
    var pendingRuleChanged = false
    init(_ value: BookSearchConfiguration) { original = value; self.value = value }
    var changed: Bool { value != original || pendingRuleChanged }
    func node(_ id: UUID) -> BookSearchNode? { find(value.root, id) }
    private func find(_ node: BookSearchNode, _ id: UUID) -> BookSearchNode? {
        if node.id == id { return node }
        for child in node.children { if let found = find(child, id) { return found } }
        return nil
    }
    func edit(_ id: UUID, _ mutation: (inout BookSearchNode) -> Void) { edit(&value.root, id: id, mutation) }
    private func edit(_ node: inout BookSearchNode, id: UUID, _ mutation: (inout BookSearchNode) -> Void) {
        if node.id == id { mutation(&node); return }
        for index in node.children.indices { edit(&node.children[index], id: id, mutation) }
    }
    func save(_ node: BookSearchNode, parent: UUID) {
        edit(parent) { group in
            if let i = group.children.firstIndex(where: { $0.id == node.id }) { group.children[i] = node }
            else { group.children.append(node) }
        }
    }
}
private enum BookSearchEditorRoute: Hashable {
    case group(UUID), fields(UUID), rule(parent: UUID, node: BookSearchNode), preview, sortFields
}
struct BookSearchEditor: View {
    let search: AppSearch
    let model: LibraryModel
    @Bindable var draft: BookSearchDraft
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var segment = 0
    @State private var discard = false
    @State private var error: String?
    @State private var path: [BookSearchEditorRoute] = []
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker("编辑内容", selection: $segment) { Text("条件").tag(0); Text("排序").tag(1) }
                    .pickerStyle(.segmented).padding()
                if segment == 0 { BookSearchGroupPage(draft: draft, id: draft.value.root.id, model: model, navigate: { path.append($0) }) }
                else { sortPage }
                if let error { Text(error).foregroundStyle(Color(uiColor: theme.destructive)).padding() }
            }
            .frame(idealWidth: 620).themedPage().navigationTitle("筛选与排序").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if path.isEmpty {
                    ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { cancel() } }
                    ToolbarItem(placement: .confirmationAction) {
                        SystemToolbarButton("应用", role: .confirm) {
                            if let validation = draft.value.validation { error = validation; segment = 0; return }
                            var value = draft.value
                            if value.root.children.isEmpty { value.root = BookSearchNode() }
                            search.configuration = value
                            dismiss()
                        }.fontWeight(.semibold).accessibilityIdentifier("applySearchFilters")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("重置筛选与排序") {
                            var reset = BookSearchConfiguration(); reset.root.id = draft.original.root.id
                            draft.value = reset; error = nil
                        }
                        Spacer()
                        NavigationLink("预览完整条件", value: BookSearchEditorRoute.preview)
                    }
                }
            }
            .navigationDestination(for: BookSearchEditorRoute.self) { route in
                switch route {
                case .group(let id): BookSearchGroupPage(draft: draft, id: id, model: model, navigate: { path.append($0) }).navigationTitle("条件组")
                case .fields(let parent):
                    List(BookSearchField.allCases) { field in
                        Button(field.title) { path.append(.rule(parent: parent, node: BookSearchNode(field: field))) }
                            .frame(minHeight: 44).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }.scrollContentBackground(.hidden).themedPage().navigationTitle("添加条件").navigationBarTitleDisplayMode(.inline)
                case .rule(let parent, let node): BookSearchRulePage(draft: draft, parent: parent, initial: node, model: model, path: $path)
                case .sortFields:
                    List {
                        ForEach(BookSearchSortField.allCases.filter { field in !draft.value.sorts.contains { $0.field == field } }) { field in
                            Button(field.title) {
                                draft.value.sorts.append(.init(field: field, descending: field == .recent))
                                path.removeLast()
                            }.frame(minHeight: 44).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                        }
                    }.scrollContentBackground(.hidden).themedPage().navigationTitle("添加排序").navigationBarTitleDisplayMode(.inline)
                case .preview:
                    ScrollView { BookSearchSummary(configuration: draft.value, term: search.term, shelfTitle: model.shelfTitle, expanded: true).padding() }
                        .themedPage().navigationTitle("预览完整条件").navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(Color(uiColor: theme.accent))
        .onChange(of: draft.value) { _, _ in error = nil }
        .presentationSizing(.form)
        .presentationDetents([.large])
        .background(BookSearchDismissalGuard(changed: draft.changed) { discard = true })
        .alert("放弃筛选更改？", isPresented: $discard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("取消", role: .cancel) {}
        }
    }
    private func cancel() { if draft.changed { discard = true } else { dismiss() } }
    private var sortPage: some View {
        ThemedGroupedList(sections: sortSections, theme: theme, reordered: { ids in
            let current = Dictionary(uniqueKeysWithValues: draft.value.sorts.map { ($0.field.rawValue, $0) })
            draft.value.sorts = ids.compactMap { current[$0] }
        })
    }
    private var sortSections: [ThemedGroupedList.Section] {
        var rows: [ThemedGroupedList.Row] = draft.value.sorts.map { item in
            .init(item.field.rawValue, actions: [
                .init(title: String(localized: "删除"), destructive: true, perform: { draft.value.sorts.removeAll { $0.field == item.field } })
            ], reorderable: true) {
                VStack(alignment: .leading) {
                    HStack {
                        Text("\((draft.value.sorts.firstIndex(where: { $0.field == item.field }) ?? 0) + 1). " + item.field.title)
                        Spacer()
                        Picker("方向", selection: Binding(get: {
                            draft.value.sorts.first(where: { $0.field == item.field })?.descending ?? item.descending
                        }, set: { direction in
                            if let i = draft.value.sorts.firstIndex(where: { $0.field == item.field }) { draft.value.sorts[i].descending = direction }
                        })) { Text("升序").tag(false); Text("降序").tag(true) }.pickerStyle(.menu)
                    }
                    if item.field == .rank && search.term.isEmpty { Text("无文字时跳过").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                .accessibilityAction(named: Text("上移")) { move(item.field, by: -1) }
                .accessibilityAction(named: Text("下移")) { move(item.field, by: 1) }
            }
        }
        if rows.isEmpty {
            rows.append(.init("default") { Text("默认：匹配程度 → 最近阅读 → 自然名称").foregroundStyle(Color(uiColor: theme.secondary)) })
        }
        return [
            .init(id: "sorts", footer: String(localized: "自定义顺序会替代默认匹配优先级；前一项相同时才比较下一项。缺少作者或阅读时间的小说始终排在最后。"), rows: rows),
            .init(id: "actions", rows: [
                .init("reset", action: { draft.value.sorts = [] }) { Text("恢复默认排序").foregroundStyle(Color(uiColor: theme.accent)) },
                .init("add", action: draft.value.sorts.count < BookSearchSortField.allCases.count ? { path.append(.sortFields) } : nil, disclosure: true) {
                    Text("添加排序").foregroundStyle(Color(uiColor: draft.value.sorts.count == BookSearchSortField.allCases.count ? theme.secondary : theme.ink))
                }
            ])
        ]
    }
    private func move(_ field: BookSearchSortField, by offset: Int) {
        guard let i = draft.value.sorts.firstIndex(where: { $0.field == field }), draft.value.sorts.indices.contains(i + offset) else { return }
        draft.value.sorts.swapAt(i, i + offset)
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
        var rows: [ThemedGroupedList.Row] = node.children.map { child in
            .init(child.id.uuidString, action: {
                navigate(child.field == nil ? .group(child.id) : .rule(parent: id, node: child))
            }, disclosure: true, actions: [
                .init(title: String(localized: "删除"), destructive: true, perform: { deleting = [child.id] })
            ]) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(child.summary(shelfTitle: model.shelfTitle))
                    if let error = child.validation() { Text(error).font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                }.padding(.vertical, 4)
            }
        }
        rows.append(.init("addSearchCondition", action: { navigate(.fields(id)) }, disclosure: true) { Text("添加条件") })
        rows.append(.init("addGroup", action: {
            draft.edit(id) { $0.children.append(BookSearchNode()) }
        }) { Label("添加条件组", systemImage: "rectangle.stack.badge.plus").foregroundStyle(Color(uiColor: theme.accent)) })
        return [options, .init(id: "children", footer: node.children.isEmpty ? String(localized: "添加条件，或保留空的根组以取消筛选。") : nil, rows: rows)]
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
        case .status: ["reading", "finished", "paused", "unread"].map(BookSearchValue.text)
        case .tag: [.untagged] + (options?.tags ?? []).map(BookSearchValue.text)
        case .author: (options?.authors ?? []).map(BookSearchValue.text)
        case .shelf: model.shelves.filter { $0.error == nil }.map { .text($0.id) }
        }
    }
    private var choices: [BookSearchValue] {
        let values = available + node.values.filter { !available.contains($0) }
        return values.filter { value in
            (!selectedOnly || node.values.contains(value)) && (value == .untagged || LibraryQueryRules.selectionMatches(node.valueTitle(value, shelfTitle: model.shelfTitle), query: query))
        }
    }
    var body: some View {
        List {
            Section {
                Toggle("只看已选", isOn: $selectedOnly)
                Text("已选 \(node.values.count) 项").foregroundStyle(Color(uiColor: theme.secondary))
                if field == .tag {
                    Picker("标签关系", selection: $node.match) {
                        ForEach(BookSearchMatch.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            if let error {
                Section { Text(error).foregroundStyle(Color(uiColor: theme.destructive)); Button("重试") { retry += 1 } }
                    .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            } else if loading { ProgressView().listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
            Section {
                ForEach(choices, id: \.self) { value in
                    Button {
                        if node.values.contains(value) { node.values.removeAll { $0 == value } } else { node.values.append(value) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(node.valueTitle(value, shelfTitle: model.shelfTitle)).foregroundStyle(Color(uiColor: theme.ink))
                                if !loading && error == nil && !available.contains(value) { Text("当前不可用，保留已选值").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                            }
                            Spacer()
                            if node.values.contains(value) { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
                        }.frame(minHeight: 44)
                    }.accessibilityAddTraits(node.values.contains(value) ? .isSelected : [])
                    .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            if choices.isEmpty && !loading && error == nil {
                Section { Text(query.isEmpty ? "暂无可选项" : "没有匹配的选项").foregroundStyle(Color(uiColor: theme.secondary)) }
                    .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            }
            if let validation = node.validation() { Text(validation).foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
        }
        .scrollContentBackground(.hidden).themedPage()
        .navigationTitle(field.title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索选项")
        .onChange(of: node) { _, value in draft.pendingRuleChanged = value != initial }
        .onDisappear { draft.pendingRuleChanged = false }
        .toolbar { ToolbarItem(placement: .confirmationAction) {
            SystemToolbarButton("完成", role: .confirm) {
                draft.save(node, parent: parent)
                if !path.isEmpty { path.removeLast() }
                if case .fields = path.last { path.removeLast() }
            }.disabled(node.validation() != nil)
                .accessibilityIdentifier("saveSearchCondition")
        } }
        .task(id: retry) {
            guard field == .tag || field == .author else { return }
            loading = true; error = nil
            defer { loading = false }
            do { options = try await AppDataService.shared.metadataOptions(shelfID: nil) }
            catch is CancellationError {} catch { self.error = ReaderMessages.error(error) }
        }
    }
}

struct BookSearchSummary: View {
    let configuration: BookSearchConfiguration
    let term: String
    let shelfTitle: (String) -> String
    var expanded: Bool = false
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("仅小说").font(.caption.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary))
            if !configuration.root.children.isEmpty {
                Text(configuration.root.summary(shelfTitle: shelfTitle)).fontWeight(.semibold)
                ForEach(Array(configuration.root.children.prefix(expanded ? configuration.root.children.count : 3))) { node in
                    summary(node)
                }
                if !expanded && configuration.root.children.count > 3 { Text("另有 \(configuration.root.children.count - 3) 条条件").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                if !expanded && configuration.root.hasExclusion { Text("含排除组").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            if configuration.sorts.isEmpty { Text("默认：匹配程度 → 最近阅读 → 自然名称").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
            else {
                Text(configuration.sorts.enumerated().map { i, key in
                    "\(i + 1). " + key.field.title + (key.field == .rank && term.isEmpty ? String(localized: "（无文字时跳过）") : key.descending ? " ↓" : " ↑")
                }.joined(separator: " → ")).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
    }
    private func summary(_ node: BookSearchNode) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 6) {
            Text(node.summary(shelfTitle: shelfTitle)).fixedSize(horizontal: false, vertical: true)
            if node.field == nil && expanded {
                ForEach(node.children) { summary($0) }.padding(.leading, 12)
            }
        })
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
