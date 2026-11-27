import MoonreadDesign
import SwiftUI

public struct DataManagementPage<Metadata: View, Backup: View, Issues: View, Records: View, Deletion: View>: View {
    @Environment(\.theme) private var theme
    let issueCount: Int?
    let message: String?
    let error: String?
    let metadata: () -> Metadata
    let backup: () -> Backup
    let issues: () -> Issues
    let records: () -> Records
    let deletion: () -> Deletion

    public init(
        issueCount: Int?, message: String?, error: String?,
        @ViewBuilder metadata: @escaping () -> Metadata, @ViewBuilder backup: @escaping () -> Backup,
        @ViewBuilder issues: @escaping () -> Issues, @ViewBuilder records: @escaping () -> Records,
        @ViewBuilder deletion: @escaping () -> Deletion
    ) {
        self.issueCount = issueCount
        self.message = message
        self.error = error
        self.metadata = metadata
        self.backup = backup
        self.issues = issues
        self.records = records
        self.deletion = deletion
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                metadata()
                VStack(alignment: .leading, spacing: 16) {
                    Label { Text("阅读数据备份", tableName: "MetadataExchange") } icon: { Image(systemName: "externaldrive") }.font(.headline)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("备份进度、书签、笔记等阅读数据，与小说信息分开。", tableName: "MetadataExchange").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        backup()
                        if let message { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
                        if let error { Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("readingDataError") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let issueCount, issueCount > 0 {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle")
                        Text("\(issueCount) 项需要处理", tableName: "DataManagement")
                        Spacer()
                        NavigationLink { issues() } label: { Text("查看", tableName: "DataManagement") }
                            .accessibilityIdentifier("readingDataIssues")
                    }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                } else if issueCount == nil {
                    NavigationLink { issues() } label: {
                        HStack {
                            Label { Text("需要处理", tableName: "DataManagement") } icon: { Image(systemName: "exclamationmark.circle") }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityIdentifier("readingDataIssues")
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("阅读数据", tableName: "DataManagement").font(.headline)
                    NavigationLink { records() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("查看与删除", tableName: "MetadataExchange").font(.body.weight(.medium))
                                Text("管理保存在月读的阅读记录", tableName: "MetadataExchange").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote)
                        }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 12))
                    }.accessibilityIdentifier("readingDataList")
                    deletion()
                }
            }.padding(20).frame(maxWidth: 690, alignment: .leading).frame(maxWidth: .infinity)
        }
        .themedPage().navigationTitle(Text("数据管理", tableName: "DataManagement"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
