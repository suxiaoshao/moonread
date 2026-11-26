import MoonreadCoreBindings
import SwiftUI

struct CloudSettingsView: View {
    @Environment(CloudStore.self) private var cloud
    @Environment(\.theme) private var theme
    @State private var replacing: String?
    @State private var showingSyncInfo = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("阅读数据 iCloud 同步", isOn: Binding(get: { cloud.status.requested }, set: cloud.setEnabled))
                        .font(.headline).disabled(cloud.busy).accessibilityIdentifier("readingDataSyncToggle")
                    if cloud.syncCard != .off {
                        ThemedDivider()
                        CloudSyncStatusRow(card: cloud.syncCard, canRetry: cloud.status.canRetry, busy: cloud.busy,
                                           retry: cloud.retry, confirm: cloud.requestConfirmation)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                HStack(spacing: 8) {
                    Text("同步阅读进度、批注、统计等数据，不包括小说文件。")
                    Button {
                        showingSyncInfo = true
                    } label: {
                        Image(systemName: "info.circle").font(.body)
                            .foregroundStyle(Color(uiColor: theme.accent))
                            .frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityLabel("同步说明")
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
            }.padding([.horizontal, .top], 20).padding(.bottom).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle("iCloud").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSyncInfo) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("阅读进度、书签、批注、小说信息、配色方案、手选编码和阅读统计会通过 iCloud 同步。")
                        Text("显示与阅读偏好留在本机。")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }
                .themedPage().navigationTitle("同步说明").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showingSyncInfo = false } }
                }
            }
            .themeScope(theme)
            .presentationBackground(Color(uiColor: theme.canvas))
            .presentationDetents([.medium, .large])
        }
        .task { await cloud.updateStatus() }
        .alert("是否将本机阅读数据同步到此账户？",
               isPresented: Binding(get: { cloud.confirmationAccount != nil }, set: { if !$0 { cloud.confirmationAccount = nil } }),
               presenting: cloud.confirmationAccount) { account in
            Button("同步到此账户") { cloud.confirmAccount(account) }.accessibilityIdentifier("approveCloudAccount")
            Button("取消", role: .cancel) { cloud.confirmationAccount = nil }
        } message: { _ in Text("仅同步当前本机仍存在的阅读数据，不移动小说文件。") }
        .alert("替换同名文件？", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }), presenting: replacing) { path in
            Button("替换", role: .destructive) { replacing = nil; cloud.replaceCloudFile(path) }
            Button("取消", role: .cancel) { replacing = nil }
        } message: { path in Text("iCloud 中已有“\(path)”，替换后将使用本机文件。取消会保留两处原件。") }
        .alert("暂时无法完成", isPresented: Binding(get: { cloud.error != nil }, set: { if !$0 { cloud.error = nil } })) {
            Button("知道了", role: .cancel) { cloud.error = nil }
        } message: { Text(cloud.error ?? "") }
    }
}

private struct CloudSyncStatusRow: View {
    let card: CloudSyncCard
    let canRetry: Bool
    let busy: Bool
    let retry: () -> Void
    let confirm: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        switch card {
        case .off: EmptyView()
        case .checking: line(Text("正在处理"), spinning: true)
        case .confirmAccount:
            line(Text("需要确认同步账户"), symbol: "icloud") {
                Button("确认同步到此账户", action: confirm)
                    .buttonStyle(ThemedProminentButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("confirmCloudAccount")
            }
        case .signedOut: line(Text("登录 iCloud 后才能同步"), symbol: "icloud")
        case .unavailable(let issue), .error(let issue):
            line(Text(issue.title), symbol: "exclamationmark.icloud") {
                if canRetry { action("重试") }
            }
        case .syncing: line(Text("正在同步"), spinning: true)
        case .firstUpload(let progress):
            line(Text("正在上传阅读数据"), spinning: progress == nil) {
                if let progress {
                    ProgressView(value: Double(progress.processed), total: Double(progress.total))
                        .progressViewStyle(.linear).accessibilityHidden(true)
                    count(Text("\(progress.processed.formatted()) / \(progress.total.formatted()) 项已处理"))
                }
            }
        case .firstDownload(let received):
            line(Text("正在下载阅读数据"), spinning: true) {
                if let received { count(Text("已接收 \(received.formatted()) 条")) }
            }
        case .finishing: line(Text("正在完成同步"), spinning: true)
        case .waitingForDevice:
            line(Text("等待另一台设备完成同步"), symbol: "icloud") { action("检查同步状态") }
        case .waiting: line(Text("等待同步"), symbol: "icloud")
        case .synced(let time):
            let relative = Text(TimeDataSource<Date>.currentDate, format: .reference(to: time, maxFieldCount: 1))
            line(Text("上次同步：\(relative)"), symbol: "icloud")
        }
    }

    private func line(_ title: Text, symbol: String? = nil, spinning: Bool = false,
                      @ViewBuilder details: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if spinning { ProgressView().controlSize(.small).accessibilityHidden(true) }
            else if let symbol {
                Image(systemName: symbol).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                title.font(.headline).accessibilityIdentifier("cloudSyncStatus")
                details()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func action(_ label: LocalizedStringKey) -> some View {
        Button(label, action: retry).font(.subheadline).buttonStyle(.borderless).disabled(busy)
    }
    private func count(_ text: Text) -> some View {
        text.font(.footnote.monospacedDigit()).foregroundStyle(Color(uiColor: theme.secondary))
    }
}

private extension CloudSyncIssue {
    var title: LocalizedStringResource {
        switch self {
        case .offline: "网络连接已断开"
        case .quota: "iCloud 空间不足"
        case .unavailable: "暂时无法连接 iCloud"
        case .restricted: "此设备的 iCloud 访问受限"
        case .unsupportedBuild: "此版本不支持阅读数据 iCloud 同步"
        case .paused: "阅读数据同步已暂停"
        case .incomplete: "阅读数据同步尚未完成"
        }
    }
}
