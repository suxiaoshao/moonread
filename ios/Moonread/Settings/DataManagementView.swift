import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

@MainActor @Observable final class DataManagementModel {
    let service: AppDataService
    var inventory = ReadingDataInventory(items: [], pending: 0, unsupported: 0)
    var cache = CacheSummary()
    var busy = false
    private(set) var loading = false
    private(set) var loaded = false
    private var inventoryLoad: Task<Void, Never>?
    private var inventoryRefreshRequested = false
    var working = ""
    var error: String?
    var message: String?
    var preview: ReadingBackupPreview?
    var exported: URL?
    var selected = Set<String>()
    var query = "" { didSet { if oldValue != query { selected.removeAll() } } }
    var unlinkedOnly = false { didSet { if oldValue != unlinkedOnly { selected.removeAll() } } }
    var recent = true
    var selecting = false
    var deleting: Set<String>?
    var issueErrors: [String: String] = [:]
    private(set) var duplicateNames: [String: (index: Int, count: Int)] = [:]
    private var operation: Task<Void, Never>?
    var canCancel: Bool { operation != nil }
    func cancel() { operation?.cancel() }
    private func runCancellable(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }; error = nil; message = nil; busy = true
        let task = Task {
            do { try Task.checkCancellation(); try await action() }
            catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
        operation = task; await task.value; operation = nil; busy = false
    }
    private var nameOrder: [String] = []
    private var recentOrder: [String] = []
    init(service: AppDataService = .shared) { self.service = service }
    var visible: [ReadingDataItem] {
        let items = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0) })
        return (recent ? recentOrder : nameOrder).compactMap { items[$0] }.filter {
            (!unlinkedOnly || !$0.linked) && (query.isEmpty || ([$0.title, $0.author] + $0.tags).contains { LibraryQueryRules.selectionMatches($0, query: query) })
        }
    }
    func load() async {
        if let inventoryLoad {
            inventoryRefreshRequested = true
            await inventoryLoad.value
            return
        }
        loading = true; error = nil
        let task = Task { @MainActor in
            defer { inventoryLoad = nil; loading = false; loaded = true }
            repeat {
                inventoryRefreshRequested = false
                error = nil
                do {
                    updateInventory(try await service.readingDataInventory())
                    cache = try await service.cacheSummary()
                } catch { self.error = ReaderMessages.error(error) }
            } while inventoryRefreshRequested
        }
        inventoryLoad = task
        await task.value
    }
    func updateInventory(_ value: ReadingDataInventory) {
            loaded = true
            inventory = value
            let entries = inventory.items.map { ReadingDataSortEntry(key: $0.id, title: $0.title, lastRead: $0.lastRead) }
            nameOrder = readingDataOrder(entries: entries, recent: false)
            recentOrder = readingDataOrder(entries: entries, recent: true)
            duplicateNames = [:]
            let byID = Dictionary(uniqueKeysWithValues: value.items.map { ($0.id, $0) })
            let groups = Dictionary(grouping: recentOrder.compactMap { byID[$0] }.filter { !$0.title.isEmpty }, by: \.title)
            for group in groups.values where group.count > 1 {
                for (index, item) in group.enumerated() { duplicateNames[item.id] = (index + 1, group.count) }
            }
            selected.formIntersection(visible.map(\.id))
    }
    var allVisibleSelected: Bool { !visible.isEmpty && Set(visible.map(\.id)).isSubset(of: selected) }
    func toggleVisibleSelection() {
        if allVisibleSelected { selected.subtract(visible.map(\.id)) } else { selected.formUnion(visible.map(\.id)) }
    }
    func prepareIssues() async {
        await load()
        guard !busy, error == nil else { return }; busy = true; working = String(localized: "正在关联阅读数据…", table: "DataManagement")
        defer { busy = false }
        // One attempt per completed task when this page is entered. Never loop
        // on a failed promotion or start an import merely to inspect inventory.
        for item in inventory.pendingItems where item.readable && item.phase == .complete {
            do { try await service.promoteUserData(item.bookID, retry: true); issueErrors[item.id] = nil }
            catch { issueErrors[item.id] = ReaderMessages.error(error) }
        }
        await load()
    }
    func continuePending(_ item: PendingReadingData) async {
        guard !busy else { return }; busy = true; working = String(localized: "正在准备正文", table: "DataManagement")
        defer { busy = false }
        do { try await service.continuePendingReadingData(item.id); issueErrors[item.id] = nil }
        catch { issueErrors[item.id] = ReaderMessages.error(error) }
        await load()
    }
    func exportAll() async {
        working = String(localized: "正在生成备份…", table: "DataManagement"); exported = nil
        await runCancellable {
            let next = try await self.service.exportReadingData()
            self.exported = next
        }
    }
    func shareBackup() async throws -> LibraryExport {
        guard let exported else { throw ReadingDataError.invalid }
        return try await service.readingBackupShareCopy(exported)
    }
    func prepareImport(_ url: URL) async {
        working = String(localized: "正在检查备份…", table: "DataManagement")
        await runCancellable { self.preview = try await self.service.previewReadingBackup(url) }
    }
    func importConfirmed() async {
        guard !busy, let candidate = preview else { return }; error = nil; working = String(localized: "正在导入…", table: "DataManagement"); busy = true; defer { busy = false }
        do {
            try await service.importReadingBackup(candidate)
            preview = nil; message = String(localized: "阅读数据已导入", table: "DataManagement"); await load()
        } catch ReadingDataError.changed {
            do { preview = try await service.refreshReadingBackupPreview(candidate.staging) }
            catch { preview = nil }
            error = ReadingDataError.changed.localizedDescription
        } catch { self.error = ReaderMessages.error(error) }
    }
    func deleteConfirmed(_ keys: Set<String>) async {
        guard !busy, !keys.isEmpty else { return }; deleting = nil; error = nil; working = String(localized: "正在清除…", table: "DataManagement"); busy = true; defer { busy = false }
        do {
            guard let configuration = inventory.configuration else { throw ReadingDataError.changed }
            let cleaned = try await service.deleteReadingData(keys, configuration: configuration)
            message = String(localized: cleaned ? "阅读数据已清除，小说文件未变" : "阅读数据已清除，部分本机缓存未清理", table: "DataManagement")
            selected.subtract(keys); await load()
        } catch { self.error = ReaderMessages.error(error) }
    }
    func requestDeleteAll() async {
        guard !busy else { return }
        do { deleting = try await service.allReadingDataKeys() }
        catch { self.error = ReaderMessages.error(error) }
    }
    func clearCache() async {
        working = String(localized: "正在清理缓存…", table: "DataManagement")
        await runCancellable {
            let result = try await self.service.clearRebuildableCaches()
            self.message = String(localized: "已清理 \(result.removed) 本缓存，保留 \(result.retained) 本", table: "DataManagement")
            await self.load()
        }
    }
    func chooseBackup() async -> URL? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") { return exported }
        #endif
        return nil
    }
}

