import MoonreadDesign
import MoonreadData
import MoonreadCoreBindings
import SwiftUI
import UIKit

enum BookSearchEditorRoute: Hashable {
    case group(UUID), rule(parent: UUID, node: BookSearchNode)
}
public struct BookSearchEditor: View {
    let source: BookSearchEditorSource
    let termIsEmpty: () -> Bool
    let apply: (BookSearchConfiguration) -> Void
    @Bindable var draft: BookSearchDraft
    let savedConfiguration: BookSearchConfiguration?
    public init(source: BookSearchEditorSource, draft: BookSearchDraft, savedConfiguration: BookSearchConfiguration?,
                termIsEmpty: @escaping () -> Bool, apply: @escaping (BookSearchConfiguration) -> Void) {
        self.source = source; self.draft = draft; self.savedConfiguration = savedConfiguration
        self.termIsEmpty = termIsEmpty; self.apply = apply
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var discard = false
    @State private var path: [BookSearchEditorRoute] = []
    public var body: some View {
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
            .underNavigationBar()
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
                    apply(value)
                    dismiss()
                }.disabled(draft.value.validation != nil).accessibilityIdentifier("applySearchFilters")
            }
        }
    }

    @ViewBuilder private func destination(_ route: BookSearchEditorRoute) -> some View {
        switch route {
        case .group(let id):
            BookSearchGroupPage(draft: draft, id: id, shelfTitle: source.shelfTitle, navigate: { path.append($0) })
                .navigationTitle(id == draft.value.root.id ? Text("组合条件") : Text("条件组"))
        case .rule(let parent, let node):
            if node.field == .tag {
                BookSearchTagRulePage(initial: node, source: source, onChange: { draft.pendingRuleChanged = $0 },
                                      complete: { value in
                    if let value {
                        draft.save(value, parent: parent)
                    } else if draft.node(node.id) != nil {
                        draft.edit(parent) { $0.children.removeAll { $0.id == node.id } }
                    }
                    path.removeLast()
                })
            } else {
                BookSearchRulePage(draft: draft, parent: parent, initial: node, source: source, path: $path)
            }
        }
    }

    private func cancel() { if draft.changed { discard = true } else { dismiss() } }
    private var root: BookSearchNode { draft.value.root }
    private var sections: [ThemedGroupedList.Section] {
        let quick = root.supportsQuickEditing(includingExcluded: true)
        // Keep the section slots stable while UIKit updates the list's layout and snapshot.
        let conditionRows = quick ? BookSearchField.allCases.map(quickConditionRow) : []
        let showsReset = savedConfiguration.map { draft.value != $0 } ?? draft.value.booksOnly
        let resetRows: [ThemedGroupedList.Row] = showsReset ? [
            .init("resetSearchFilters", action: {
                draft.value = savedConfiguration ?? BookSearchConfiguration(root: BookSearchNode(id: draft.original.root.id))
            }) {
                BookSearchActionLabel(
                    title: savedConfiguration == nil ? "重置筛选与排序" : "恢复为已保存的条件",
                    systemImage: "arrow.counterclockwise"
                )
            }
        ] : []
        let result: [ThemedGroupedList.Section] = [
            .init(id: "conditions", title: quick ? String(localized: "筛选条件") : nil, rows: conditionRows),
            .init(id: "combination", footer: quick ? nil : root.expression(shelfTitle: source.shelfTitle), rows: [
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
        let existing = root.children.first { $0.field == field }
        if field == .status {
            return .init("quickSearchStatusRow") {
                BookSearchConditionActions(field: field, excluded: existing.map(draft.exclusion)) {
                    BookSearchStatusMenu(values: Binding(get: { statusValues }, set: setStatusValues))
                }
            }
        }

        let rowID = "quickSearch-\(field.rawValue)"
        guard let existing else {
            return .init(rowID, action: {
                path.append(.rule(parent: root.id, node: BookSearchNode(field: field)))
            }, disclosure: true) {
                BookSearchConditionSummary(title: field.title) { Text("不限") }
            }
        }
        let detail = conditionDetail(existing)
        return .init(rowID) {
            BookSearchConditionActions(field: field, excluded: draft.exclusion(of: existing)) {
                BookSearchConditionButton(action: { path.append(.rule(parent: root.id, node: existing)) }) {
                    BookSearchConditionSummary(title: field.title) { Text(detail) }
                }
                .accessibilityIdentifier(rowID)
            }
        }
    }

    private func conditionDetail(_ node: BookSearchNode) -> String {
        if node.field == .tag && (node.match == .none || node.values.count > 1) {
            return node.expression(includingExclusion: false, shelfTitle: source.shelfTitle)
        }
        return node.values.map { node.valueTitle($0, shelfTitle: source.shelfTitle) }.joined(separator: "、")
    }

    private var sortSection: ThemedGroupedList.Section {
        let sorts = draft.value.sorts
        var rows = sorts.enumerated().map { index, item in sortRow(item, index: index) }
        let available = BookSearchSortField.allCases.filter { field in
            (savedConfiguration == nil || !field.requiresSearchText) && !sorts.contains { $0.field == field }
        }
        let defaultOrder = savedConfiguration != nil
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
                if item.field == .rank && termIsEmpty() {
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
struct BookSearchActionLabel: View {
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

struct BookSearchConditionActions<Editor: View>: View {
    let field: BookSearchField
    let excluded: Binding<Bool>?
    @ViewBuilder let editor: Editor
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.theme) private var theme

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: LayoutTokens.compact))
            : AnyLayout(HStackLayout(spacing: LayoutTokens.control))
        layout {
            if let excluded {
                exclusionMenu(excluded)
            }
            editor
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }

    private func exclusionMenu(_ excluded: Binding<Bool>) -> some View {
        let isExcluded = excluded.wrappedValue
        return Menu {
            Picker("条件作用：\(field.title)", selection: excluded) {
                Text("包含").tag(false)
                Text("排除").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            ZStack(alignment: .leading) {
                // Reserve the wider label in every language and at every Dynamic Type size.
                exclusionLabel(!isExcluded).hidden()
                exclusionLabel(isExcluded)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(.rect)
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("条件作用：\(field.title)"))
        .accessibilityValue(Text(isExcluded ? "排除" : "包含"))
        .accessibilityIdentifier("searchRuleExclusion-\(field.rawValue)")
    }

    private func exclusionLabel(_ excluded: Bool) -> some View {
        HStack(spacing: 3) {
            Text(excluded ? "排除" : "包含")
                .fontWeight(excluded ? .semibold : .regular)
            Image(systemName: "chevron.up.chevron.down")
                .imageScale(.small)
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .foregroundStyle(Color(uiColor: excluded ? theme.accent : theme.secondary))
    }
}

struct BookSearchConditionButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: LayoutTokens.compact) {
                label.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

struct BookSearchConditionSummary<Detail: View>: View {
    let title: String
    @ViewBuilder let detail: Detail
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(Color(uiColor: theme.ink))
            detail.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
        }
    }
}

private struct BookSearchStatusMenu: View {
    @Binding var values: [BookSearchValue]

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
            BookSearchConditionSummary(title: BookSearchField.status.title) {
                HStack(spacing: LayoutTokens.compact) {
                    Text(summary)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
