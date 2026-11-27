import MoonreadDesign
import SwiftUI

/// The latest Shortcuts backup import. Shortcuts apply backups without a preview,
/// so Settings keeps this device-local summary for review afterwards.
public struct ShortcutBackupImportRecord: Codable, Equatable, Sendable {
    public let date: Date
    public let fileName: String?
    public let updatedTitles: [String?]
    public let kept: Int
    public let globalUpdated: Bool

    public init(date: Date = Date(), fileName: String?, updatedTitles: [String?], kept: Int, globalUpdated: Bool) {
        self.date = date; self.fileName = fileName; self.updatedTitles = updatedTitles
        self.kept = kept; self.globalUpdated = globalUpdated
    }

    static let key = "Moonread.shortcutBackupImport.v1"
    public static func load(_ defaults: UserDefaults = .standard) -> Self? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    public func save(_ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
        NotificationCenter.default.post(name: .shortcutBackupImportRecorded, object: nil)
    }

    public var changed: Bool { !updatedTitles.isEmpty || globalUpdated }

    /// One sentence shared by the Shortcuts result and the Settings row.
    public var summary: String {
        guard changed else { return String(localized: "没有需要更新的内容", table: "DataManagement") }
        var parts: [String] = []
        if !updatedTitles.isEmpty { parts.append(String(localized: "更新了 \(updatedTitles.count) 本书", table: "DataManagement")) }
        if globalUpdated { parts.append(String(localized: "更新了配色等全局数据", table: "DataManagement")) }
        if kept > 0 { parts.append(String(localized: "\(kept) 本保留本机较新的内容", table: "DataManagement")) }
        return parts.formatted(.list(type: .and, width: .narrow))
    }
}

public extension Notification.Name {
    static let shortcutBackupImportRecorded = Notification.Name("Moonread.shortcutBackupImportRecorded")
}

struct ShortcutBackupImportSummary: View {
    @Environment(\.theme) private var theme
    @State private var record = ShortcutBackupImportRecord.load()
    @State private var showing = false

    var body: some View {
        Group {
            if let record {
                DataExchangeTaskSummary(symbol: "square.2.layers.3d", iconColor: theme.secondary,
                                        link: Text("查看", tableName: "MetadataExchange"), open: { showing = true }) {
                    Text("快捷指令导入", tableName: "DataManagement")
                } detail: {
                    Text(verbatim: "\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.summary)")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
                .accessibilityIdentifier("shortcutBackupImportRecord")
                .sheet(isPresented: $showing) { ShortcutBackupImportRecordView(record: record).presentationSizing(.page) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shortcutBackupImportRecorded).receive(on: DispatchQueue.main)) { _ in
            record = ShortcutBackupImportRecord.load()
        }
    }
}

private struct ShortcutBackupImportRecordView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let record: ShortcutBackupImportRecord

    private struct Row: Identifiable { let id: Int; let title: String? }

    var body: some View {
        DataExchangeTaskSheet(title: Text("快捷指令导入", tableName: "DataManagement"), sharing: .constant(nil), onShared: {},
                              closeIdentifier: "closeShortcutImportRecord") {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: record.summary).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        Text(verbatim: [record.date.formatted(date: .long, time: .shortened), record.fileName].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(.vertical, 8)
                    if !record.updatedTitles.isEmpty {
                        Text("更新的书", tableName: "DataManagement").font(.headline).accessibilityAddTraits(.isHeader)
                        MetadataReviewRows(rows: record.updatedTitles.enumerated().map { Row(id: $0.offset, title: $0.element) }) { row in
                            Group {
                                if let title = row.title { Text(verbatim: title) }
                                else { Text("未知小说", tableName: "DataManagement") }
                            }
                            .font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("快捷指令导入不经过预览，按与「导入备份」相同的规则合并：旧位置不会覆盖较新的位置。导入较早的备份时，本机已删除但备份里还有的阅读数据会恢复。", tableName: "DataManagement")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }.padding(20).frame(maxWidth: 690).frame(maxWidth: .infinity)
            }
        } footer: {
            MetadataTaskActions {
                Button { dismiss() } label: { Text("完成", tableName: "MetadataExchange").frame(maxWidth: .infinity) }
                    .buttonStyle(MetadataActionButtonStyle(prominent: true))
            }
        }
    }
}
