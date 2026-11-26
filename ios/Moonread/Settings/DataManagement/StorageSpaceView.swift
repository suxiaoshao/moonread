import Charts
import SwiftUI

extension StorageCategory {
    var title: LocalizedStringResource {
        switch self {
        case .books: .init("正文与封面", table: "Storage")
        case .database: .init("阅读数据库", table: "Storage")
        case .work: .init("导入与临时文件", table: "Storage")
        case .old: .init("旧版数据", table: "Storage")
        case .app: .init("App 本体", table: "Storage")
        case .other: .init("其他", table: "Storage")
        }
    }

    func color(_ theme: ThemeSurface) -> Color {
        switch self {
        case .books: Color(uiColor: theme.accent)
        case .database: Color(uiColor: theme.success)
        case .work: Color(uiColor: theme.warning)
        case .old: Color(uiColor: theme.destructive)
        case .app: Color(uiColor: .systemGray)
        case .other: Color(uiColor: theme.secondary)
        }
    }
}

extension StorageOther {
    var title: LocalizedStringResource {
        switch self {
        case .shelf: .init("本机书架文件", table: "Storage")
        case .conversations: .init("对话与附件", table: "Storage")
        case .fonts: .init("已安装字体", table: "Storage")
        case .snapshots: .init("系统界面快照", table: "Storage")
        case .caches: .init("其他缓存", table: "Storage")
        case .preferences: .init("偏好与其他文件", table: "Storage")
        }
    }
}

struct StorageSpaceView: View {
    let data: DataManagementModel
    let model: StorageSpaceModel
    @Environment(\.theme) private var theme
    private let storageBarHeight: CGFloat = 14
    private let storageBarShape = RoundedRectangle(cornerRadius: 5, style: .circular)

    var body: some View {
        StoragePage(title: .init("存储空间", table: "Storage")) {
            if let error = model.overviewError {
                StorageErrorRow(message: error) { await model.refresh() }
            } else {
                overviewContent(model.overview)
            }
        }
        .task { await model.loadForPresentation() }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("storageOverview")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.overview != nil, !model.available.isEmpty {
                    NavigationLink {
                        StorageSelectionPage(model: model, preselectedKind: nil)
                    } label: { Text("清理", tableName: "Storage") }
                    .accessibilityIdentifier("storageCleanup")
                }
            }
        }
    }

    @ViewBuilder private func overviewContent(_ overview: StorageOverview?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("月读总占用", tableName: "Storage").font(.headline)
            HStack(spacing: 12) {
                StorageAmount(bytes: overview?.total).font(.largeTitle.bold())
                if overview == nil {
                    ProgressView()
                        .accessibilityLabel(Text("正在统计占用", tableName: "Storage"))
                        .accessibilityIdentifier("storageInventoryProgress")
                }
            }
            if let overview, overview.total > 0 {
                storageBar(overview)
            } else if overview == nil {
                storageBarShape.fill(Color(uiColor: theme.secondary).opacity(0.16))
                    .frame(height: storageBarHeight).accessibilityHidden(true)
            }
        }
        StorageGroup("按类别管理") {
            ForEach(StorageCategory.allCases) { category in
                let row = StorageRow(title: category.title,
                                     bytes: overview.map { $0.sizes[category, default: 0] },
                                     color: category.color(theme), navigates: category != .app, loadingAmount: overview == nil)
                if category == .app { row }
                else {
                    NavigationLink {
                        StorageCategoryPage(category: category, model: model, data: data)
                    } label: { row }
                    .buttonStyle(.plain).disabled(overview == nil)
                    .accessibilityIdentifier("storageCategory-\(category.rawValue)")
                }
            }
        }
        if let message = model.cleanupMessage { Text(verbatim: message).font(.footnote) }
    }

    private func storageBar(_ overview: StorageOverview) -> some View {
        Chart(StorageCategory.allCases) { item in
            let start = StorageCategory.allCases.prefix(while: { $0 != item })
                .reduce(UInt64(0)) { $0 + overview.sizes[$1, default: 0] }
            BarMark(xStart: .value("Start", Double(start)),
                    xEnd: .value("End", Double(start + overview.sizes[item, default: 0])),
                    y: .value("Storage", "Moonread"),
                    height: .fixed(storageBarHeight))
                .cornerRadius(0)
                .foregroundStyle(item.color(theme))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartXScale(domain: 0...Double(overview.total))
        .chartYScale(range: .plotDimension(padding: 0))
        .chartPlotStyle { $0.clipShape(storageBarShape) }
        .frame(height: storageBarHeight)
        .accessibilityHidden(true)
    }
}

struct StorageAction: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringResource
    let progress: LocalizedStringResource?
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if let progress {
                Button(action: action) {
                    InlineTaskProgress(title: Text(progress))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Color(uiColor: theme.ink))
                .disabled(true)
            } else {
                Button(action: action) {
                    Text(title).frame(maxWidth: .infinity)
                }
                .buttonStyle(ThemedProminentButtonStyle())
                .disabled(disabled)
            }
        }.controlSize(.large)
    }
}

struct StoragePage<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20, content: content)
                .padding(20).frame(maxWidth: 690, alignment: .leading).frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle(Text(title)).navigationBarTitleDisplayMode(.inline)
    }
}

struct StorageGroup<Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String.LocalizationValue
    @ViewBuilder let content: () -> Content

    init(_ title: String.LocalizationValue, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: title, table: "Storage")).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(rows) { row in
                        if row.id != rows.first?.id { Divider().padding(.horizontal, 14) }
                        row
                    }
                }
            }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
        }
    }
}

struct StorageRow: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    var bytes: UInt64? = nil
    var color: Color? = nil
    var navigates = false
    var picked: Bool? = nil
    var loadingAmount = false

    var body: some View {
        HStack(spacing: 10) {
            if let color { Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true) }
            if let picked {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(Color(uiColor: picked ? theme.accent : theme.secondary)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if let detail { Text(detail).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if bytes != nil || loadingAmount {
                StorageAmount(bytes: bytes).font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
            if navigates {
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityHidden(true)
            }
        }.padding(14).frame(minHeight: 44).contentShape(.rect)
            .accessibilityElement(children: .combine)
    }
}

struct StorageAmount: View {
    let bytes: UInt64?

    var body: some View {
        if let bytes {
            Text(StorageSpaceModel.formatted(bytes))
        } else {
            Text(verbatim: "00.0 MB").redacted(reason: .placeholder).accessibilityHidden(true)
        }
    }
}

struct StorageHint: View {
    @Environment(\.theme) private var theme
    let text: String.LocalizationValue
    init(_ text: String.LocalizationValue) { self.text = text }
    var body: some View {
        Text(String(localized: text, table: "Storage")).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }
}

struct StorageErrorRow: View {
    @Environment(\.theme) private var theme
    let message: String
    let retry: () async -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
            Button("重试") { Task { await retry() } }
        }
    }
}
