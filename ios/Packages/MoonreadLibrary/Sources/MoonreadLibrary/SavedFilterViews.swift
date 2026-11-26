import MoonreadDesign
import MoonreadData
import SwiftUI

public struct SavedFilterIndexPage<Route: Hashable>: View {
    let filters: SavedFilters
    let shelfTitle: (String) -> String
    let count: (BookSearchConfiguration) async throws -> Int
    let indexRoute: Route
    let filterRoute: (UUID) -> Route
    public init(filters: SavedFilters, shelfTitle: @escaping (String) -> String,
                count: @escaping (BookSearchConfiguration) async throws -> Int, indexRoute: Route,
                filterRoute: @escaping (UUID) -> Route) {
        self.filters = filters
        self.shelfTitle = shelfTitle
        self.count = count
        self.indexRoute = indexRoute
        self.filterRoute = filterRoute
    }

    public var body: some View {
        ScrollView {
            SavedFilterSectionContent(filters: filters, onHome: false, shelfTitle: shelfTitle, count: count,
                                      indexRoute: indexRoute, filterRoute: filterRoute)
                .padding(LayoutTokens.page)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle("虚拟书架").navigationBarTitleDisplayMode(.inline)
        .overlay {
            if filters.entries.isEmpty {
                ContentUnavailableView("暂无虚拟书架", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

public struct SavedFilterSectionContent<Route: Hashable>: View {
    let filters: SavedFilters
    let shelfTitle: (String) -> String
    let count: (BookSearchConfiguration) async throws -> Int
    let indexRoute: Route
    let filterRoute: (UUID) -> Route
    let onHome: Bool
    @Environment(\.theme) private var theme
    @State private var renaming: SavedFilter?
    @State private var removing: SavedFilter?
    private var entries: [SavedFilter] { filters.entries }
    private let homeLimit = 3

    public init(filters: SavedFilters, onHome: Bool, shelfTitle: @escaping (String) -> String,
                count: @escaping (BookSearchConfiguration) async throws -> Int, indexRoute: Route,
                filterRoute: @escaping (UUID) -> Route) {
        self.filters = filters
        self.onHome = onHome
        self.shelfTitle = shelfTitle
        self.count = count
        self.indexRoute = indexRoute
        self.filterRoute = filterRoute
    }

    public var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: LayoutTokens.content) {
                if onHome {
                    HStack {
                        Text("虚拟书架").font(.headline).foregroundStyle(Color(uiColor: theme.ink))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if entries.count > homeLimit {
                            NavigationLink(value: indexRoute) {
                                HStack(spacing: 4) { Text("查看全部"); Image(systemName: "chevron.right").accessibilityHidden(true) }
                                    .font(.subheadline)
                            }.foregroundStyle(Color(uiColor: theme.accent))
                                .accessibilityIdentifier("allSavedFilters")
                        }
                    }
                }
                rows
            }
            .sheet(item: $renaming) { entry in
                SavedFilterNameSheet(request: .rename(entry), filters: filters, shelfTitle: shelfTitle, count: count) { _ in }
            }
            .alert("移除虚拟书架？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { entry in
                Button("移除", role: .destructive) { Task { await filters.change(.remove(entry.id)) } }
                Button("取消", role: .cancel) {}
            } message: { entry in
                Text("将移除「\(entry.name)」入口。小说仍保留在原来的书架。")
            }
        }
    }

    private var rows: some View {
        let summaries = entries.map { entry in
            (entry: entry, condition: entry.configuration.root.expression(shelfTitle: shelfTitle),
             order: entry.configuration.sortDescription(hasTerm: false))
        }
        let ordersByCondition = Dictionary(grouping: summaries, by: \.condition)
            .mapValues { Set($0.map(\.order)) }
        return VStack(spacing: 0) {
            ForEach(Array(summaries.prefix(onHome ? homeLimit : summaries.count).enumerated()), id: \.element.entry.id) { index, item in
                if index > 0 { Divider().overlay(Color(uiColor: theme.separator)).padding(.leading, 42) }
                NavigationLink(value: filterRoute(item.entry.id)) {
                    SavedFilterRow(name: item.entry.name, condition: item.condition, order: item.entry.configuration.root.children.isEmpty ||
                                   (ordersByCondition[item.condition]?.count ?? 0) > 1 ? item.order : nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("savedFilter-\(item.entry.id)")
                .contextMenu {
                    Button("重命名", systemImage: "pencil") { renaming = item.entry }
                    Button("移除虚拟书架", systemImage: "trash", role: .destructive) { removing = item.entry }
                }
                .accessibilityActions {
                    Button("重命名") { renaming = item.entry }
                    Button("移除虚拟书架") { removing = item.entry }
                }
            }
        }
        .padding(.horizontal, 16)
        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
    }
}

private struct SavedFilterRow: View {
    let name: String
    let condition: String
    let order: String?
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: LayoutTokens.content) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.title2)
                .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.body.weight(.semibold)).foregroundStyle(Color(uiColor: theme.ink))
                Text(condition)
                if let order { Text("排序 · \(order)") }
            }
            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
        }
        .frame(minHeight: 44).padding(.vertical, LayoutTokens.compact)
        .contentShape(.rect).accessibilityElement(children: .combine)
    }
}

