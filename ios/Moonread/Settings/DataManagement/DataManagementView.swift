import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

struct DataManagementView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var picker = false
    @State private var showingBackupExport = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                MetadataTasksSection()
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text("阅读数据备份", tableName: "MetadataExchange") } icon: { Image(systemName: "externaldrive") }.font(.headline)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("备份进度、书签、笔记等阅读数据，与小说信息分开。", tableName: "MetadataExchange").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        ViewThatFits(in: .horizontal) {
                            HStack { backupButtons }
                            VStack { backupButtons }
                        }
                        backupExportStatus
                        if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("readingDataError") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let issueCount = model.issueCount, issueCount > 0 {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text("\(issueCount) 项需要处理", tableName: "DataManagement")
                        Spacer()
                        NavigationLink { ReadingDataIssuesView(model: model) } label: { Text("查看", tableName: "DataManagement") }
                            .accessibilityIdentifier("readingDataIssues")
                    }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                } else if model.issueCount == nil {
                    NavigationLink { ReadingDataIssuesView(model: model) } label: {
                        HStack {
                            Label { Text("需要处理", tableName: "DataManagement") } icon: { Image(systemName: "exclamationmark.circle") }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("readingDataIssues")
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
                            if let cache = model.cache {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: cache.bytes), countStyle: .file)).foregroundStyle(Color(uiColor: theme.secondary))
                            } else if model.cacheError == nil {
                                ProgressView().controlSize(.small)
                            }
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
        .refreshable { await model.loadCache() }
        .task { await model.loadCache() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryIdentityChanged).receive(on: DispatchQueue.main)) { _ in
            if !model.busy { Task { await model.loadCache() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged)
            .merge(with: NotificationCenter.default.publisher(for: .cloudStatusChanged),
                   NotificationCenter.default.publisher(for: .cloudDataReceived),
                   NotificationCenter.default.publisher(for: .libraryIndexScanCommitted))
            .receive(on: DispatchQueue.main)) { _ in model.invalidateIssueCount() }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.moonreadBackup]) { result in
            switch result { case .success(let url): Task { await model.prepareImport(url) }; case .failure(let error): model.showError(error.localizedDescription) }
        }
        .sheet(isPresented: $showingBackupExport) { BackupExportView(model: model).presentationSizing(.page) }
        .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 && !model.busy { model.closePreview() } })) { BackupImportPreviewView(model: model) }
    }
    @ViewBuilder private var backupButtons: some View {
        Button { Task { if let url = await model.chooseBackup() { await model.prepareImport(url) } else { picker = true } } } label: {
            Label { Text("导入备份", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.down") }.frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("importReadingBackup")
        Button {
            model.backupExport.start(())
            showingBackupExport = true
        } label: {
            Label { Text("导出备份", tableName: "MetadataExchange") } icon: { Image(systemName: "square.and.arrow.up") }
                .frame(maxWidth: .infinity)
        }.buttonStyle(MetadataActionButtonStyle()).accessibilityIdentifier("exportAllReadingData")
    }

    private var backupExportStatus: some View {
        let export = model.backupExport
        return ExportTaskSummary(task: export,
                                 runningDetail: export.stopping ? nil : Text("正在生成备份", tableName: "DataManagement"),
                                 open: { showingBackupExport = true }) { _ in
            Text("备份已生成", tableName: "DataManagement")
        }
    }
}

private struct BackupExportView: View {
    let model: DataManagementModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: LibraryExport?
    @State private var sharingError: String?
    @State private var preparingShare = false
    private var task: ExportTask<Void, URL> { model.backupExport }

    var body: some View {
        ExportTaskSheet(title: task.phase == .running ? Text("导出阅读数据备份", tableName: "DataManagement") : Text("导出结果", tableName: "MetadataExchange"),
                        sharing: $sharing, onShared: { [output = task.output] in
                            guard let output, task.output == output else { return }
                            task.clear()
                        }) {
            switch task.phase {
            case .idle: Color.clear
            case .running:
                ExportRunningView(title: Text("正在生成备份", tableName: "DataManagement"), stopping: task.stopping) {
                    ProgressView {
                        if task.stopping { Text("正在停止导出。", tableName: "MetadataExchange") }
                    }
                }
            case .completed:
                MetadataStatusView(symbol: task.phase.symbol, title: String(localized: "备份已生成", table: "DataManagement"),
                                   message: task.output?.lastPathComponent)
            case .failed:
                MetadataStatusView(symbol: task.phase.symbol,
                                   title: String(localized: "导出失败", table: "MetadataExchange"),
                                   message: task.error)
            }
        } footer: {
            footer
        }
        .alert(Text("无法分享导出文件", tableName: "MetadataExchange"),
               isPresented: Binding(get: { sharingError != nil }, set: { if !$0 { sharingError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            if let sharingError { Text(verbatim: sharingError) }
        }
        .onChange(of: task.phase) { _, phase in
            if phase == .idle { dismiss() }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            ThemedDivider()
            VStack(spacing: 8) {
                switch task.phase {
                case .idle: EmptyView()
                case .running:
                    Button(role: .destructive) { task.cancel() } label: {
                        Label { Text("停止导出", tableName: "MetadataExchange") } icon: { Image(systemName: "stop.circle") }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(destructive: true)).disabled(task.stopping)
                case .completed:
                    Button { share() } label: {
                        Text("分享或存储", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(prominent: true)).disabled(preparingShare)
                        .accessibilityIdentifier("shareReadingBackup")
                    finishButton(Text("完成", tableName: "MetadataExchange"))
                case .failed:
                    Button { task.retry() } label: {
                        Text("重试", tableName: "MetadataExchange").frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(prominent: true))
                    finishButton(Text("关闭"))
                }
            }.frame(maxWidth: 460).padding(.horizontal, 20).padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
    }

    private func finishButton(_ title: Text) -> some View {
        Button { task.clear() } label: { title.frame(maxWidth: .infinity) }
            .buttonStyle(MetadataActionButtonStyle()).disabled(preparingShare)
    }

    private func share() {
        preparingShare = true
        Task {
            defer { preparingShare = false }
            do { sharing = try await model.shareBackup() }
            catch { sharingError = ReaderMessages.error(error) }
        }
    }
}
struct ReadingDataWorking: ViewModifier {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    func body(content: Content) -> some View {
        content.disabled(model.busy).overlay {
            if let working = model.working {
                VStack(spacing: 12) {
                    ProgressView(working)
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
                if let cache = model.cache {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: cache.bytes), countStyle: .file)).font(.largeTitle.bold())
                    if cache.protected > 0 {
                        Text("有 \(Int(clamping: cache.protected)) 本正在使用或找不到原文件，暂不清理", tableName: "DataManagement").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                } else if model.cacheError == nil {
                    ProgressView()
                }
                Text("正文缓存可以随时重新生成，清理后再打开小说会稍慢一些。", tableName: "DataManagement").foregroundStyle(Color(uiColor: theme.secondary))
                if let error = model.cacheError {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                    Button("重试") { Task { await model.loadCache() } }
                }
                Button { confirmation = true } label: { Text("清理可重建缓存", tableName: "DataManagement").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("clearRebuildableCaches")
                if let message = model.message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                if let error = model.error { Text(verbatim: error).foregroundStyle(Color(uiColor: theme.destructive)) }
                Spacer()
            }.padding()
        }.themedPage().navigationTitle(Text("可重建缓存", tableName: "DataManagement"))
        .task { if model.cache == nil { await model.loadCache() } }
        .refreshable { await model.loadCache() }
        .modifier(ReadingDataWorking(model: model))
        .alert(Text("清理可重建缓存？", tableName: "DataManagement"), isPresented: $confirmation) {
            Button(role: .destructive) { Task { await model.clearCache() } } label: { Text("确认清理缓存", tableName: "DataManagement") }
            Button("取消", role: .cancel) {}
        }
    }
}
struct ReadingDataDeletionPrompt: ViewModifier {
    @Bindable var model: DataManagementModel
    func body(content: Content) -> some View {
        content.alert(Text("清除这 \(model.deleting?.keys.count ?? 0) 本小说的阅读数据？", tableName: "DataManagement"), isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })) {
            if let request = model.deleting {
                Button(role: .destructive) { Task { await model.deleteConfirmed(request) } } label: { Text("确认清除阅读数据", tableName: "DataManagement") }.accessibilityIdentifier("confirmDeleteReadingData")
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
            .toolbar { ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { if !model.busy { model.closePreview() } }.disabled(model.busy) } }
            .interactiveDismissDisabled(model.busy)
        }
    }
}