struct DataManagementView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var picker = false
    @State private var exportConfirmation = false
    @State private var sharing: LibraryExport?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text("备份", tableName: "DataManagement") } icon: { Image(systemName: "externaldrive") }.font(.headline)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("备份包含全部阅读数据和配色，不包含小说原文、AI 或授权。", tableName: "DataManagement").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                        ViewThatFits(in: .horizontal) {
                            HStack { backupButtons }
                            VStack { backupButtons }
                        }
                        if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("readingDataError") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                if !model.inventory.diagnostics.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text("\(model.inventory.diagnostics.count) 项需要处理", tableName: "DataManagement")
                        Spacer()
                        NavigationLink { ReadingDataIssuesView(model: model) } label: { Text("查看", tableName: "DataManagement") }
                            .accessibilityIdentifier("readingDataIssues")
                    }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                }
                VStack {
                    VStack(spacing: 16) {
                        NavigationLink { ReadingDataListView(model: model) } label: {
                            HStack { Label { Text("阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "books.vertical") }; Spacer(); Text("\(model.inventory.items.count) 本", tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.secondary)); Image(systemName: "chevron.right").font(.footnote) }
                        }.accessibilityIdentifier("readingDataList")
                        ThemedDivider()
                        NavigationLink { ReadingDataCacheView(model: model) } label: {
                            HStack { Label { Text("可重建缓存", tableName: "DataManagement") } icon: { Image(systemName: "internaldrive") }; Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file)).foregroundStyle(Color(uiColor: theme.secondary)); Image(systemName: "chevron.right").font(.footnote) }
                        }.accessibilityIdentifier("readingDataCaches")
                    }.padding(.vertical, 8)
                }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                Button(role: .destructive) { Task { await model.requestDeleteAll() } } label: {
                    Text("删除全部阅读数据", tableName: "DataManagement").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.bordered).tint(Color(uiColor: theme.destructive)).accessibilityIdentifier("deleteAllReadingData")
            }.padding()
        }.pageScrollMargins()
        .themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .navigationBarTitleDisplayMode(.large)
        .modifier(ReadingDataWorking(model: model))
        .modifier(ReadingDataDeletionPrompt(model: model))
        .refreshable { await model.load() }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .cloudStatusChanged).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.moonreadBackup]) { result in
            switch result { case .success(let url): Task { await model.prepareImport(url) }; case .failure(let error): model.error = error.localizedDescription }
        }
        .confirmationDialog(Text("导出全部阅读数据？", tableName: "DataManagement"), isPresented: $exportConfirmation, titleVisibility: .visible) {
            Button { Task {
                await model.exportAll()
                #if DEBUG
                // U21 reimports this real export through its existing isolated
                // backup fixture; system sharing is outside the business flow.
                if await model.chooseBackup() != nil { return }
                #endif
                if model.exported != nil { do { sharing = try await model.shareBackup() } catch { model.error = ReaderMessages.error(error) } }
            } } label: { Text("生成全部备份", tableName: "DataManagement") }.accessibilityIdentifier("confirmExportAllReadingData")
        } message: { Text("全部 \(model.inventory.items.count) 本阅读数据与配色；身份未完成或附件缺失时将提示重试。", tableName: "DataManagement") }
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) { if let sharing { LibraryShareSheet(files: sharing) } }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 && !model.busy { model.preview = nil } })) { BackupImportPreviewView(model: model) }
    }
    @ViewBuilder private var backupButtons: some View {
        Button { Task { if let url = await model.chooseBackup() { await model.prepareImport(url) } else { picker = true } } } label: {
            Label { Text("导入备份", tableName: "DataManagement") } icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("importReadingBackup")
        Button { exportConfirmation = true } label: {
            Label { Text("导出全部", tableName: "DataManagement") } icon: { Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
        }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("exportAllReadingData")
        #if DEBUG
        .accessibilityValue(model.exported == nil ? "not-ready" : "backup-ready")
        #endif
    }
}
private struct ReadingDataWorking: ViewModifier {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    func body(content: Content) -> some View {
        content.disabled(model.busy).overlay {
            if model.busy {
                VStack(spacing: 12) {
                    ProgressView(model.working)
                    if model.canCancel { Button("取消") { model.cancel() } }
                }.padding().background(theme.floatingBackground(), in: .rect(cornerRadius: 12)).accessibilityIdentifier("readingDataWorking")
            }
        }
    }
}
private struct ReadingDataListView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var detail: ReadingDataItem?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if dynamicTypeSize.isAccessibilitySize {
                    readingDataFilter.pickerStyle(.menu)
                } else {
                    ViewThatFits(in: .horizontal) {
                        readingDataFilter.pickerStyle(.segmented).fixedSize(horizontal: true, vertical: false)
                        readingDataFilter.pickerStyle(.menu)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Picker(selection: $model.recent) {
                        Text("最近阅读", tableName: "DataManagement").tag(true)
                        Text("名称", tableName: "DataManagement").tag(false)
                    } label: { Text("排序", tableName: "DataManagement") }
                } label: { Label { Text("排序", tableName: "DataManagement") } icon: { Image(systemName: "arrow.up.arrow.down") } }
                    .labelStyle(.iconOnly).accessibilityIdentifier("readingDataSort")
            }.padding(.horizontal).padding(.vertical, 8)
            if let error = model.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                    Spacer(minLength: 8)
                    Button("重试") { Task { await model.load() } }
                }.padding(.horizontal).padding(.vertical, 8).accessibilityIdentifier("readingDataError")
            } else if let message = model.message {
                Label(message, systemImage: "checkmark.circle").font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 8).accessibilityIdentifier("readingDataResult")
            }
            if !model.visible.isEmpty {
                List(selection: $model.selected) {
                    Section {
                        ForEach(model.visible) { item in
                            Group {
                                if model.selecting {
                                    DataManagementRow(item: item, duplicate: model.duplicateNames[item.id])
                                } else {
                                    Button { detail = item } label: {
                                        DataManagementRow(item: item, duplicate: model.duplicateNames[item.id])
                                    }.buttonStyle(.plain)
                                }
                            }.tag(item.id).accessibilityIdentifier("reading-data-" + item.id)
                                .swipeActions { Button(role: .destructive) { model.deleting = [item.id] } label: { Text("删除", tableName: "DataManagement") } }
                        }
                    } footer: {
                        Text("按此设备当前索引判断；未建立索引或尚未重新连接的小说也可能出现在这里。", tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.secondary))
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
                .contentMargins(.top, 8, for: .scrollContent)
            } else if model.loading || !model.loaded {
                ProgressView { Text("正在读取阅读数据…", tableName: "DataManagement") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.error != nil {
                ContentUnavailableView { Label { Text("暂时无法读取阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "exclamationmark.circle") } }
            } else if model.inventory.items.isEmpty {
                ContentUnavailableView { Label { Text("暂无阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "books.vertical") } }
                    .accessibilityIdentifier("readingDataEmpty")
            } else {
                ContentUnavailableView { Label { Text("没有匹配的阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "magnifyingglass") } } description: {
                    Text("试试其他筛选条件或搜索词。", tableName: "DataManagement")
                }.accessibilityIdentifier("readingDataNoMatches")
            }
        }.themedPage()
        .navigationTitle(model.selecting ? Text("已选 \(model.selected.count) 本", tableName: "DataManagement") : Text("阅读数据", tableName: "DataManagement"))
        .navigationBarTitleDisplayMode(model.selecting ? .inline : .large)
        .searchable(text: $model.query, prompt: Text("搜索书名、作者或标签", tableName: "DataManagement"))
        .environment(\.editMode, .constant(model.selecting ? .active : .inactive))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.selecting.toggle(); model.selected.removeAll() } label: { Text(model.selecting ? "完成" : "选择", tableName: "DataManagement") }.accessibilityIdentifier("selectReadingData")
            }
            if model.selecting {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.toggleVisibleSelection() } label: { Text(model.allVisibleSelected ? "取消全选" : "全选", tableName: "DataManagement") }
                        .accessibilityIdentifier("selectAllReadingData")
                    Spacer()
                    Button(role: .destructive) { model.deleting = model.selected } label: { Text("删除 \(model.selected.count) 本", tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.destructive)) }
                        .disabled(model.selected.isEmpty).accessibilityIdentifier("deleteSelectedReadingData")
                }
            }
        }
        .toolbar(model.selecting ? .hidden : .automatic, for: .tabBar)
        .onDisappear { model.selecting = false; model.selected.removeAll() }
        .modifier(ReadingDataWorking(model: model)).modifier(ReadingDataDeletionPrompt(model: model))
        .sheet(item: $detail) { item in
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    DataManagementRow(item: item, duplicate: model.duplicateNames[item.id])
                    Text("书签 \(item.bookmarks) · 批注 \(item.annotations)", tableName: "DataManagement").font(.footnote)
                    Spacer()
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).themedPage()
                    .navigationTitle(Text("阅读数据", tableName: "DataManagement"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detail = nil } } }
            }
        }
    }
    private var readingDataFilter: some View {
        Picker(selection: $model.unlinkedOnly) {
            Text("全部 \(model.inventory.items.count)", tableName: "DataManagement")
                .tag(false).accessibilityIdentifier("readingDataFilterAll")
            Text("不在书架上 \(model.inventory.items.filter { !$0.linked }.count)", tableName: "DataManagement")
                .tag(true).accessibilityIdentifier("readingDataFilterUnlinked")
        } label: { Text("阅读数据", tableName: "DataManagement") }
        .accessibilityIdentifier("readingDataFilter")
    }

}
private struct DataManagementRow: View {
    @Environment(\.theme) private var theme
    let item: ReadingDataItem
    var duplicate: (index: Int, count: Int)? = nil
    private var sourceLabel: String {
        guard let hint = item.sourceHint else { return String(localized: "来源未知", table: "DataManagement") }
        var parts = [hint.relative_path]
        if let bytes = hint.byte_size { parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) }
        parts.append(hint.decoding == "auto" ? String(localized: "自动识别", table: "DataManagement") : hint.decoding.uppercased())
        return String(localized: "上次来源：", table: "DataManagement") + parts.joined(separator: " · ")
    }
    private var readingLabel: String {
        var parts: [String] = []
        if item.lastRead > 0 {
            let date = Date(timeIntervalSince1970: Double(item.lastRead) / 1000).formatted(.dateTime.year().month().day().hour().minute())
            parts.append(String(localized: "最后阅读", table: "DataManagement") + " " + date)
        }
        if let percentage = item.percentage {
            parts.append(String(localized: "读到", table: "DataManagement") + " " + percentage.formatted(.number.precision(.fractionLength(0))) + "%")
        } else if item.hasPosition { parts.append(String(localized: "只有阅读进度", table: "DataManagement")) }
        if item.hasStatistics { parts.append(String(localized: "有统计", table: "DataManagement")) }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    if !item.title.isEmpty { Text(verbatim: item.title) } else { Text("书架上没有这本小说", tableName: "DataManagement") }
                    if let duplicate {
                        Text("同名 \(duplicate.index)/\(duplicate.count)", tableName: "DataManagement")
                            .font(.caption2).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 6).padding(.vertical, 2).background(Color(uiColor: theme.raised), in: .capsule)
                    }
                }
                Text(verbatim: sourceLabel).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                if !readingLabel.isEmpty { Text(verbatim: readingLabel).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                if item.unsupported { Text("需要处理", tableName: "DataManagement").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
}
private struct ReadingDataIssuesView: View {
    @Environment(\.theme) private var theme
    @Environment(LibraryModel.self) private var library
    @Bindable var model: DataManagementModel
    @State private var discarding: PendingReadingData?
    private var pending: [PendingReadingData] { model.inventory.pendingItems.filter(\.readable) }
    private var unreadable: [ReadingDataDiagnostic] { model.inventory.diagnostics.filter { $0.reason != .pending } }
    var body: some View {
        Group {
            if model.loading || !model.loaded || (model.busy && model.inventory.diagnostics.isEmpty) {
                ProgressView { Text("正在检查阅读数据…", tableName: "DataManagement") }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error, model.inventory.diagnostics.isEmpty {
                ContentUnavailableView { Label { Text("暂时无法读取阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "exclamationmark.circle") } } description: {
                    Text(verbatim: error)
                } actions: { Button("重试") { Task { await model.prepareIssues() } } }
                .accessibilityIdentifier("readingDataIssuesError")
            } else if model.inventory.diagnostics.isEmpty {
                ContentUnavailableView { Label { Text("没有需要处理的记录", tableName: "DataManagement") } icon: { Image(systemName: "checkmark.circle") } }
                    .accessibilityIdentifier("readingDataIssuesEmpty")
            } else {
                VStack(spacing: 0) {
                    if let error = model.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                            Button("重试") { Task { await model.prepareIssues() } }
                        }.padding()
                    }
                    List {
                        pendingSection("正文没有准备完成", items: pending.filter { $0.phase != nil && $0.phase != .complete && $0.sourceState == .available })
                        pendingSection("阅读数据尚未关联", items: pending.filter { $0.phase == .complete })
                        pendingSection("需要重新连接书架", items: pending.filter { $0.phase != .complete && $0.sourceState == .reconnect })
                        pendingSection("找不到原文件", items: pending.filter { $0.phase != .complete && $0.sourceState == .missing })
                        if !unreadable.isEmpty {
                            Section {
                                ForEach(unreadable) { diagnostic in
                                    VStack(alignment: .leading, spacing: 6) {
                                        if !diagnostic.title.isEmpty { Text(verbatim: diagnostic.title).font(.headline) }
                                        Text(recordName(diagnostic.recordType))
                                        Text(reasonName(diagnostic.reason), tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.secondary))
                                    }.accessibilityIdentifier("readingDataIssue-" + diagnostic.reason.rawValue)
                                }
                            } header: { Text("暂时无法读取的记录", tableName: "DataManagement") }
                                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                        }
                    }
                }
            }
        }.themedPage().navigationTitle(Text("需要处理", tableName: "DataManagement"))
        .task { await model.prepareIssues() }
        .refreshable { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged).receive(on: DispatchQueue.main)) { _ in Task { await model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: .libraryIndexScanCommitted).receive(on: DispatchQueue.main)) { _ in Task { await model.load() } }
        .confirmationDialog(Text("丢弃这本书的待关联记录？", tableName: "DataManagement"), isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }), titleVisibility: .visible) {
            if let item = discarding {
                Button(role: .destructive) { discarding = nil; Task { await model.deleteConfirmed([item.id]) } } label: { Text("丢弃记录", tableName: "DataManagement") }
                    .accessibilityIdentifier("confirmDiscardPending")
            }
        } message: { Text("只删除这条待关联的阅读进度、统计及其他阅读数据，不删除小说文件，也不删除已经关联的正式记录。", tableName: "DataManagement") }
    }
    @ViewBuilder private func pendingSection(_ title: LocalizedStringKey, items: [PendingReadingData]) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        if item.title.isEmpty { Text("未关联的阅读数据", tableName: "DataManagement").font(.headline) }
                        else { Text(verbatim: item.title).font(.headline) }
                        if !item.source.isEmpty { Text(verbatim: item.source).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                        pendingExplanation(item)
                        if let error = model.issueErrors[item.id] { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                        HStack {
                            if item.canResume {
                                Button { Task { await model.continuePending(item) } } label: { Text("继续准备", tableName: "DataManagement") }
                                    .buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("resumePending-" + item.id)
                            } else if item.phase != .complete, item.sourceState == .reconnect, let shelf = item.shelfID {
                                Button { library.chooseFiles(.folder(shelf)) } label: { Text("重新连接书架", tableName: "DataManagement") }
                                    .buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("reconnectPending-" + item.id)
                            }
                            Spacer(minLength: 8)
                            Menu {
                                Button(role: .destructive) { discarding = item } label: { Text("丢弃记录", tableName: "DataManagement") }
                                    .accessibilityIdentifier("discardPending-" + item.id)
                            } label: { Label("更多", systemImage: "ellipsis").labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44) }
                                .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityIdentifier("pendingMore-" + item.id)
                        }.disabled(model.busy)
                    }.padding(.vertical, 4)
                }
            } header: { Text(title, tableName: "DataManagement") }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }
    }
    @ViewBuilder private func pendingExplanation(_ item: PendingReadingData) -> some View {
        if item.phase == .complete {
            Text("正文已准备完成，但阅读数据尚未关联。", tableName: "DataManagement")
        } else if item.sourceState == .reconnect {
            Text("原书架「\(item.shelfName)」需要重新授权，才能读取原文件。", tableName: "DataManagement")
        } else if item.phase == nil {
            Text("原导入任务已不在此设备，无法继续准备。", tableName: "DataManagement")
        } else if item.sourceState == .missing {
            Text("找不到原文件或来源信息，暂时无法继续准备。", tableName: "DataManagement")
        } else if item.canResume {
            Text("正文准备曾中断，阅读进度和统计会在准备完成后接上。", tableName: "DataManagement")
        } else {
            Label { Text("正在准备正文，完成后会自动关联阅读数据。", tableName: "DataManagement") } icon: { ProgressView() }
        }
    }
    private func reasonName(_ reason: ReadingDataDiagnostic.Reason) -> LocalizedStringKey {
        switch reason {
        case .newerFormat: "较新版本格式，请更新 App"
        case .unreadable: "数据无法读取，原始记录已保留"
        case .readFailure: "读取失败，请稍后重试"
        case .pending: "阅读数据尚未关联"
        }
    }
    private func recordName(_ kind: String) -> String {
        switch kind {
        case "values": String(localized: "小说信息与设置", table: "DataManagement")
        case "positions": String(localized: "阅读进度", table: "DataManagement")
        case "annotations": String(localized: "书签与批注", table: "DataManagement")
        case "facts": String(localized: "阅读统计", table: "DataManagement")
        case "statistics-clears": String(localized: "统计清除记录", table: "DataManagement")
        case "source": String(localized: "书架来源", table: "DataManagement")
        default: String(localized: "阅读数据", table: "DataManagement")
        }
    }
}
private struct ReadingDataCacheView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var confirmation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file)).font(.largeTitle.bold())
                Text("正文缓存可以随时重新生成，清理后再打开小说会稍慢一些。", tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.secondary))
                if model.cache.protected > 0 {
                    Text("有 \(model.cache.protected) 本正在使用或找不到原文件，暂不清理", tableName: "DataManagement").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
                Button { confirmation = true } label: { Text("清理可重建缓存", tableName: "DataManagement").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("clearRebuildableCaches")
                if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                if let error = model.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
                Spacer()
            }.padding()
        }.pageScrollMargins().themedPage().navigationTitle(Text("可重建缓存", tableName: "DataManagement"))
        .modifier(ReadingDataWorking(model: model))
        .confirmationDialog(Text("清理可重建缓存？", tableName: "DataManagement"), isPresented: $confirmation, titleVisibility: .visible) {
            Button { Task { await model.clearCache() } } label: { Text("确认清理缓存", tableName: "DataManagement") }
        }
    }
}
struct ReadingDataDeletionPrompt: ViewModifier {
    @Bindable var model: DataManagementModel
    func body(content: Content) -> some View {
        content.confirmationDialog(Text("清除这 \(model.deleting?.count ?? 0) 本小说的阅读数据？", tableName: "DataManagement"), isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } }), titleVisibility: .visible) {
            if let keys = model.deleting {
                Button(role: .destructive) { Task { await model.deleteConfirmed(keys) } } label: { Text("确认清除阅读数据", tableName: "DataManagement") }.accessibilityIdentifier("confirmDeleteReadingData")
            }
            Button("取消", role: .cancel) { model.deleting = nil }
        } message: {
            Text("将移除进度、书签、批注、人工目录、小说信息、封面和统计，并尝试清理正文缓存。小说文件不变，阅读时长从统计扣除；可能失去离线缓存，无法在 App 内撤销。已有备份仍可恢复。", tableName: "DataManagement")
            Text("开启同步时，对已同步对象的删除将由 iCloud 传播；新数据保留。同步关闭时仅本机生效，不承诺追溯删除未同步记录。", tableName: "DataManagement")
        }
    }
}
private struct BackupImportPreviewView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let preview = model.preview {
                        Label { Text("包含 \(preview.preview.keys.count) 本小说的阅读数据，其中 \(preview.linked) 本在书架上", tableName: "DataManagement") } icon: { Image(systemName: "books.vertical") }.font(.title3.bold())
                        if preview.preview.existingNewer > 0 { Text("本机有 \(preview.preview.existingNewer) 条更新的记录会保留", tableName: "DataManagement") }
                        if preview.preview.conflicts > 0 { Text("\(preview.preview.conflicts) 处批注有冲突", tableName: "DataManagement") }
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.pageScrollMargins().themedPage().navigationTitle(Text("导入预览", tableName: "DataManagement"))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                    Button { Task { await model.importConfirmed() } } label: { Text("确认导入", tableName: "DataManagement").frame(maxWidth: .infinity) }
                        .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("confirmImportReadingBackup")
                }.padding().background(Color(uiColor: theme.canvas))
            }
            .modifier(ReadingDataWorking(model: model))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if !model.busy { model.preview = nil } }.disabled(model.busy) } }
            .interactiveDismissDisabled(model.busy)
        }
    }
}
