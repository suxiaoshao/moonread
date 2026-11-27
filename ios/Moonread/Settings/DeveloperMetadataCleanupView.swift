import MoonreadLibrary
import MoonreadDesign
import MoonreadSearchText
import MoonreadData
import MoonreadDataTypes
#if MOONREAD_INTERNAL_TOOLS
import MoonreadCoreBindings
import SwiftUI

struct DeveloperMetadataCleanupView: View {
    let task: MetadataExchangeModel
    let service: AppDataService
    let openDataManagement: () -> Void
    @Environment(CloudStore.self) private var cloud
    @Environment(\.theme) private var theme
    @State private var inventory: MetadataCleanupInventory?
    @State private var loadingInventory = false
    @State private var selection = Set<String>()
    @State private var fields: Set<MetadataField> = [.author, .description, .tags, .cover]
    @State private var confirmation: MetadataCleanupConfirmation?
    @State private var confirming = false
    @State private var error: String?
    @State private var completed: Int?

    var body: some View {
        let preview = inventory.map { inventory in
            Result { try inventory.confirmation(selected: selection, fields: fields) }
        }
        let candidate = preview.flatMap { try? $0.get() }
        let count = candidate?.count ?? 0
        ZStack {
            if let completed {
                ContentUnavailableView {
                    Label {
                        Text("已清理 \(completed) 本的资料", tableName: "DeveloperTools")
                    } icon: { Image(systemName: "checkmark.circle") }
                } description: {
                    Text("可以前往数据管理重新导入小说信息。", tableName: "DeveloperTools")
                } actions: {
                    Button(action: openDataManagement) { Text("前往数据管理", tableName: "DeveloperTools") }
                        .buttonStyle(.bordered)
                }
            } else if let inventory {
                form(inventory)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        cleanupStatus(preview, count: count)
                    }
            } else if let error {
                ContentUnavailableView {
                    Label {
                        Text("暂时无法读取小说资料", tableName: "DeveloperTools")
                    } icon: { Image(systemName: "exclamationmark.circle") }
                } description: {
                    Text(error)
                } actions: {
                    Button("重试", action: startInventoryLoad)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .themedPage()
        .navigationTitle(completed == nil ? Text("清理小说资料", tableName: "DeveloperTools")
                         : Text("清理结果", tableName: "DeveloperTools"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if completed == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .destructive) {
                        guard let candidate else { return }
                        confirmation = candidate
                        confirming = true
                    } label: { Text("清理", tableName: "DeveloperTools") }
                        .disabled(count == 0 || !task.canCleanMetadata)
                }
            }
        }
        .onAppear {
            if inventory == nil { startInventoryLoad() }
        }
        .alert(Text("清理小说资料？", tableName: "DeveloperTools"), isPresented: $confirming, presenting: confirmation) { value in
            Button("取消", role: .cancel) { confirmation = nil }
            Button(role: .destructive) {
                confirmation = nil
                Task { await clean(value) }
            } label: { Text("清理", tableName: "DeveloperTools") }
        } message: { value in
            let names = MetadataCleanupInventory.fields.filter(value.fields.contains).map(\.title)
            let description = ListFormatter.localizedString(byJoining: names)
            let count = value.count
            Text(String(localized: "清理 \(count) 本小说的资料：\(description)。", table: "DeveloperTools")
                 + "\n" + impact(of: value.lease.scope))
        }
    }

    private func form(_ inventory: MetadataCleanupInventory) -> some View {
        Form {
            Section {
                NavigationLink {
                    DeveloperMetadataBookPicker(books: inventory.books, selected: selection) { selection = $0 }
                } label: {
                    HStack {
                        Text("选择小说", tableName: "DeveloperTools")
                        Spacer()
                        if selection.isEmpty {
                            Text("未选择", tableName: "DeveloperTools").foregroundStyle(.secondary)
                        } else {
                            Text("已选 \(selection.count) 本", tableName: "DeveloperTools").foregroundStyle(.secondary)
                        }
                    }
                }.disabled(task.cleaningMetadata)
                    .listRowBackground(Color(uiColor: theme.surface))
            } header: { Text("清理对象", tableName: "DeveloperTools") }

            Section {
                ForEach(MetadataCleanupInventory.fields) { field in
                    Toggle(field.title, isOn: Binding(get: { fields.contains(field) }, set: { selected in
                        if selected { fields.insert(field) } else { fields.remove(field) }
                    })).listRowBackground(Color(uiColor: theme.surface))
                }
            } header: { Text("清理内容", tableName: "DeveloperTools") }
            footer: {
                if fields.contains(.readingState) {
                    Text("手动阅读状态将恢复为默认值，阅读进度和其他阅读记录保留。", tableName: "DeveloperTools")
                } else {
                    Text("保留阅读状态和阅读记录。", tableName: "DeveloperTools")
                }
            }.disabled(task.cleaningMetadata)

            Section {
                libraryLabel(inventory.lease.scope).listRowBackground(Color(uiColor: theme.surface))
            } header: { Text("当前资料库", tableName: "DeveloperTools") }
            footer: { Text(impact(of: inventory.lease.scope)) }
        }.scrollContentBackground(.hidden)
    }

