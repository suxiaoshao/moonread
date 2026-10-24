import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

@MainActor @Observable final class DataManagementModel {
    let service: ReaderService
    var inventory = ReadingDataInventory(items: [], pending: 0, unsupported: 0)
    var cache = CacheSummary()
    var busy = false
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
    init(service: ReaderService = .shared) { self.service = service }
    var visible: [ReadingDataItem] {
        let items = Dictionary(uniqueKeysWithValues: inventory.items.map { ($0.id, $0) })
        return (recent ? recentOrder : nameOrder).compactMap { items[$0] }.filter {
            (!unlinkedOnly || !$0.linked) && (query.isEmpty || ([$0.title, $0.author] + $0.tags).contains { LibraryQueryRules.selectionMatches($0, query: query) })
        }
    }
    func load() async {
        error = nil
        do {
            updateInventory(try await service.readingDataInventory())
            cache = try await service.cacheSummary()
        } catch { self.error = ReaderMessages.error(error) }
    }
    func updateInventory(_ value: ReadingDataInventory) {
            inventory = value
            let entries = inventory.items.map { ReadingDataSortEntry(key: $0.id, title: $0.title, lastRead: $0.lastRead) }
            nameOrder = readingDataOrder(entries: entries, recent: false)
            recentOrder = readingDataOrder(entries: entries, recent: true)
            selected.formIntersection(visible.map(\.id))
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
    @Bindable var model: DataManagementModel
    @State private var picker = false
    @State private var exportConfirmation = false
    @State private var sharing: LibraryExport?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("备份包含全部阅读数据和配色，不包含小说原文、AI 或授权。", tableName: "DataManagement").font(.footnote).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack { backupButtons }
                            VStack { backupButtons }
                        }
                        if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red).accessibilityIdentifier("readingDataError") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label { Text("备份", tableName: "DataManagement") } icon: { Image(systemName: "externaldrive") } }
                if !model.inventory.diagnostics.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text("\(model.inventory.diagnostics.count) 项需要处理", tableName: "DataManagement")
                        Spacer()
                        NavigationLink { ReadingDataIssuesView(inventory: model.inventory) } label: { Text("查看", tableName: "DataManagement") }
                            .accessibilityIdentifier("readingDataIssues")
                    }.padding().background(.quaternary, in: .rect(cornerRadius: 12))
                }
                GroupBox {
                    VStack(spacing: 16) {
                        NavigationLink { ReadingDataListView(model: model) } label: {
                            HStack { Label { Text("阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "books.vertical") }; Spacer(); Text("\(model.inventory.items.count) 本", tableName: "DataManagement").foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.footnote) }
                        }.accessibilityIdentifier("readingDataList")
                        Divider()
                        NavigationLink { ReadingDataCacheView(model: model) } label: {
                            HStack { Label { Text("可重建缓存", tableName: "DataManagement") } icon: { Image(systemName: "internaldrive") }; Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file)).foregroundStyle(.secondary); Image(systemName: "chevron.right").font(.footnote) }
                        }.accessibilityIdentifier("readingDataCaches")
                    }.padding(.vertical, 8)
                }
            }.padding()
        }
        .themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .modifier(ReadingDataWorking(model: model))
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
    }
}
private struct ReadingDataWorking: ViewModifier {
    @Bindable var model: DataManagementModel
    func body(content: Content) -> some View {
        content.disabled(model.busy).overlay {
            if model.busy {
                VStack(spacing: 12) {
                    ProgressView(model.working)
                    if model.canCancel { Button("取消") { model.cancel() } }
                }.padding().background(.regularMaterial, in: .rect(cornerRadius: 12)).accessibilityIdentifier("readingDataWorking")
            }
        }
    }
}
private struct ReadingDataListView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var detail: ReadingDataItem?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker(selection: $model.unlinkedOnly) {
                    Text("全部", tableName: "DataManagement").tag(false)
                    Text("不在书架上", tableName: "DataManagement").tag(true)
                } label: { Text("筛选", tableName: "DataManagement") }.pickerStyle(.segmented).accessibilityIdentifier("readingDataFilter")
                if model.unlinkedOnly { Text("按此设备当前索引判断；未建立索引或尚未重新连接的小说也可能出现在这里。", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary) }
                if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                if let error = model.error { Text(verbatim: error).font(.footnote).foregroundStyle(.red) }
            }.padding(.horizontal).padding(.vertical, 8)
            List(model.visible) { item in
                Button {
                    if model.selecting { if !model.selected.insert(item.id).inserted { model.selected.remove(item.id) } }
                    else { detail = item }
                } label: { DataManagementRow(item: item, selected: model.selected.contains(item.id), selecting: model.selecting) }
                    .buttonStyle(.plain).accessibilityIdentifier("reading-data-" + item.id)
                    .swipeActions { Button(role: .destructive) { model.deleting = [item.id] } label: { Text("删除", tableName: "DataManagement") } }
            }
            .overlay { if model.visible.isEmpty { ContentUnavailableView { Label { Text("暂无阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "books.vertical") } } } }
        }.themedPage().navigationTitle(Text("阅读数据", tableName: "DataManagement"))
        .searchable(text: $model.query, prompt: Text("搜索书名、作者或标签", tableName: "DataManagement"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(selection: $model.recent) {
                        Text("最近阅读", tableName: "DataManagement").tag(true)
                        Text("名称", tableName: "DataManagement").tag(false)
                    } label: { Text("排序", tableName: "DataManagement") }
                    if model.selecting { Button(role: .destructive) { Task { await model.requestDeleteAll() } } label: { Text("删除全部阅读数据", tableName: "DataManagement") } }
                } label: { Label { Text("更多", tableName: "DataManagement") } icon: { Image(systemName: "ellipsis.circle") } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.selecting.toggle(); model.selected.removeAll() } label: { Text(model.selecting ? "完成选择" : "选择", tableName: "DataManagement") }.accessibilityIdentifier("selectReadingData")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.selecting {
                HStack {
                    Button { model.selected = Set(model.visible.map(\.id)) } label: { Text("全选当前结果", tableName: "DataManagement") }.accessibilityIdentifier("selectAllReadingData")
                    Spacer()
                    Button(role: .destructive) { model.deleting = model.selected } label: { Text("删除 \(model.selected.count) 本", tableName: "DataManagement") }
                        .buttonStyle(.bordered).tint(Color(uiColor: theme.destructive)).foregroundStyle(Color(uiColor: theme.destructive)).disabled(model.selected.isEmpty).accessibilityIdentifier("deleteSelectedReadingData")
                }.padding().background(.bar)
            }
        }
        .modifier(ReadingDataWorking(model: model)).modifier(ReadingDataDeletionPrompt(model: model))
        .sheet(item: $detail) { item in
            NavigationStack {
                VStack(alignment: .leading, spacing: 20) {
                    DataManagementRow(item: item, selected: false, selecting: false)
                    Spacer()
                }.padding().navigationTitle(Text("阅读数据", tableName: "DataManagement"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { detail = nil } } }
            }
        }
    }
}
private struct DataManagementRow: View {
    let item: ReadingDataItem
    let selected: Bool
    let selecting: Bool
    var body: some View {
        HStack {
            if selecting { Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint) }
            VStack(alignment: .leading, spacing: 4) {
                if !item.title.isEmpty { Text(verbatim: item.title) } else { Text("书架上没有这本小说", tableName: "DataManagement") }
                if !item.linked { Text("未关联到书架", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary) }
                if !item.author.isEmpty { Text(verbatim: item.author).font(.caption).foregroundStyle(.secondary) }
                Text("书签 \(item.bookmarks) · 批注 \(item.annotations)", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary)
                if item.lastRead > 0 { Text(Date(timeIntervalSince1970: Double(item.lastRead) / 1000), style: .date).font(.caption).foregroundStyle(.secondary) }
                if item.cover { Text("自定义封面", tableName: "DataManagement").font(.caption) }
                if item.unsupported { Text("需要处理", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
}
private struct ReadingDataIssuesView: View {
    let inventory: ReadingDataInventory
    private var groups: [String] { Set(inventory.diagnostics.compactMap(\.bookKey)).sorted() }
    var body: some View {
        List {
            ForEach(groups, id: \.self) { key in
                let issues = inventory.diagnostics.filter { $0.bookKey == key }
                Section {
                    ForEach(issues) { diagnostic in issue(diagnostic) }
                } header: {
                    if let title = issues.first(where: { !$0.title.isEmpty })?.title { Text(verbatim: title) }
                    else { Text("未关联的阅读数据", tableName: "DataManagement") }
                }
            }
            let other = inventory.diagnostics.filter { $0.bookKey == nil }
            if !other.isEmpty { Section { ForEach(other) { diagnostic in issue(diagnostic) } } header: { Text("其他记录", tableName: "DataManagement") } }
        }.themedPage().navigationTitle(Text("需要处理", tableName: "DataManagement"))
    }
    private func issue(_ diagnostic: ReadingDataDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recordName(diagnostic.recordType), tableName: "DataManagement").font(.headline)
            Text(reasonName(diagnostic.reason), tableName: "DataManagement")
            if !diagnostic.source.isEmpty { Text(verbatim: diagnostic.source).font(.caption).foregroundStyle(.secondary) }
            if diagnostic.reason == .pending {
                NavigationLink(value: LibraryRoute.manage) { Text("前往书架管理", tableName: "DataManagement") }
            }
        }.accessibilityIdentifier("readingDataIssue-" + diagnostic.reason.rawValue)
    }
    private func reasonName(_ reason: ReadingDataDiagnostic.Reason) -> LocalizedStringKey {
        switch reason {
        case .newerFormat: "较新版本格式，请更新 App"
        case .unreadable: "数据无法读取，原始记录已保留"
        case .readFailure: "读取失败，请稍后重试"
        case .pending: "正文尚未准备完成；来源不可用时，请重新连接书架或找到原文件。"
        }
    }
    private func recordName(_ kind: String) -> LocalizedStringKey {
        switch kind {
        case "values": "小说信息与设置"
        case "positions": "阅读进度"
        case "annotations": "书签与批注"
        case "facts": "阅读统计"
        case "statistics-clears": "统计清除记录"
        case "source": "书架来源"
        default: "阅读数据"
        }
    }
}
private struct ReadingDataCacheView: View {
    @Bindable var model: DataManagementModel
    @State private var confirmation = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file)).font(.largeTitle.bold())
                Text("执行时重新验证来源；不会删除阅读数据、小说或 iCloud 下载。清理量不等于立即释放的磁盘空间。", tableName: "DataManagement").foregroundStyle(.secondary)
                Text("\(model.cache.protected) 本因正在使用或原件不可用而保留", tableName: "DataManagement").font(.footnote).foregroundStyle(.secondary)
                Button { confirmation = true } label: { Text("清理可重建缓存", tableName: "DataManagement").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("clearRebuildableCaches")
                if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                if let error = model.error { Text(verbatim: error).foregroundStyle(.red) }
                Spacer()
            }.padding()
        }.themedPage().navigationTitle(Text("可重建缓存", tableName: "DataManagement"))
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
            }.themedPage().navigationTitle(Text("导入预览", tableName: "DataManagement"))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.red) }
                    Button { Task { await model.importConfirmed() } } label: { Text("确认导入", tableName: "DataManagement").frame(maxWidth: .infinity) }
                        .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("confirmImportReadingBackup")
                }.padding().background(.bar)
            }
            .modifier(ReadingDataWorking(model: model))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if !model.busy { model.preview = nil } }.disabled(model.busy) } }
            .interactiveDismissDisabled(model.busy)
        }
    }
}
