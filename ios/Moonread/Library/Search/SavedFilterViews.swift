import SwiftUI

struct SavedFilterIndex: View {
    let model: LibraryModel
    var body: some View {
        ScrollView {
            SavedFilterSection(model: model, onHome: false)
                .padding(LayoutTokens.page)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle("虚拟书架").navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.savedFilters.entries.isEmpty {
                ContentUnavailableView("暂无虚拟书架", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

struct SavedFilterSection: View {
    let model: LibraryModel
    let onHome: Bool
    @Environment(\.theme) private var theme
    @State private var renaming: SavedFilter?
    @State private var removing: SavedFilter?
    private var entries: [SavedFilter] { model.savedFilters.entries }
    private let homeLimit = 3

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: LayoutTokens.content) {
                if onHome {
                    HStack {
                        Text("虚拟书架").font(.headline).foregroundStyle(Color(uiColor: theme.ink))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if entries.count > homeLimit {
                            NavigationLink(value: LibraryRoute.savedFilters) {
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
                SavedFilterNameSheet(request: .rename(entry), model: model) { _ in }
            }
            .alert("移除虚拟书架？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                   presenting: removing) { entry in
                Button("移除", role: .destructive) { Task { await model.savedFilters.change(.remove(entry.id)) } }
                Button("取消", role: .cancel) {}
            } message: { entry in
                Text("将移除「\(entry.name)」入口。小说仍保留在原来的书架。")
            }
        }
    }

    private var rows: some View {
        let summaries = entries.map { entry in
            (entry: entry, condition: entry.configuration.root.expression(shelfTitle: model.shelfTitle),
             order: entry.configuration.sortDescription(hasTerm: false))
        }
        let ordersByCondition = Dictionary(grouping: summaries, by: \.condition)
            .mapValues { Set($0.map(\.order)) }
        return VStack(spacing: 0) {
            ForEach(Array(summaries.prefix(onHome ? homeLimit : summaries.count).enumerated()), id: \.element.entry.id) { index, item in
                if index > 0 { Divider().overlay(Color(uiColor: theme.separator)).padding(.leading, 42) }
                NavigationLink(value: LibraryRoute.savedFilter(item.entry.id)) {
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

struct SavedFilterDestination: View {
    let model: LibraryModel
    let id: UUID
    var host: LibraryBrowsingHost = .main
    var body: some View {
        if let entry = model.savedFilters.entries.first(where: { $0.id == id }) {
            SavedFilterPage(model: model, entry: entry, host: host).id(id)
        } else {
            ContentUnavailableView("虚拟书架已移除", systemImage: "line.3.horizontal.decrease.circle").themedPage()
        }
    }
}

private struct SavedFilterPage: View {
    let model: LibraryModel
    let entry: SavedFilter
    let host: LibraryBrowsingHost
    @State private var search: AppSearch

    init(model: LibraryModel, entry: SavedFilter, host: LibraryBrowsingHost) {
        self.model = model
        self.entry = entry
        self.host = host
        let search = AppSearch()
        search.configuration = entry.configuration
        _search = State(initialValue: search)
    }

    var body: some View {
        AppSearchView(model: model, search: search, host: host, savedFilter: entry)
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
    let model: LibraryModel
    let saved: (UUID) -> Void
    @State private var name: String
    @State private var saving = false
    @State private var shelfCount: Int?
    @State private var countError: String?
    @State private var countRetry = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    init(request: SavedFilterNameRequest, model: LibraryModel, saved: @escaping (UUID) -> Void) {
        self.request = request; self.model = model; self.saved = saved
        if case .rename(let entry) = request { _name = State(initialValue: entry.name) }
        else { _name = State(initialValue: "") }
    }

    private var title: LocalizedStringKey {
        if case .rename = request { "重命名虚拟书架" } else { "保存为虚拟书架" }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("书架名称", text: $name)
                    .keyboardInputRegion()
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .listRowBackground(Color(uiColor: theme.input))
                    .accessibilityIdentifier("savedFilterName")

                if case .save(let configuration, let term, let searchCount) = request {
                    Section {
                        ruleRows(configuration)
                    } header: {
                        Text("收录规则")
                    } footer: {
                        if !term.isEmpty {
                            Text("本次含搜索文字，匹配 \(searchCount) 本。虚拟书架只按收录规则匹配，不保存搜索文字。")
                        }
                    }
                    .listRowBackground(Color(uiColor: theme.surface))
                    .listRowSeparatorTint(Color(uiColor: theme.separator))
                }
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
            guard case .save(let configuration, let term, let searchCount) = request else { return }
            if term.isEmpty {
                shelfCount = searchCount
                return
            }
            do {
                let result = try await model.service.searchLibrary(query: "", configuration: configuration, virtualShelf: true)
                if !Task.isCancelled { shelfCount = result.entries.count }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.countError = ReaderMessages.error(error) }
            }
        }
        .alert("暂时无法完成", isPresented: Binding(get: { model.savedFilters.error != nil }, set: { if !$0 { model.savedFilters.error = nil } })) {
            Button("知道了", role: .cancel) { model.savedFilters.error = nil }
        } message: { Text(model.savedFilters.error ?? "") }
    }

    private var cleanedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !cleanedName.isEmpty && !saving && !model.savedFilters.saving && model.savedFilters.snapshot != nil }

    @ViewBuilder private func ruleRows(_ configuration: BookSearchConfiguration) -> some View {
        if let countError {
            Text(countError).foregroundStyle(Color(uiColor: theme.secondary))
            Button("重试") { self.countError = nil; countRetry += 1 }
        } else {
            LabeledContent("符合规则的小说") {
                if let shelfCount { Text("\(shelfCount) 本").fontWeight(.semibold) }
                else { ProgressView().controlSize(.small) }
            }
        }
        Text(configuration.root.expression(shelfTitle: model.shelfTitle))
            .fixedSize(horizontal: false, vertical: true)
        if !configuration.sorts.isEmpty {
            let order = configuration.sortDescription(hasTerm: false)
            Text("排序 · \(order)")
                .foregroundStyle(Color(uiColor: theme.secondary))
        }
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
            let success = await model.savedFilters.change(change)
            saving = false
            guard success else { return }
            if let created { saved(created) }
            dismiss()
        }
    }
}
