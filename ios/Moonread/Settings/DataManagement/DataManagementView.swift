import MoonreadCoreBindings
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let moonreadBackup = UTType(exportedAs: "dev.moonread.backup", conformingTo: .zip) }

struct DataManagementView: View {
    @Environment(\.theme) private var theme
    @Bindable var model: DataManagementModel
    @State private var picker = false
    @State private var showingBackupExport = false
    @State private var showingReadingDeletion = false
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
                        backupImportStatus
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
                    ReadingDeletionSummary(task: model.readingDeletion) { showingReadingDeletion = true }
                }
            }.padding(20).frame(maxWidth: 690, alignment: .leading).frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .navigationBarTitleDisplayMode(.inline)
        .modifier(ReadingDataWorking(model: model))
        .onReceive(NotificationCenter.default.publisher(for: .readingDataChanged)
            .merge(with: NotificationCenter.default.publisher(for: .cloudStatusChanged),
                   NotificationCenter.default.publisher(for: .cloudDataReceived),
                   NotificationCenter.default.publisher(for: .libraryIndexScanCommitted))
            .receive(on: DispatchQueue.main)) { _ in model.invalidateIssueCount() }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.moonreadBackup]) { result in
            switch result {
            case .success(let url): model.receiveBackup(url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.showError(ReaderMessages.error(error)) }
            }
        }
        .sheet(isPresented: $showingReadingDeletion) { ReadingDeletionTaskView(task: model.readingDeletion).presentationSizing(.page) }
        .sheet(isPresented: $showingBackupExport) { BackupExportView(model: model).presentationSizing(.page) }
        .sheet(isPresented: $model.showingBackupImport) { BackupImportTaskView(task: model.backupImport).presentationSizing(.page) }
    }

    @ViewBuilder private var backupButtons: some View {
        Button {
            if model.backupImport.phase.isActive { model.showingBackupImport = true }
            else if let url = model.chooseBackup() { model.receiveBackup(url) }
            else { picker = true }
        } label: {
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

    @ViewBuilder private var backupImportStatus: some View {
        let task = model.backupImport
        if task.phase.isActive {
            let status = BackupImportStatus(task: task)
            DataExchangeTaskSummary(symbol: status.symbol,
                                  iconColor: status.isFailure ? theme.warning : status.isComplete ? theme.success : theme.secondary,
                                  link: Text(status.isInProgress ? "查看" : "查看结果", tableName: "MetadataExchange"),
                                  open: { model.showingBackupImport = true }) {
                Text(verbatim: status.title)
            } detail: {
                if case .working = task.phase {
                    Text("可以关闭页面，稍后查看。", tableName: "MetadataExchange")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
        }
    }

    private var backupExportStatus: some View {
        let export = model.backupExport
        return DataExchangeExportSummary(task: export,
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
    private var task: DataExchangeTask<Void, URL> { model.backupExport }

    var body: some View {
        DataExchangeTaskSheet(title: task.phase == .running ? Text("导出阅读数据备份", tableName: "DataManagement") : Text("导出结果", tableName: "MetadataExchange"),
                        sharing: $sharing, onShared: { [output = task.output] in
                            guard let output, task.output == output else { return }
                            task.clear()
                        }) {
            switch task.phase {
            case .idle: Color.clear
            case .running:
                DataExchangeRunningView(title: Text("正在生成备份", tableName: "DataManagement"), stopping: task.stopping) {
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
    let model: DataManagementModel

    func body(content: Content) -> some View {
        content.disabled(model.working != nil).toolbar {
            if let working = model.working {
                ToolbarItem(placement: .topBarTrailing) {
                    InlineTaskProgress(title: Text(verbatim: working))
                        .accessibilityIdentifier("readingDataWorking")
                }
            }
        }
    }
}
struct ReadingDataDeletionPrompt: ViewModifier {
    @Bindable var model: DataManagementModel
    var startTask: ((DataManagementModel.DeletionRequest) -> Void)?
    func body(content: Content) -> some View {
        content.alert(Text("清除这 \(model.deleting?.keys.count ?? 0) 本小说的阅读数据？", tableName: "DataManagement"), isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })) {
            if let request = model.deleting {
                Button(role: .destructive) {
                    if let startTask { startTask(request) } else { Task { await model.deleteConfirmed(request) } }
                } label: { Text("确认清除阅读数据", tableName: "DataManagement") }.accessibilityIdentifier("confirmDeleteReadingData")
            }
            Button("取消", role: .cancel) { model.deleting = nil }
        } message: {
            Text("将移除进度、书签、批注、人工目录、小说信息、封面和统计，并尝试清理正文缓存。小说文件不变，阅读时长从统计扣除；可能失去离线缓存，无法在 App 内撤销。已有备份仍可恢复。", tableName: "DataManagement")
            Text("开启同步时，对已同步对象的删除将由 iCloud 传播；新数据保留。同步关闭时仅本机生效，不承诺追溯删除未同步记录。", tableName: "DataManagement")
        }
    }
}
struct ReadingDeletionSummary: View {
    @Environment(\.theme) private var theme
    let task: DataExchangeTask<DataManagementModel.DeletionRequest, Bool>
    let open: () -> Void

    var body: some View {
        if task.phase != .idle {
            DataExchangeTaskSummary(symbol: task.phase == .running ? "trash" : task.phase.symbol,
                                    iconColor: task.phase == .completed ? theme.success : task.phase == .failed ? theme.warning : theme.secondary,
                                    link: Text(task.phase == .running ? "查看" : "查看结果", tableName: "MetadataExchange"),
                                    open: open) {
                switch task.phase {
                case .idle: EmptyView()
                case .running: Text("正在清除…", tableName: "DataManagement")
                case .completed: Text("阅读数据已清除", tableName: "DataManagement")
                case .failed: Text("清除阅读数据失败", tableName: "DataManagement")
                }
            } detail: {
                EmptyView()
            }.accessibilityElement(children: .contain).accessibilityIdentifier("readingDeletionSummary")
        }
    }
}

struct ReadingDeletionTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let task: DataExchangeTask<DataManagementModel.DeletionRequest, Bool>

    var body: some View {
        DataExchangeTaskSheet(title: Text("清除阅读数据", tableName: "DataManagement"),
                              sharing: .constant(nil), onShared: {}, closeIdentifier: "closeReadingDeletionTask") {
            switch task.phase {
            case .idle: Color.clear
            case .running:
                DataExchangeRunningView(title: Text("正在清除…", tableName: "DataManagement"), stopping: false, symbol: "trash") {
                    ProgressView()
                }
            case .completed:
                MetadataStatusView(symbol: task.phase.symbol, title: String(localized: "阅读数据已清除", table: "DataManagement"),
                                   message: task.output.map(DataManagementModel.deletionMessage(cacheCleaned:)))
                    .accessibilityIdentifier("readingDataResult")
            case .failed:
                MetadataStatusView(symbol: task.phase.symbol, title: String(localized: "清除阅读数据失败", table: "DataManagement"),
                                   message: task.error)
            }
        } footer: {
            if task.phase == .completed || task.phase == .failed {
                MetadataTaskActions {
                    if task.phase == .failed {
                        Button { task.retry() } label: { Text("重试").frame(maxWidth: .infinity) }
                            .buttonStyle(MetadataActionButtonStyle(prominent: true))
                    }
                    Button {
                        task.clear()
                        dismiss()
                    } label: {
                        Group {
                            if task.phase == .completed { Text("完成") } else { Text("关闭") }
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(MetadataActionButtonStyle(prominent: task.phase == .completed))
                        .accessibilityIdentifier("finishReadingDeletionTask")
                }
            }
        }
    }
}

@MainActor private struct BackupImportStatus {
    let task: BackupImportTask

    var isInProgress: Bool {
        switch task.phase {
        case .working, .review: true
        default: false
        }
    }
    var isFailure: Bool { if case .failed = task.phase { true } else { false } }
    var isComplete: Bool {
        switch task.phase {
        case .completed, .unchanged: true
        default: false
        }
    }
    var symbol: String {
        switch task.phase {
        case .idle, .working: "tray.and.arrow.down"
        case .review: "doc.text"
        case .unchanged, .completed: "checkmark.circle"
        case .stopped: "stop.circle"
        case .failed: "exclamationmark.circle"
        }
    }
    var title: String {
        switch task.phase {
        case .idle: ""
        case .working(.checking):
            if task.stopping { String(localized: "正在停止检查…", table: "DataManagement") }
            else { String(localized: "正在检查备份…", table: "DataManagement") }
        case .working(.importing):
            if task.stopping { String(localized: "正在停止导入。", table: "MetadataExchange") }
            else { String(localized: "正在导入", table: "MetadataExchange") }
        case .review(let preview):
            if preview.review.updates > 0 { String(localized: "将更新 \(preview.review.updates) 本", table: "DataManagement") }
            else { String(localized: "有全局阅读数据待导入", table: "DataManagement") }
        case .unchanged(let review):
            if review.isEmpty { String(localized: "备份中没有阅读数据", table: "DataManagement") }
            else { String(localized: "没有需要导入的数据", table: "DataManagement") }
        case .completed: String(localized: "阅读数据已导入", table: "DataManagement")
        case .stopped(.checking): String(localized: "检查已停止", table: "DataManagement")
        case .stopped(.importing): String(localized: "导入已停止", table: "MetadataExchange")
        case .failed(.checking, _): String(localized: "无法检查备份", table: "DataManagement")
        case .failed(.importing, _): String(localized: "导入失败", table: "MetadataExchange")
        }
    }
    var detail: String? {
        switch task.phase {
        case .stopped(.checking): String(localized: "没有导入阅读数据。", table: "DataManagement")
        case .stopped(.importing): String(localized: "没有保存此次改动。", table: "DataManagement")
        case .failed(_, let message): message
        case .unchanged(let review):
            if review.isEmpty { nil }
            else if review.keepsLocal {
                if review.books.isEmpty { String(localized: "本机较新的记录将保留。", table: "DataManagement") }
                else { String(localized: "已核对 \(review.books.count) 本：\(review.same) 本已相同，\(review.kept) 本保留本机较新的记录。", table: "DataManagement") }
            } else if review.books.isEmpty { String(localized: "备份数据均已存在。", table: "DataManagement") }
            else { String(localized: "已核对 \(review.books.count) 本，阅读数据均已相同。", table: "DataManagement") }
        default: nil
        }
    }
}

private struct BackupImportTaskView: View {
    @Environment(\.dismiss) private var dismiss
    let task: BackupImportTask

    var body: some View {
        let status = BackupImportStatus(task: task)
        DataExchangeTaskSheet(title: sheetTitle, sharing: .constant(nil), onShared: {}, closeIdentifier: "closeImportTask") {
            switch task.phase {
            case .idle: Color.clear
            case .working:
                DataExchangeRunningView(title: Text(verbatim: status.title), stopping: task.stopping, symbol: status.symbol) {
                    ProgressView()
                }
            case .review(let preview):
                BackupImportReviewView(review: preview.review, title: status.title)
            case .unchanged, .completed, .stopped, .failed:
                MetadataStatusView(symbol: status.symbol, title: status.title, message: status.detail)
            }
        } footer: {
            if task.phase.isActive {
                MetadataTaskActions { actions }
            }
        }
    }

    private var sheetTitle: Text {
        if case .review = task.phase { Text("导入预览", tableName: "DataManagement") }
        else { Text("导入阅读数据备份", tableName: "DataManagement") }
    }

    @ViewBuilder private var actions: some View {
        switch task.phase {
        case .idle: EmptyView()
        case .working(let operation):
            Button(role: .destructive, action: task.stop) {
                Label {
                    if task.stopping { Text("正在停止…", tableName: "DataManagement") }
                    else if operation == .checking { Text("停止检查", tableName: "DataManagement") }
                    else { Text("停止导入", tableName: "MetadataExchange") }
                } icon: { Image(systemName: "stop.circle") }.frame(maxWidth: .infinity)
            }.buttonStyle(MetadataActionButtonStyle(destructive: true)).disabled(task.stopping)
        case .review(let preview):
            Button(action: task.confirm) {
                Group {
                    if preview.review.hasGlobalChanges { Text("确认导入", tableName: "DataManagement") }
                    else { Text("导入 \(preview.review.updates) 本", tableName: "DataManagement") }
                }.frame(maxWidth: .infinity)
            }.buttonStyle(MetadataActionButtonStyle(prominent: true)).accessibilityIdentifier("confirmImportReadingBackup")
            Button(action: finish) { Text("结束本次导入", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                .buttonStyle(MetadataActionButtonStyle())
        case .unchanged, .completed, .stopped, .failed:
            if task.canRetry {
                Button(action: task.resume) { Text("重试", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                    .buttonStyle(MetadataActionButtonStyle(prominent: true))
            }
            Button(action: finish) { Text("完成", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                .buttonStyle(MetadataActionButtonStyle(prominent: !task.canRetry)).accessibilityIdentifier("finishBackupImport")
        }
    }

    private func finish() {
        task.clear()
        dismiss()
    }
}

private struct BackupImportReviewView: View {
    @Environment(\.theme) private var theme
    enum Filter: Hashable { case all, updates, unchanged }
    @State private var filter = Filter.all
    let review: ReadingBackupReview
    let title: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    if !review.books.isEmpty {
                        Text("共 \(review.books.count) 本 · \(review.same) 本已相同 · \(review.kept) 本保留本机", tableName: "DataManagement")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }.padding(.vertical, 8)
                if !review.global.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("全局阅读数据", tableName: "DataManagement").font(.headline).accessibilityAddTraits(.isHeader)
                        changeDetail(review.global)
                    }
                }
                if review.updates > 0, review.updates < review.books.count {
                    Picker(selection: $filter) {
                        Text("全部", tableName: "MetadataExchange").tag(Filter.all)
                        Text("将更新", tableName: "MetadataExchange").tag(Filter.updates)
                        Text("未更新", tableName: "MetadataExchange").tag(Filter.unchanged)
                    } label: { Text("预览范围", tableName: "MetadataExchange") }.pickerStyle(.segmented)
                }
                if !review.books.isEmpty {
                    MetadataReviewRows(rows: filteredBooks) { book in
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent {
                                disposition(book.disposition).font(.subheadline)
                                    .foregroundStyle(Color(uiColor: book.disposition == .restore ? theme.accent : theme.secondary))
                            } label: {
                                Group {
                                    if let title = book.title { Text(verbatim: title) }
                                    else { Text("未知小说", tableName: "DataManagement") }
                                }.font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                            }
                            changeDetail(book.changes, unlinked: !book.linked)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                    }
                }
            }.padding(20).frame(maxWidth: 690).frame(maxWidth: .infinity)
        }
    }

    private var filteredBooks: [ReadingBackupReview.Book] {
        switch filter {
        case .all: review.books
        case .updates: review.books.filter { $0.disposition == .restore }
        case .unchanged: review.books.filter { $0.disposition != .restore }
        }
    }

    private func disposition(_ disposition: BackupDisposition) -> Text {
        switch disposition {
        case .same: Text("已相同", tableName: "DataManagement")
        case .keepLocal: Text("保留本机", tableName: "DataManagement")
        case .restore: Text("将更新", tableName: "DataManagement")
        }
    }

    private func changeDetail(_ changes: Set<BackupChange>, unlinked: Bool = false) -> some View {
        let restored = kinds(changes, .restore), kept = kinds(changes, .keepLocal), same = kinds(changes, .same)
        return VStack(alignment: .leading, spacing: 2) {
            if !restored.isEmpty { Text("将恢复：\(restored)", tableName: "DataManagement") }
            if !kept.isEmpty { Text("保留本机：\(kept)", tableName: "DataManagement") }
            if restored.isEmpty, kept.isEmpty { Text("已相同：\(same)", tableName: "DataManagement") }
            if unlinked { Text("未在书架", tableName: "DataManagement") }
        }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }

    private func kinds(_ changes: Set<BackupChange>, _ disposition: BackupDisposition) -> String {
        BackupDataKind.allCases.filter { changes.contains(.init(kind: $0, disposition: disposition)) }
            .map(\.localizedName).formatted(.list(type: .and))
    }
}

private extension BackupDataKind {
    var localizedName: String {
        switch self {
        case .progress: String(localized: "阅读进度", table: "DataManagement")
        case .bookmark: String(localized: "书签", table: "DataManagement")
        case .annotation: String(localized: "批注", table: "DataManagement")
        case .metadata: String(localized: "小说信息", table: "DataManagement")
        case .chapter: String(localized: "人工目录", table: "DataManagement")
        case .history: String(localized: "阅读时长", table: "DataManagement")
        case .statisticsClear: String(localized: "统计清除记录", table: "DataManagement")
        case .isolatedHistory: String(localized: "待处理的统计记录", table: "DataManagement")
        case .cover: String(localized: "封面", table: "DataManagement")
        case .palette: String(localized: "配色方案", table: "DataManagement")
        case .decoding: String(localized: "文件编码", table: "DataManagement")
        }
    }
}
