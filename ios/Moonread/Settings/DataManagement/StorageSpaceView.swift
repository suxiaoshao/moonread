import Charts
import SwiftUI

private extension StorageCategory {
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

    var detail: LocalizedStringResource {
        switch self {
        case .books: .init("缓存、离线正文和封面副本", table: "Storage")
        case .database: .init("阅读记录、资料及同步状态", table: "Storage")
        case .work: .init("导入、导出和任务使用的文件", table: "Storage")
        case .old: .init("早期版本留下的数据", table: "Storage")
        case .app: .init("不可清理", table: "Storage")
        case .other: .init("书架文件、对话及其他数据", table: "Storage")
        }
    }

    func color(_ theme: ThemeSurface) -> Color {
        switch self {
        case .books: Color(uiColor: theme.accent)
        case .database: Color(uiColor: theme.success)
        case .work: Color(uiColor: theme.warning)
        case .old: Color(uiColor: theme.destructive)
        case .app: Color(uiColor: theme.ink)
        case .other: Color(uiColor: theme.secondary)
        }
    }
}

private extension StorageOther {
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

private enum StorageRoute: Hashable {
    case category(StorageCategory)
    case cleanup(StorageCleanupKind?)
    case offline
}

struct StorageSpaceView: View {
    let data: DataManagementModel
    @State private var model: StorageSpaceModel
    @Environment(\.theme) private var theme

    init(data: DataManagementModel) {
        self.data = data
        // The storage destination owns its inventory until the user exits it.
        _model = State(initialValue: StorageSpaceModel(service: data.service))
    }

