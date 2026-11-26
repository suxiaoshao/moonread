import MoonreadDesign
import MoonreadSearchText
import MoonreadData
import MoonreadCoreBindings
import Combine
import SwiftUI

struct BookSearchGroupPage: View {
    @Bindable var draft: BookSearchDraft
    let id: UUID
    let shelfTitle: (String) -> String
    let navigate: (BookSearchEditorRoute) -> Void
    @Environment(\.theme) private var theme
    @State private var deleting: [UUID] = []
    private var node: BookSearchNode { draft.node(id) ?? BookSearchNode(id: id) }
    private var deletionCount: Int {
        func count(_ node: BookSearchNode) -> Int { node.field == nil ? node.children.reduce(0) { $0 + count($1) } : 1 }
        return node.children.filter { deleting.contains($0.id) }.reduce(0) { $0 + count($1) }
    }
    var body: some View {
        ThemedGroupedList(sections: groupSections, theme: theme)
        .underNavigationBar()
        .themedPage()
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
        let rows = node.children.map(conditionRow)
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

    private func conditionRow(_ child: BookSearchNode) -> ThemedGroupedList.Row {
        let actions: [ThemedGroupedList.Action] = [
            .init(title: String(localized: "删除"), destructive: true, perform: {
                if child.field == nil { deleting = [child.id] }
                else { draft.edit(id) { $0.children.removeAll { $0.id == child.id } } }
            })
        ]
        if let field = child.field {
            return .init(child.id.uuidString, actions: actions) {
                BookSearchConditionActions(field: field, excluded: draft.exclusion(of: child)) {
                    BookSearchConditionButton(action: { navigate(.rule(parent: id, node: child)) }) {
                        conditionLabel(child, includingExclusion: false)
                    }
                    .accessibilityIdentifier(child.id.uuidString)
                }
            }
        }
        return .init(child.id.uuidString, action: { navigate(.group(child.id)) }, disclosure: true, actions: actions) {
            conditionLabel(child, includingExclusion: true).padding(.vertical, 4)
        }
    }

    private func conditionLabel(_ child: BookSearchNode, includingExclusion: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(child.expression(includingExclusion: includingExclusion, shelfTitle: shelfTitle))
            if let error = child.validation() {
                Text(error).font(.caption).foregroundStyle(Color(uiColor: theme.destructive))
            }
        }
    }
}
struct BookSearchRulePage: View {
    let draft: BookSearchDraft
    let parent: UUID
    let initial: BookSearchNode
    let source: BookSearchEditorSource
    @Binding var path: [BookSearchEditorRoute]
    @State private var node: BookSearchNode
    @State private var query = ""
    @State private var selectedOnly = false
    @State private var options: LibraryMetadataOptions?
    @State private var error: String?
    @State private var loading = false
    @State private var retry = 0
    @Environment(\.theme) private var theme
    init(draft: BookSearchDraft, parent: UUID, initial: BookSearchNode, source: BookSearchEditorSource, path: Binding<[BookSearchEditorRoute]>) {
        self.draft = draft; self.parent = parent; self.initial = initial; self.source = source; _path = path; _node = State(initialValue: initial)
    }
    private var field: BookSearchField { node.field ?? .status }
    private var available: [BookSearchValue] {
        switch field {
        case .status: BookSearchStatus.allCases.map { .text($0.rawValue) }
        case .tag: []
        case .author: (options?.authors ?? []).map(BookSearchValue.text)
        case .shelf: LibraryQueryRules.filterShelves(source.shelves()).map { .text($0.id) }
        }
    }
    private var concreteValues: [BookSearchValue] {
        available + node.values.filter { !available.contains($0) }
    }
    private var choices: [BookSearchValue] {
        concreteValues.filter { value in
            (!selectedOnly || node.values.contains(value))
                && LibraryQueryRules.selectionMatches(node.valueTitle(value, shelfTitle: source.shelfTitle), query: query)
        }
    }
    private var canLimitChoices: Bool {
        concreteValues.count > 1 && !node.values.isEmpty
    }
    private var removalTitle: LocalizedStringKey? {
        switch field {
        case .author: "移除作者条件"
        case .shelf: "移除书架条件"
        case .status, .tag: nil
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
            } else if loading || (options == nil && field == .author) {
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
        .onReceive(source.accountChanges) { _ in
            options = nil; retry += 1
        }
        .task(id: retry) {
            guard field == .author else { return }
            let request = retry
            loading = true; error = nil
            defer { if request == retry { loading = false } }
            do {
                let updates = try await source.metadataOptions()
                for try await value in updates {
                    guard request == retry, !Task.isCancelled else { return }
                    options = value
                    loading = false
                }
            } catch is CancellationError { }
            catch { if request == retry, !Task.isCancelled { self.error = source.describeError(error) } }
        }
    }

    private var optionList: some View {
        List {
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
            if concreteValues.isEmpty && !isExisting {
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
                    if field == .shelf, case .text(let id) = value, let shelf = source.shelves().first(where: { $0.id == id }) {
                        BookSearchShelfOptionLabel(shelf: shelf)
                    } else {
                        Text(node.valueTitle(value, shelfTitle: source.shelfTitle))
                            .foregroundStyle(Color(uiColor: theme.ink))
                    }
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

public struct BookSearchShelfOptionLabel: View {
    let shelf: LibraryShelf
    var showsLocation: Bool
    var loadParent: () async -> String?

    public init(shelf: LibraryShelf, showsLocation: Bool = false, loadParent: @escaping () async -> String? = { nil }) {
        self.shelf = shelf; self.showsLocation = showsLocation; self.loadParent = loadParent
    }
    @Environment(\.theme) private var theme
    @State private var parentLocation: String?

    public var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: LibraryQueryRules.filterShelfName(shelf)).foregroundStyle(Color(uiColor: theme.ink))
            if showsLocation {
                Text(parentLocation ?? locationKind).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
        .task(id: shelf.id) {
            guard showsLocation, !shelf.builtin else { return }
            parentLocation = await loadParent()
        }
    }

    private var locationKind: String {
        if shelf.location == "icloud" { return "iCloud Drive" }
        return shelf.builtin ? String(localized: "本机") : String(localized: "文件夹")
    }
}