    @ViewBuilder private func cleanupStatus(_ preview: Result<MetadataCleanupConfirmation, Error>?, count: Int) -> some View {
        let message = cleanupMessage(preview, count: count)
        if task.cleaningMetadata || message != nil {
            HStack {
                if task.cleaningMetadata {
                    ProgressView {
                        Text("正在清理小说资料", tableName: "DeveloperTools")
                    }
                } else if let message {
                    message
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LayoutTokens.content)
            .background(Color(uiColor: theme.canvas))
        }
    }

    private func cleanupMessage(_ preview: Result<MetadataCleanupConfirmation, Error>?, count: Int) -> Text? {
        if let error { return Text(error) }
        if !task.canCleanMetadata {
            return Text("小说资料任务尚未结束，请结束任务后再清理。", tableName: "DeveloperTools")
        }
        if case .failure(let error)? = preview { return Text(ReaderMessages.error(error)) }
        if !selection.isEmpty && !fields.isEmpty && count == 0 {
            return Text("所选小说没有需要清理的内容。", tableName: "DeveloperTools")
        }
        return nil
    }

    @ViewBuilder private func libraryLabel(_ scope: DataScope) -> some View {
        if scope == .local {
            Text("本机资料库", tableName: "DeveloperTools")
        } else {
            switch CloudConfiguration.readingEnvironment {
            case .development: Text("账户资料库 · 开发环境", tableName: "DeveloperTools")
            case .production: Text("账户资料库 · 生产环境", tableName: "DeveloperTools")
            case nil: Text("账户资料库", tableName: "DeveloperTools")
            }
        }
    }

    private func impact(of scope: DataScope) -> String {
        if scope == .local { return String(localized: "本次清理只写入本机资料库。", table: "DeveloperTools") }
        if cloud.status.enabled && cloud.status.transportIssue == nil && cloud.status.phase != .waitingForDevice {
            return String(localized: "清理会通过 iCloud 同步到使用此账户和环境的其他设备。", table: "DeveloperTools")
        }
        return String(localized: "清理写入账户资料库，恢复同步后会更新使用此账户和环境的其他设备。", table: "DeveloperTools")
    }

    private func startInventoryLoad() {
        guard !loadingInventory else { return }
        loadingInventory = true
        // Finish the read across a quick exit and reentry to this destination.
        Task {
            defer { loadingInventory = false }
            await load()
        }
    }

    private func load() async {
        do {
            let updated = try await service.metadataCleanupInventory()
            guard !Task.isCancelled else { return }
            if updated.lease != inventory?.lease { selection = [] }
            else { selection.formIntersection(updated.books.map(\.id)) }
            inventory = updated
            error = nil
        } catch is CancellationError { }
        catch { self.error = ReaderMessages.error(error) }
    }

    private func clean(_ confirmation: MetadataCleanupConfirmation) async {
        error = nil
        do { completed = try await task.cleanMetadata(confirmation, service: service) }
        catch let change as ReadingDataError {
            await load()
            error = ReaderMessages.error(change)
        } catch { self.error = ReaderMessages.error(error) }
    }
}

private struct DeveloperMetadataBookPicker: View {
    let books: [MetadataCleanupInventory.Book]
    let done: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var selection: Set<String>
    @State private var query = ""

    init(books: [MetadataCleanupInventory.Book], selected: Set<String>, done: @escaping (Set<String>) -> Void) {
        self.books = books
        self.done = done
        _selection = State(initialValue: selected)
    }

    var body: some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = books.filter { term.isEmpty || LibraryQueryRules.selectionMatches($0.title, query: term) }
        let ids = Set(visible.map(\.id))
        let allVisibleSelected = ids.isSubset(of: selection)
        List(selection: $selection) {
            Section {
                ForEach(visible) { book in
                    VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                        Text(verbatim: book.title)
                        if book.copies > 1 {
                            Text("\(book.copies) 份相同正文 · 共用资料", tableName: "DeveloperTools")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: book.shelf).font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(book.id).listRowBackground(Color(uiColor: theme.surface))
                }
            } header: {
                HStack {
                    Text("已选 \(selection.count) 本", tableName: "DeveloperTools")
                    Spacer()
                    Button {
                        if allVisibleSelected { selection.subtract(ids) } else { selection.formUnion(ids) }
                    } label: {
                        if allVisibleSelected { Text("取消全选") }
                        else if term.isEmpty { Text("全选") }
                        else { Text("全选搜索结果", tableName: "DeveloperTools") }
                    }.disabled(ids.isEmpty)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .themedPage()
        .overlay {
            if visible.isEmpty {
                if term.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("暂无可选小说", tableName: "DeveloperTools")
                        } icon: { Image(systemName: "books.vertical") }
                    }
                } else { ContentUnavailableView.search(text: term) }
            }
        }
        .navigationTitle(Text("选择小说", tableName: "DeveloperTools"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("搜索小说", tableName: "DeveloperTools"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SystemToolbarButton("完成", role: .confirm) { done(selection); dismiss() }
            }
        }
    }
}
#endif
