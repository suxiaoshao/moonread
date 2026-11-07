import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

struct DataManagementView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var picker = false
    @State private var exportConfirmation = false
    @State private var sharing: LibraryExport?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                MetadataTasksSection(service: model.service)
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text("阅读数据备份", tableName: "MetadataExchange") } icon: { Image(systemName: "externaldrive") }.font(.headline)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("备份进度、书签、笔记等阅读数据，与小说信息分开。", tableName: "MetadataExchange").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        ViewThatFits(in: .horizontal) {
                            HStack { backupButtons }
                            VStack { backupButtons }
                        }
                        if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("readingDataError") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.inventory.diagnostics.isEmpty {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text("\(model.inventory.diagnostics.count) 项需要处理", tableName: "DataManagement")
                        Spacer()
                        NavigationLink { ReadingDataIssuesView(model: model) } label: { Text("查看", tableName: "DataManagement") }
                            .accessibilityIdentifier("readingDataIssues")
                    }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("阅读数据", tableName: "DataManagement").font(.headline)
                    NavigationLink { ReadingDataListView(model: model) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("查看与删除", tableName: "MetadataExchange").font(.body.weight(.medium))
                                Text("管理保存在月读的阅读记录", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                    }.accessibilityIdentifier("readingDataList")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("可重建缓存", tableName: "DataManagement").font(.headline)
                    Text("清理缓存不删除小说文件与阅读数据。", tableName: "MetadataExchange")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    NavigationLink { ReadingDataCacheView(model: model) } label: {
                        HStack {
                            Text("清理缓存", tableName: "DataManagement")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.cache.bytes), countStyle: .file)).foregroundStyle(Color(uiColor: theme.secondary))
                            Image(systemName: "chevron.right").font(.footnote)
                        }
                    }.foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("readingDataCaches")
                }
                Button(role: .destructive) { Task { await model.requestDeleteAll() } } label: {
                    Text("删除全部阅读数据", tableName: "DataManagement").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("deleteAllReadingData")
            }.padding(20).frame(maxWidth: 690, alignment: .leading).frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .navigationBarTitleDisplayMode(.inline)
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
        Button { exportConfirmation = true } label: {
            Label { Text("导出备份", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.up") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("exportAllReadingData")
        #if DEBUG
        .accessibilityValue(model.exported == nil ? "not-ready" : "backup-ready")
        #endif
        Button { Task { if let url = await model.chooseBackup() { await model.prepareImport(url) } else { picker = true } } } label: {
            Label { Text("导入备份", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("importReadingBackup")
    }
}
struct ReadingDataWorking: ViewModifier {
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
            }.themedPage().navigationTitle(Text("导入预览", tableName: "DataManagement"))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                    Button { Task { await model.importConfirmed() } } label: { Text("确认导入", tableName: "DataManagement").frame(maxWidth: .infinity) }
                        .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("confirmImportReadingBackup")
                }.padding().background(Color(uiColor: theme.canvas))
            }
            .modifier(ReadingDataWorking(model: model))
            .toolbar { ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { if !model.busy { model.preview = nil } }.disabled(model.busy) } }
            .interactiveDismissDisabled(model.busy)
        }
    }
}
