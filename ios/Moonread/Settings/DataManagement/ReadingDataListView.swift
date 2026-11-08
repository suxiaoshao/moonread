import SwiftUI

struct ReadingDataListView: View {
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
                ThemedGroupedList(sections: [
                    .init(id: "readingData", footer: String(localized: "按此设备当前索引判断；未建立索引或尚未重新连接的小说也可能出现在这里。", table: "DataManagement"), rows: model.visible.map { item in
                        .init(item.id, action: { detail = item }, actions: [
                            .init(title: String(localized: "删除", table: "DataManagement"), destructive: true, perform: { model.deleting = [item.id] })
                        ], accessibilityID: "reading-data-" + item.id) {
                            DataManagementRow(item: item, duplicate: model.duplicateNames[item.id])
                                .accessibilityIdentifier("reading-data-" + item.id)
                        }
                    })
                ], theme: theme, topInset: 8, selecting: model.selecting, selected: model.selected,
                   selectionChanged: { model.selected = $0 })
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
                Group {
                    if model.selecting {
                        SystemToolbarButton("结束选择", role: .confirm) { model.selecting = false; model.selected.removeAll() }
                    } else {
                        Button { model.selecting = true; model.selected.removeAll() } label: { Text("选择", tableName: "DataManagement") }
                    }
                }.accessibilityIdentifier("selectReadingData")
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
                    .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { detail = nil } } }
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
