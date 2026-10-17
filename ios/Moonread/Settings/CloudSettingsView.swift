import CloudKit
import CoreData
import SwiftUI

struct CloudSettingsView: View {
    @Environment(CloudStore.self) private var cloud
    @Environment(\.theme) private var theme
    @State private var replacing: String?
    var body: some View {
        Form {
            Section {
                Toggle("阅读数据 iCloud 同步", isOn: Binding(get: { cloud.status.requested }, set: cloud.setEnabled))
                    .disabled(cloud.busy).accessibilityIdentifier("readingDataSyncToggle")
                if cloud.busy { ProgressView("正在处理") }
                if cloud.status.requested && !cloud.status.enabled { Text("已保留开启意愿，当前同步暂停。").foregroundStyle(Color(uiColor: theme.secondary)) }
                if cloud.status.syncing { ProgressView("正在同步") }
                if let date = cloud.status.lastSync { LabeledContent("上次同步") { Text(date, style: .relative) } }
                if let message = cloud.status.message { Text(message).foregroundStyle(Color(uiColor: theme.secondary)) }
                if cloud.status.enabled { Text("系统会自动同步已保存的数据。") }
                else if cloud.status.accountToConfirm != nil {
                    Button("确认同步到此账户") { cloud.requestConfirmation() }
                        .disabled(cloud.busy).accessibilityIdentifier("confirmCloudAccount")
                } else if cloud.status.requested {
                    Button("重试阅读数据同步") { cloud.retry() }.disabled(cloud.busy)
                }
            } header: { Text("阅读数据同步") } footer: {
                Text("同步进度、书签、批注、小说信息、配色方案和阅读统计。显示与阅读偏好留在此设备；此开关不控制小说文件。")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section {
                Text(cloud.libraryStatus)
                if let path = cloud.conflictPath {
                    Button("处理同名文件") { replacing = path }.disabled(cloud.busy)
                }
            } header: { Text("我的书架文件") } footer: {
                Text("我的书架由应用管理固定的本机与 iCloud 目录，小说文件由 iCloud Drive 同步。外部文件夹仍在原位置管理。")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .themedPage().navigationTitle("iCloud").navigationBarTitleDisplayMode(.inline)
        .task { await cloud.updateStatus() }
        .confirmationDialog("是否将本机阅读数据同步到此账户？", isPresented: Binding(get: { cloud.confirmationAccount != nil }, set: { if !$0 { cloud.confirmationAccount = nil } }), titleVisibility: .visible, presenting: cloud.confirmationAccount) { account in
            Button("同步到此账户") { cloud.confirmAccount(account) }.accessibilityIdentifier("approveCloudAccount")
            Button("取消", role: .cancel) { cloud.confirmationAccount = nil }
        } message: { _ in Text("仅同步当前本机仍存在的阅读数据，不移动小说文件。退出账户后的数据保留遵循系统规则。") }
        .confirmationDialog("替换同名文件？", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), presenting: replacing) { path in
            Button("替换", role: .destructive) { replacing = nil; cloud.replaceCloudFile(path) }
            Button("取消", role: .cancel) { replacing = nil }
        } message: { path in Text("iCloud 中已有“\(path)”，替换后将使用本机文件。取消会保留两处原件。") }
        .alert("暂时无法完成", isPresented: Binding(get: { cloud.error != nil }, set: { if !$0 { cloud.error = nil } })) {
            Button("知道了", role: .cancel) { cloud.error = nil }
        } message: { Text(cloud.error ?? "") }
    }
}
