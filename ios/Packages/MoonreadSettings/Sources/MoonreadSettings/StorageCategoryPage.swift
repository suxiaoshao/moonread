import MoonreadDataTypes
import MoonreadData
import SwiftUI

struct StorageCategoryPage: View {
    let category: StorageCategory
    let model: StorageSpaceModel
    let data: DataManagementModel
    let actions: StoragePageActions

    var body: some View {
        if category == .database {
            StorageDatabasePage(model: model, data: data, databaseBusy: actions.databaseBusy)
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
                    if work.removableBytes > 0 {
                        StorageGroup("可清理") { link(.imports) }
                    }
                    let total = model.overview?.sizes[.work, default: 0] ?? 0
                    let accounted = work.removableBytes + work.packages.retained
                    if work.packages.retained > 0 || total > accounted {
                        StorageGroup("暂时保留") {
                            if work.packages.retained > 0 {
                                StorageRow(title: .init("导入任务的原包", table: "Storage"),
                                           detail: work.packages.unverified
                                               ? .init("暂时无法核对原包归属", table: "Storage")
                                               : nil,
                                           bytes: work.packages.retained)
                            }
                            if total > accounted {
                                StorageRow(title: .init("其余任务与临时文件", table: "Storage"), bytes: total - accounted)
                            }
                        }
                    } else if work.removableBytes == 0 {
                        StorageHint("暂无可清理项目")
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
            NavigationLink {
                StorageSelectionPage(model: model, preselectedKind: kind, actions: actions)
            } label: {
                StorageRow(title: kind.title, bytes: bytes, navigates: true)
            }.buttonStyle(.plain)
        } else {
            StorageRow(title: kind.title, bytes: 0)
        }
    }
}