enum SavedFilterNameRequest: Identifiable {
    case save(BookSearchConfiguration, term: String, searchCount: Int)
    case rename(SavedFilter)

    var id: String {
        switch self {
        case .save: "create"
        case .rename(let entry): entry.id.uuidString
        }
    }
}

struct SavedFilterNameSheet: View {
    let request: SavedFilterNameRequest
    let filters: SavedFilters
    let shelfTitle: (String) -> String
    let count: (BookSearchConfiguration) async throws -> Int
    let saved: (UUID) -> Void
    @State private var name: String
    @State private var saving = false
    @State private var shelfCount: Int?
    @State private var countFailed = false
    @State private var countRetry = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(request: SavedFilterNameRequest, filters: SavedFilters, shelfTitle: @escaping (String) -> String,
         count: @escaping (BookSearchConfiguration) async throws -> Int, saved: @escaping (UUID) -> Void) {
        self.request = request
        self.filters = filters
        self.shelfTitle = shelfTitle
        self.count = count
        self.saved = saved
        if case .rename(let entry) = request { _name = State(initialValue: entry.name) }
        else { _name = State(initialValue: "") }
    }

    private var title: LocalizedStringKey {
        if case .rename = request { "重命名虚拟书架" } else { "保存为虚拟书架" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    nameSection
                    if case .save(let configuration, let term, let searchCount) = request {
                        rulesSection(configuration, term: term, searchCount: searchCount)
                        BookSearchSortCard(sorts: configuration.forVirtualShelf.sorts)
                    }
                }
                .padding(.horizontal, LayoutTokens.page)
                .padding(.vertical, LayoutTokens.content)
            }
            .themedPage()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SystemToolbarButton("取消", role: .cancel) { dismiss() }
                        .disabled(saving).accessibilityIdentifier("cancelSavedFilter")
                }
                ToolbarItem(placement: .confirmationAction) {
                    SystemToolbarButton("保存", role: .confirm) { save() }
                        .disabled(!canSave).accessibilityIdentifier("commitSavedFilter")
                }
            }
        }
        .presentationSizing(.form)
        .interactiveDismissDisabled(saving)
        .task(id: countRetry) {
            guard case .save(let configuration, let term, _) = request, !term.isEmpty else { return }
            do {
                let result = try await count(configuration)
                if !Task.isCancelled { shelfCount = result }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { countFailed = true }
            }
        }
        .alert("暂时无法完成", isPresented: Binding(get: { filters.error != nil }, set: { if !$0 { filters.error = nil } })) {
            Button("知道了", role: .cancel) { filters.error = nil }
        } message: { Text(filters.error ?? "") }
    }

    private var cleanedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !cleanedName.isEmpty && !saving && !filters.saving && filters.snapshot != nil }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            BookSearchSummaryTitle(title: "书架名称")
            TextField("书架名称", text: $name, prompt: Text("输入名称"))
                .keyboardInputRegion()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { save() }
                .padding(LayoutTokens.control)
                .frame(minHeight: LayoutTokens.hit)
                .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: LayoutTokens.inputRadius)
                        .strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border)
                        .allowsHitTesting(false)
                }
                .accessibilityIdentifier("savedFilterName")
        }
    }

    private func rulesSection(_ configuration: BookSearchConfiguration, term: String, searchCount: Int) -> some View {
        let count = term.isEmpty ? searchCount : shelfCount
        return BookSearchRuleCard(root: configuration.root, title: "收录规则", shelfTitle: shelfTitle) {
            countStatus(count)
        } footer: {
            if !term.isEmpty {
                Text("本次搜索匹配 \(searchCount) 本。搜索文字不会保存到书架。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }

    private func countStatus(_ count: Int?) -> some View {
        Group {
            if let count {
                Text("当前 \(count) 本").monospacedDigit()
                    .accessibilityIdentifier("savedFilterRuleCount")
            } else if countFailed {
                HStack(spacing: LayoutTokens.compact) {
                    Text("本数暂缺")
                    Button("重试") { countFailed = false; countRetry += 1 }
                        .buttonStyle(.borderless).foregroundStyle(Color(uiColor: theme.accent))
                }
            } else {
                InlineTaskProgress(title: Text("正在统计…"))
            }
        }
        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }

    private func save() {
        guard canSave else { return }
        let change: SavedFilterChange
        let created: UUID?
        switch request {
        case .save(let configuration, _, _):
            let entry = SavedFilter(id: UUID(), name: cleanedName, configuration: configuration)
            change = .create(entry)
            created = entry.id
        case .rename(let entry):
            change = .rename(entry.id, cleanedName)
            created = nil
        }
        saving = true
        Task {
            let success = await filters.change(change)
            saving = false
            guard success else { return }
            if let created { saved(created) }
            dismiss()
        }
    }
}