    var body: some View {
        StoragePage(title: .init("存储空间", table: "Storage")) {
            if let overview = model.overview {
                VStack(alignment: .leading, spacing: 8) {
                    Text("月读总占用", tableName: "Storage").font(.headline)
                    Text(StorageSpaceModel.formatted(overview.total)).font(.largeTitle.bold())
                    if overview.total > 0 { storageBar(overview) }
                    StorageHint("按月读可读取的本机文件统计，可能与 iOS 设置略有不同。")
                    if overview.readingIncomplete { StorageHint("部分文件无法读取，当前只显示已统计的占用。") }
                }
                StorageGroup("按类别管理") {
                    ForEach(StorageCategory.allCases) { category in
                        let row = StorageRow(title: category.title, detail: category.detail,
                                             bytes: overview.sizes[category, default: 0], color: category.color(theme),
                                             navigates: category != .app)
                        if category == .app { row }
                        else { NavigationLink(value: StorageRoute.category(category)) { row }.buttonStyle(.plain) }
                    }
                }
                if !model.available.isEmpty {
                    NavigationLink(value: StorageRoute.cleanup(nil)) {
                        Text("选择清理项目", tableName: "Storage").frame(maxWidth: .infinity)
                    }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                }
                if let message = model.cleanupMessage { Text(verbatim: message).font(.footnote) }
            } else if let error = model.overviewError {
                StorageErrorRow(message: error) { await model.refresh() }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .accessibilityIdentifier("storageOverview")
        .navigationDestination(for: StorageRoute.self) { route in
            switch route {
            case .category(let kind): StorageCategoryPage(category: kind, model: model, data: data)
            case .cleanup(let kind): StorageSelectionPage(model: model, mode: .cleanup(kind))
            case .offline: StorageSelectionPage(model: model, mode: .offline)
            }
        }
    }

    private func storageBar(_ overview: StorageOverview) -> some View {
        Chart(StorageCategory.allCases) { item in
            let start = StorageCategory.allCases.prefix(while: { $0 != item })
                .reduce(UInt64(0)) { $0 + overview.sizes[$1, default: 0] }
            BarMark(xStart: .value("Start", Double(start)),
                    xEnd: .value("End", Double(start + overview.sizes[item, default: 0])),
                    y: .value("Storage", "Moonread"))
                .foregroundStyle(item.color(theme))
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartXScale(domain: 0...Double(overview.total))
        .frame(height: 14).clipShape(.capsule)
        .accessibilityHidden(true)
    }
}

private struct StorageCategoryPage: View {
    let category: StorageCategory
    let model: StorageSpaceModel
    let data: DataManagementModel

    var body: some View {
        if category == .database {
            StorageDatabasePage(model: model, data: data)
        } else {
            StoragePage(title: category.title) {
                content
            }
            .task { if needsLoad { await model.load(category) } }
            .refreshable { await model.loadOverview(); await model.load(category) }
        }
    }

    private var needsLoad: Bool {
        switch category {
        case .books: model.bodies == nil
        case .work: model.work == nil
        case .old: model.legacy == nil
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.errors[category] {
            StorageErrorRow(message: error) { await model.load(category) }
        } else if needsLoad {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            switch category {
            case .books:
                if let bodies = model.bodies {
                    StorageGroup("可管理内容") {
                        link(.cache)
                        if !bodies.offline.isEmpty {
                            NavigationLink(value: StorageRoute.offline) {
                                StorageRow(title: .init("离线正文", table: "Storage"),
                                           detail: .init("原文件暂不可用 · 按书移除", table: "Storage"),
                                           bytes: bodies.offline.reduce(0) { $0 + $1.bytes }, navigates: true)
                            }.buttonStyle(.plain)
                        }
                    }
                    if !bodies.held.isEmpty {
                        StorageGroup("暂时保留") {
                            StorageRow(title: .init("任务使用的正文", table: "Storage"),
                                       detail: .init("\(bodies.held.count) 本等待继续导入", table: "Storage"),
                                       bytes: bodies.held.reduce(0) { $0 + $1.bytes })
                        }
                    }
                    StorageHint("正文保存在索引库内，清理后空闲空间可继续使用。")
                }
            case .work:
                if let work = model.work {
                    StorageGroup("可清理") { link(.imports) }
                    let total = model.overview?.sizes[.work, default: 0] ?? 0
                    let accounted = work.removableBytes + work.packages.retained
                    if work.packages.retained > 0 || total > accounted {
                        StorageGroup("暂时保留") {
                            if work.packages.retained > 0 {
                                StorageRow(title: .init("导入任务的原包", table: "Storage"),
                                           detail: work.packages.unverified
                                               ? .init("暂时无法核对原包归属", table: "Storage")
                                               : .init("供未结束的任务继续使用", table: "Storage"),
                                           bytes: work.packages.retained)
                            }
                            if total > accounted {
                                StorageRow(title: .init("其余任务与临时文件", table: "Storage"), bytes: total - accounted)
                            }
                        }
                    }
                }
            case .old:
                StorageGroup("可清理") { link(.legacy) }
                let total = model.overview?.sizes[.old, default: 0] ?? 0
                let eligible = model.bytes(for: .legacy)
                if total > eligible {
                    StorageGroup("暂时保留") {
                        StorageRow(title: .init("旧版阅读数据", table: "Storage"),
                                   detail: .init("尚未确认完整迁入", table: "Storage"), bytes: total - eligible)
                    }
                }
            case .other:
                if let overview = model.overview {
                    StorageGroup("仅查看") {
                        ForEach(StorageOther.allCases, id: \.self) { item in
                            if let bytes = overview.other[item], bytes > 0 { StorageRow(title: item.title, bytes: bytes) }
                        }
                    }
                }
            case .database, .app: EmptyView()
            }
        }
    }

    @ViewBuilder private func link(_ kind: StorageCleanupKind) -> some View {
        let bytes = model.bytes(for: kind)
        if bytes > 0 {
            NavigationLink(value: StorageRoute.cleanup(kind)) {
                StorageRow(title: kind.title, bytes: bytes, navigates: true)
            }.buttonStyle(.plain)
        } else {
            StorageRow(title: kind.title, bytes: 0)
        }
    }
}

private struct StorageSelectionPage: View {
    enum Mode { case cleanup(StorageCleanupKind?), offline }
    let model: StorageSpaceModel
    let mode: Mode
    @Environment(LibraryModel.self) private var library
    @Environment(\.theme) private var theme
    @State private var selectedKinds = Set<StorageCleanupKind>()
    @State private var selectedBooks = Set<String>()
    @State private var request: StorageCleanupRequest?
    @State private var work: Task<Void, Never>?

    private var offline: Bool { if case .offline = mode { true } else { false } }

    private var selection: StorageCleanupRequest {
        model.confirmation(kinds: selectedKinds, offline: offline ? selectedBooks : nil, shell: library.shell)
    }

    var body: some View {
        StoragePage(title: offline ? .init("离线正文", table: "Storage") : .init("选择清理项目", table: "Storage")) {
            if offline {
                StorageHint("移除后需要重新取得同一份原文才能继续阅读。进度、书签和批注会保留。")
                StorageGroup("移除本机正文") {
                    ForEach(model.bodies?.offline ?? [], id: \.bookId) { book in
                        let picked = selectedBooks.contains(book.bookId)
                        Button { toggle(book.bookId, in: &selectedBooks) } label: {
                            StorageRow(title: nil, literal: book.title, detail: .init("暂未找到可用原文件", table: "Storage"),
                                       bytes: book.bytes, picked: picked)
                        }.buttonStyle(.plain).accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
            } else {
                StorageGroup("选择要清理的内容") {
                    ForEach(model.available) { kind in
                        let picked = selectedKinds.contains(kind)
                        Button { toggle(kind, in: &selectedKinds) } label: {
                            StorageRow(title: kind.title, bytes: model.bytes(for: kind), picked: picked)
                        }.buttonStyle(.plain).accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
                if model.available.isEmpty { StorageHint("暂无可清理项目") }
            }
            if !selection.readerTitles.isEmpty {
                Text("将关闭的阅读页：\(selection.readerTitles.formatted(.list(type: .and)))", tableName: "Storage")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
            Button { request = selection } label: {
                Text(selectionTitle).frame(maxWidth: .infinity)
            }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                .disabled(selection.bytes == 0 || model.busy)
                .accessibilityIdentifier("clearRebuildableCaches")
            if let message = model.cleanupMessage { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
        }
        .disabled(model.busy)
        .overlay {
            if model.busy {
                VStack(spacing: 12) {
                    ProgressView { Text("正在清理…", tableName: "Storage") }
                    Button("取消") { work?.cancel() }
                }.padding().background(theme.floatingBackground(), in: .rect(cornerRadius: 12))
            }
        }
        .onAppear {
            if case .cleanup(let kind) = mode, selectedKinds.isEmpty {
                selectedKinds = kind.map { [$0] } ?? Set(model.available)
            }
        }
        .refreshable { await model.refresh() }
        .alert(Text(alertTitle), isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
               presenting: request) { confirmed in
            Button(role: .destructive) {
                work = Task {
                    await model.clean(confirmed, shell: library.shell)
                    work = nil
                }
            } label: { Text(actionTitle(confirmed)) }
            Button("取消", role: .cancel) {}
        } message: { confirmed in
            let size = StorageSpaceModel.formatted(confirmed.bytes)
            if offline {
                Text("将移除约 \(size) 的本机正文。再次阅读需要重新取得原文。", tableName: "Storage")
            } else {
                let kinds = confirmed.kinds.map { String(localized: $0.title) }.formatted(.list(type: .and))
                Text("将清理\(kinds)，约 \(size)。", tableName: "Storage")
            }
            if !confirmed.readerTitles.isEmpty {
                Text("将保存进度并关闭\(confirmed.readerTitles.formatted(.list(type: .and)))。听书和自动阅读也会停止。", tableName: "Storage")
            }
        }
    }

    private var selectionTitle: LocalizedStringResource {
        if offline { return .init("移除所选本机正文", table: "Storage") }
        if selection.bytes == 0 { return .init("清理所选项目", table: "Storage") }
        return .init("清理 \(StorageSpaceModel.formatted(selection.bytes))", table: "Storage")
    }

    private var alertTitle: LocalizedStringResource {
        if request?.readers.isEmpty == false { return .init("关闭阅读页并清理？", table: "Storage") }
        return offline ? .init("移除所选本机正文？", table: "Storage") : .init("清理所选项目？", table: "Storage")
    }

    private func actionTitle(_ confirmed: StorageCleanupRequest) -> LocalizedStringResource {
        if offline { return confirmed.readers.isEmpty ? .init("移除", table: "Storage") : .init("关闭并移除", table: "Storage") }
        return confirmed.readers.isEmpty ? .init("清理", table: "Storage") : .init("关闭并清理", table: "Storage")
    }

    private func toggle<T: Hashable>(_ value: T, in selection: inout Set<T>) {
        if !selection.insert(value).inserted { selection.remove(value) }
    }
}

private struct StorageDatabasePage: View {
    let model: StorageSpaceModel
    let data: DataManagementModel
    @Environment(CloudStore.self) private var cloud
    @State private var confirmation = false

    private var unavailable: Bool {
        if cloud.status.syncing || data.busy || MetadataExchangeModel.shared.saving || MetadataExchangeModel.shared.loading { return true }
        if case .working = data.backupImport.phase { return true }
        if case .running = data.backupExport.phase { return true }
        return false
    }

    var body: some View {
        StoragePage(title: .init("阅读数据库", table: "Storage")) {
            if model.busy {
                ProgressView { Text("正在整理数据库…", tableName: "Storage") }.frame(maxWidth: .infinity)
            } else if let inventory = model.database {
                StorageGroup("当前阅读数据库") {
                    StorageRow(title: .init("可复用的空闲空间", table: "Storage"), bytes: inventory.freeBytes)
                    StorageRow(title: .init("未使用的封面", table: "Storage"),
                               detail: .init("\(inventory.orphanCount) 个", table: "Storage"), bytes: inventory.orphanBytes)
                }
                if let overview = model.overview, overview.sizes[.database, default: 0] > overview.activeDatabase {
                    StorageGroup("仅查看") {
                        StorageRow(title: .init("其他阅读数据库", table: "Storage"),
                                   bytes: overview.sizes[.database, default: 0] - overview.activeDatabase)
                    }
                }
                StorageHint("整理会移除无引用的封面并收回数据库空闲空间。")
                Button { confirmation = true } label: {
                    Text("整理数据库", tableName: "Storage").frame(maxWidth: .infinity)
                }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large)
                    .disabled(!inventory.canOrganize || unavailable)
                if unavailable { StorageHint("请在阅读数据同步或其他任务结束后再整理。") }
            } else if model.errors[.database] == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error = model.errors[.database] { StorageErrorRow(message: error) { await model.load(.database) } }
            if let result = model.databaseResult {
                Text(result.incomplete ? .init("已清除未使用的封面，数据库尚未整理。", table: "Storage")
                                       : .init("数据库已整理", table: "Storage")).font(.headline)
                StorageGroup("整理结果") {
                    StorageRow(title: .init("清除未使用的封面", table: "Storage"),
                               detail: .init("\(result.coversRemoved) 个", table: "Storage"))
                    if !result.incomplete {
                        StorageRow(title: .init("数据库文件减少", table: "Storage"), bytes: result.bytesRecovered)
                    }
                }
            }
        }
        .task { await model.load(.database) }
        .refreshable { await model.loadOverview(); await model.load(.database) }
        .alert(Text("整理当前账户的阅读数据库？", tableName: "Storage"), isPresented: $confirmation, presenting: model.database) { value in
            Button { Task { if !unavailable { await model.organize(value) } } } label: { Text("整理", tableName: "Storage") }
            Button("取消", role: .cancel) {}
        } message: { value in
            if value.orphanCount > 0 { Text("将清除 \(value.orphanCount) 个未使用的封面。", tableName: "Storage") }
            Text("将收回空闲空间。进度、批注和正在使用的封面会保留。", tableName: "Storage")
        }
    }
}

private struct StoragePage<Content: View>: View {
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

private struct StorageGroup<Content: View>: View {
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

private struct StorageRow: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringResource?
    var literal: String? = nil
    var detail: LocalizedStringResource? = nil
    var bytes: UInt64? = nil
    var color: Color? = nil
    var navigates = false
    var picked: Bool? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let color { Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true) }
            if let picked {
                Image(systemName: picked ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(Color(uiColor: picked ? theme.accent : theme.secondary)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let title { Text(title) }
                if let literal { Text(verbatim: literal) }
                if let detail { Text(detail).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let bytes {
                Text(StorageSpaceModel.formatted(bytes)).font(.subheadline.monospacedDigit())
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

private struct StorageHint: View {
    @Environment(\.theme) private var theme
    let text: String.LocalizationValue
    init(_ text: String.LocalizationValue) { self.text = text }
    var body: some View {
        Text(String(localized: text, table: "Storage")).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
    }
}

private struct StorageErrorRow: View {
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
