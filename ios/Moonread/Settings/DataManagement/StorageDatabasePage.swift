import MoonreadLibrary
import MoonreadCoreBindings
import SwiftUI

struct StorageDatabasePage: View {
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
            if let inventory = model.database {
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
                let organizing = model.operation == .organizing
                StorageAction(title: .init("整理数据库", table: "Storage"),
                              progress: organizing ? .init("正在整理…", table: "Storage") : nil,
                              disabled: !inventory.canOrganize || unavailable || model.busy) { confirmation = true }
                if organizing {
                    StorageHint("整理开始后无法取消。")
                } else if unavailable {
                    StorageHint("请在阅读数据同步或其他任务结束后再整理。")
                }
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
        .refreshable { if !model.busy { await model.loadOverview(); await model.load(.database) } }
        .alert(Text("整理当前账户的阅读数据库？", tableName: "Storage"), isPresented: $confirmation, presenting: model.database) { value in
            Button { Task { if !unavailable { await model.organize(value) } } } label: { Text("整理", tableName: "Storage") }
            Button("取消", role: .cancel) {}
        } message: { value in
            if value.orphanCount > 0 { Text("将清除 \(value.orphanCount) 个未使用的封面。", tableName: "Storage") }
            Text("将收回空闲空间。进度、批注和正在使用的封面会保留。", tableName: "Storage")
        }
    }
}
