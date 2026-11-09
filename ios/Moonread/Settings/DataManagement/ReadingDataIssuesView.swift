import SwiftUI

struct ReadingDataIssuesView: View {
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
        .alert(Text("丢弃这本书的待关联记录？", tableName: "DataManagement"), isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } })) {
            if let item = discarding {
                Button(role: .destructive) { discarding = nil; Task { await model.deleteConfirmed([item.id]) } } label: { Text("丢弃记录", tableName: "DataManagement") }
                    .accessibilityIdentifier("confirmDiscardPending")
            }
            Button("取消", role: .cancel) { discarding = nil }
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
