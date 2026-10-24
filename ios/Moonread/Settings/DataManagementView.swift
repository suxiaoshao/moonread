import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

@MainActor @Observable final class DataManagementModel {
    let service: ReaderService
    var inventory = ReadingDataInventory(items: [], pending: 0, unsupported: 0)
    var cache = CacheSummary()
    var busy = false
    var error: String?
    var message: String?
    var preview: ReadingBackupPreview?
    var exported: URL?
    var selected = Set<String>()
    var query = ""
    var recent = true
    var selecting = false
    var deleting: Set<String>?
    private var operation: Task<Void, Never>?
    var canCancel: Bool { operation != nil }
    func cancel() { operation?.cancel() }
    private func runCancellable(_ action: @escaping @MainActor () async throws -> Void) async {
        guard !busy else { return }; busy = true
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
            query.isEmpty || ([$0.title, $0.author] + $0.tags).contains { LibraryQueryRules.selectionMatches($0, query: query) }
        }
    }
    func load() async {
        do {
            inventory = try await service.readingDataInventory()
            cache = try await service.cacheSummary()
            let entries = inventory.items.map { ReadingDataSortEntry(key: $0.id, title: $0.title, lastRead: $0.lastRead) }
            nameOrder = readingDataOrder(entries: entries, recent: false)
            recentOrder = readingDataOrder(entries: entries, recent: true)
            selected.formIntersection(inventory.items.map(\.id))
        } catch { self.error = ReaderMessages.error(error) }
    }
    func exportAll() async {
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
        await runCancellable { self.preview = try await self.service.previewReadingBackup(url) }
    }
    func importConfirmed() async {
        guard !busy, let candidate = preview else { return }; error = nil; busy = true; defer { busy = false }
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
        guard !busy, !keys.isEmpty else { return }; deleting = nil; busy = true; defer { busy = false }
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
    @State private var cacheConfirmation = false
    @State private var sharing: LibraryExport?
    var body: some View {
        List {
            Section {
                Button { Task { if let url = await model.chooseBackup() { await model.prepareImport(url) } else { picker = true } } } label: { Label { Text("导入阅读数据", tableName: "DataManagement") } icon: { Image(systemName: "square.and.arrow.down") } }
                    .accessibilityIdentifier("importReadingBackup")
                Button { exportConfirmation = true } label: { Label { Text("导出全部", tableName: "DataManagement") } icon: { Image(systemName: "square.and.arrow.up") } }
                    .accessibilityIdentifier("exportAllReadingData")
                if model.exported != nil {
                    Button { Task {
                        do { sharing = try await model.shareBackup() }
                        catch { model.error = ReaderMessages.error(error) }
                    } } label: { Text("保存或分享备份", tableName: "DataManagement") }.accessibilityIdentifier("shareReadingBackup")
                }
                if model.inventory.pending > 0 { Text("有 \(model.inventory.pending) 本身份尚未确定，请先完成正文准备", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary) }
                if model.inventory.unsupported > 0 { Text("部分数据需要较新版本处理，请更新 App", tableName: "DataManagement").foregroundStyle(.secondary) }
            } footer: { Text("备份包含全部阅读数据和配色，不包含小说原文、AI 或授权。", tableName: "DataManagement") }
            Section {
                Picker(selection: $model.recent) {
                    Text("最近阅读", tableName: "DataManagement").tag(true)
                    Text("名称", tableName: "DataManagement").tag(false)
                } label: { Text("排序", tableName: "DataManagement") }
                ForEach(model.visible) { item in
                    DataManagementRow(item: item, selected: model.selected.contains(item.id), selecting: model.selecting) {
                        if model.selecting {
                            if !model.selected.insert(item.id).inserted { model.selected.remove(item.id) }
                        } else { model.deleting = [item.id] }
                    }.accessibilityIdentifier("reading-data-" + item.id)
                }
                if model.selecting {
                    Button { model.selected = Set(model.visible.map(\.id)) } label: { Text("全选当前结果", tableName: "DataManagement") }
                    Button(role: .destructive) { model.deleting = model.selected } label: { Text("删除所选阅读数据", tableName: "DataManagement") }.disabled(model.selected.isEmpty).accessibilityIdentifier("deleteSelectedReadingData")
                }
                Button { model.selecting.toggle() } label: { Text(model.selecting ? "完成选择" : "选择阅读数据", tableName: "DataManagement") }
                Button(role: .destructive) { Task { await model.requestDeleteAll() } } label: { Text("删除全部阅读数据", tableName: "DataManagement") }.disabled(model.inventory.items.isEmpty)
            } header: { Text("阅读数据（\(model.inventory.items.count) 本）", tableName: "DataManagement") }
            Section {
                Text("预计可重建缓存：\(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file))", tableName: "DataManagement")
                Text("\(model.cache.protected) 本因正在使用或原件不可用而保留", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary)
                Button { cacheConfirmation = true } label: { Text("清理可重建缓存", tableName: "DataManagement") }.accessibilityIdentifier("clearRebuildableCaches")
            } header: { Text("可重建缓存", tableName: "DataManagement") } footer: { Text("执行时重新验证来源；不会删除阅读数据、小说或 iCloud 下载。清理量不等于立即释放的磁盘空间。", tableName: "DataManagement") }
            if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
        }
        .disabled(model.busy).themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .searchable(text: $model.query, prompt: Text("搜索书名、作者或标签", tableName: "DataManagement"))
        .overlay { if model.busy { VStack { ProgressView(); if model.canCancel { Button("取消") { model.cancel() } } }.padding().background(.regularMaterial, in: .rect(cornerRadius: 12)).accessibilityIdentifier("readingDataWorking") } }
        .task { await model.load() }
        .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .cloudStatusChanged).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in if !model.busy { Task { await model.load() } } }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.moonreadBackup]) { result in
            switch result { case .success(let url): Task { await model.prepareImport(url) }; case .failure(let error): model.error = error.localizedDescription }
        }
        .confirmationDialog(Text("导出全部阅读数据？", tableName: "DataManagement"), isPresented: $exportConfirmation, titleVisibility: .visible) {
            Button { Task { await model.exportAll() } } label: { Text("生成全部备份", tableName: "DataManagement") }.accessibilityIdentifier("confirmExportAllReadingData")
        } message: { Text("全部 \(model.inventory.items.count) 本阅读数据与配色；身份未完成或附件缺失时将提示重试。", tableName: "DataManagement") }
        .confirmationDialog(Text("清理可重建缓存？", tableName: "DataManagement"), isPresented: $cacheConfirmation, titleVisibility: .visible) {
            Button { Task { await model.clearCache() } } label: { Text("确认清理缓存", tableName: "DataManagement") }
        }
        .modifier(ReadingDataDeletionPrompt(model: model))
        .sheet(isPresented: Binding(get: { sharing != nil }, set: { if !$0 { sharing = nil } })) {
            if let sharing { LibraryShareSheet(files: sharing) }
        }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 && !model.busy { model.preview = nil } })) { BackupImportPreviewView(model: model) }
        .alert(Text("暂时无法完成", tableName: "DataManagement"), isPresented: Binding(get: { model.error != nil && model.preview == nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
private struct DataManagementRow: View {
    let item: ReadingDataItem
    let selected: Bool
    let selecting: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                if selecting { Image(systemName: selected ? "checkmark.circle.fill" : "circle") }
                VStack(alignment: .leading, spacing: 4) {
                    if item.linked { Text(verbatim: item.title) } else { Text("书架上没有这本小说", tableName: "DataManagement") }
                    if !item.author.isEmpty { Text(verbatim: item.author).font(.caption).foregroundStyle(.secondary) }
                    Text("书签 \(item.bookmarks) · 批注 \(item.annotations)", tableName: "DataManagement").font(.caption).foregroundStyle(.secondary)
                    if item.lastRead > 0 { Text(Date(timeIntervalSince1970: Double(item.lastRead) / 1000), style: .date).font(.caption).foregroundStyle(.secondary) }
                    if item.cover { Text("自定义封面", tableName: "DataManagement").font(.caption) }
                    if item.unsupported { Text("部分数据需要较新版本处理，请更新 App", tableName: "DataManagement").font(.caption) }
                }
                Spacer()
                if !selecting { Image(systemName: "trash").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.borderless)
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
            Form {
                if let error = model.error { Text(verbatim: error).foregroundStyle(.red) }
                if let preview = model.preview {
                    Section {
                        Text("包含 \(preview.preview.keys.count) 本小说的阅读数据，其中 \(preview.linked) 本在书架上", tableName: "DataManagement")
                        if preview.preview.existingNewer > 0 {
                            Text("本机有 \(preview.preview.existingNewer) 条更新的记录会保留", tableName: "DataManagement")
                        }
                        if preview.preview.conflicts > 0 {
                            Text("\(preview.preview.conflicts) 处批注有冲突", tableName: "DataManagement")
                        }
                    }.listRowBackground(Color(uiColor: theme.surface))
                    Section {
                        Button { Task { await model.importConfirmed() } } label: {
                            Text("确认导入", tableName: "DataManagement").frame(maxWidth: .infinity)
                        }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                            .accessibilityIdentifier("confirmImportReadingBackup")
                    }.listRowBackground(Color.clear)
                }
            }.themedPage().tint(Color(uiColor: theme.accent)).disabled(model.busy).navigationTitle(Text("导入预览", tableName: "DataManagement"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if !model.busy { model.preview = nil } }.disabled(model.busy) } }
                .interactiveDismissDisabled(model.busy)
        }
    }
}
