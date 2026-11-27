import MoonreadDesign
import MoonreadData
import SwiftUI

/// The latest Shortcuts backup import. Shortcuts apply backups without a preview,
/// so Settings keeps this device-local summary for review afterwards.
public struct ShortcutBackupImportRecord: Codable, Equatable, Sendable {
    /// One book the import changed, and which kinds of its reading data were restored.
    public struct Book: Codable, Equatable, Sendable {
        public let title: String?
        public let linked: Bool
        /// `BackupDataKind` raw values, in display order.
        public let restored: [String]
        public init(title: String?, linked: Bool, restored: [String]) { self.title = title; self.linked = linked; self.restored = restored }
    }
    public let date: Date
    public let fileName: String?
    public let books: [Book]
    public let kept: Int
    public let globalUpdated: Bool

    public init(date: Date = Date(), fileName: String?, books: [Book], kept: Int, globalUpdated: Bool) {
        self.date = date; self.fileName = fileName; self.books = books
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

    public var changed: Bool { !books.isEmpty || globalUpdated }

    /// One sentence shared by the Shortcuts result and the Settings row.
    public var summary: String {
        guard changed else { return String(localized: "没有需要更新的内容", table: "DataManagement") }
        var parts: [String] = []
        if !books.isEmpty { parts.append(String(localized: "更新了 \(books.count) 本书", table: "DataManagement")) }
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

    private struct Row: Identifiable { let id: Int; let book: ShortcutBackupImportRecord.Book }

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
                    if !record.books.isEmpty {
                        Text("更新的书", tableName: "DataManagement").font(.headline).accessibilityAddTraits(.isHeader)
                        // Same row as the import preview: title, then what was restored.
                        MetadataReviewRows(rows: record.books.enumerated().map { Row(id: $0.offset, book: $0.element) }) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Group {
                                    if let title = row.book.title { Text(verbatim: title) }
                                    else { Text("未知小说", tableName: "DataManagement") }
                                }.font(.body.weight(.medium)).foregroundStyle(Color(uiColor: theme.ink))
                                VStack(alignment: .leading, spacing: 2) {
                                    let kinds = row.book.restored.compactMap(BackupDataKind.init(rawValue:)).map(\.localizedName)
                                    if !kinds.isEmpty { Text("已恢复：\(kinds.formatted(.list(type: .and)))", tableName: "DataManagement") }
                                    if !row.book.linked { Text("未在书架", tableName: "DataManagement") }
                                }.font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
                        }
                    }
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
