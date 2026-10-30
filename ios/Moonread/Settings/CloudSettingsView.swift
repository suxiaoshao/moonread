import CloudKit
import CoreData
import SwiftUI

struct CloudSettingsView: View {
    @Environment(CloudStore.self) private var cloud
    @Environment(\.theme) private var theme
    @State private var replacing: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("阅读数据 iCloud 同步", isOn: Binding(get: { cloud.status.requested }, set: cloud.setEnabled))
                        .font(.headline).disabled(cloud.busy).accessibilityIdentifier("readingDataSyncToggle")
                    ThemedDivider()
                    HStack(alignment: .top, spacing: 12) {
                        if cloud.busy || cloud.status.syncing { ProgressView().accessibilityLabel(cloud.syncTitle) }
                        else { Image(systemName: cloud.status.message != nil || cloud.status.accountToConfirm != nil ? "exclamationmark.icloud" : "icloud").foregroundStyle(Color(uiColor: theme.secondary)) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: cloud.syncTitle).font(.headline).accessibilityIdentifier("cloudSyncStatus")
                            if let date = cloud.status.lastSync {
                                HStack { Text("上次同步"); Text(date, style: .relative) }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                            if let message = cloud.status.message { Text(verbatim: message).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                            if !cloud.status.enabled {
                                if cloud.status.accountToConfirm != nil {
                                    Button("确认同步到此账户") { cloud.requestConfirmation() }
                                        .buttonStyle(ThemedProminentButtonStyle()).disabled(cloud.busy).accessibilityIdentifier("confirmCloudAccount")
                                } else if cloud.status.requested {
                                    Button("重试阅读数据同步") { cloud.retry() }.buttonStyle(ThemedProminentButtonStyle()).disabled(cloud.busy)
                                }
                            }
                        }
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                VStack(alignment: .leading, spacing: 6) {
                    Text("同步进度、书签、批注、小说信息、配色方案、手选编码和阅读统计。显示与阅读偏好留在此设备；此开关不控制小说文件。")
                    if cloud.status.enabled { Text("系统会自动同步已保存的数据。") }
                }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 4)
                VStack(alignment: .leading, spacing: 16) {
                    Label("我的书架文件", systemImage: "folder").font(.headline)
                    if let path = cloud.conflictPath {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.accent))
                            VStack(alignment: .leading, spacing: 8) {
                                Text("有一个同名文件需要处理").font(.headline)
                                Text(verbatim: path).textSelection(.enabled)
                                Text("本机与 iCloud 中都有这个文件。处理前，两处原件都会保留。")
                                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        Button("处理同名文件") { replacing = path }.buttonStyle(ThemedProminentButtonStyle()).disabled(cloud.busy)
                    } else {
                        Text(verbatim: cloud.libraryStatus).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    ThemedDivider()
                    NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: "builtin"))) {
                        HStack {
                            Text("查看我的书架")
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                .foregroundStyle(Color(uiColor: theme.secondary))
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
                    }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                        .accessibilityIdentifier("openManagedShelfFiles")
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                Text("我的书架由应用管理固定的本机与 iCloud 目录，小说文件由 iCloud Drive 同步。外部文件夹仍在原位置管理。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).padding(.horizontal, 4)
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.pageScrollMargins()
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
