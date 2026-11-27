import MoonreadDataTypes
import MoonreadSettings
import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Whole-library reading data for Shortcuts. Where the file goes (Files, a server,
/// WebDAV) is the shortcut's choice; the format and merge rules are the Settings backup.
struct ExportReadingDataIntent: AppIntent {
    static let title: LocalizedStringResource = "导出阅读数据"
    static let description = IntentDescription("导出月读全部阅读数据的备份文件，包括进度、书签、批注、阅读统计和配色，与设置里的「导出备份」相同。")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let data: Data
        do { data = try await AppDataService.shared.shortcutReadingBackup() }
        catch { throw ShortcutReadingDataError(error) }
        return .result(value: IntentFile(data: data, filename: "Moonread.moonread-backup", type: .moonreadBackup))
    }
}

struct ImportReadingDataIntent: AppIntent {
    static let title: LocalizedStringResource = "导入阅读数据"
    static let description = IntentDescription("把月读阅读数据备份合并进来，规则与设置里的「导入备份」相同，但不经过预览：旧位置不会覆盖较新的位置；导入较早的备份时，本机已删除但备份里还有的阅读数据会恢复。")

    // The backup type conforms to zip, and downloaded content often arrives as plain data;
    // the archive check rejects anything that is not a Moonread backup.
    @Parameter(title: "备份文件", supportedContentTypes: [.zip, .data]) var file: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("导入 \(\.$file) 到月读阅读数据") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shortcut-import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let record: ShortcutBackupImportRecord
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent("Moonread.moonread-backup")
            try file.data.write(to: archive)
            let outcome = try await AppDataService.shared.importShortcutReadingBackup(archive)
            record = .init(fileName: file.filename, books: outcome.books, kept: outcome.kept, globalUpdated: outcome.globalUpdated)
        } catch { throw ShortcutReadingDataError(error) }
        record.save()
        return .result(value: record.summary, dialog: "\(record.summary)")
    }
}

private struct ShortcutReadingDataError: LocalizedError {
    let message: String
    init(_ error: Error) { message = ReaderMessages.error(error) }
    var errorDescription: String? { message }
}
