import SwiftUI

@MainActor @Observable final class MetadataExchangeModel {
    let service: AppDataService
    var preview: MetadataImportPreview?
    struct Issue: Identifiable {
        let id = UUID()
        let value: MetadataDiagnostic
    }
    var issues: [Issue] = []
    var result: MetadataBatchResult?
    var loading = false
    var saving = false
    var cancellationRequested = false
    var error: String?
    var completed = 0
    var total = 0
    var query = ""
    var filter = 0
    private var work: Task<Void, Never>?
    init(service: AppDataService) { self.service = service }
    var books: [MetadataPreviewBook] { preview?.books ?? [] }
    var invalidSelection: Bool { books.contains { $0.selectionError != nil } }
    var pending: [MetadataPreviewBook] { books.filter { $0.disposition == .changes } }
    var unchangedCount: Int { books.filter { $0.disposition == .unchanged }.count }
    var unmatchedCount: Int { books.filter { $0.disposition == .unmatched }.count }
    var skippedCount: Int { books.filter { $0.disposition == .skipped }.count }
    var visible: [MetadataPreviewBook] {
        books.filter { book in
            (query.isEmpty || LibraryQueryRules.selectionMatches(book.title, query: query)) &&
            (filter == 0 || (filter == 1 ? book.disposition == .changes : book.disposition != .changes))
        }
    }
    func load(_ url: URL) async {
        loading = true; error = nil; preview = nil; result = nil; issues = []; query = ""; filter = 0
        defer { loading = false }
        do { preview = try await service.previewMetadata(url); issues = (preview?.diagnostics ?? []).map { Issue(value: $0) } }
        catch { self.error = ReaderMessages.error(error) }
    }
    func binding(_ id: String) -> Binding<MetadataPreviewBook>? {
        guard let book = books.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.books.first { $0.id == id } ?? book }, set: { value in
            guard let index = self.preview?.books.firstIndex(where: { $0.id == id }) else { return }; var value = value; value.validateSelection(using: self.service); self.preview?.books[index] = value
        })
    }
    func adopt(_ enabled: Bool, replaceTags: Bool = false) {
        guard preview != nil else { return }
        for index in preview!.books.indices { preview!.books[index].adopt(enabled, replaceTags: replaceTags); preview!.books[index].validateSelection(using: service) }
    }
    var confirmation: String {
        let clear = pending.reduce(0) { $0 + $1.fields.filter { $0.chosen?.clearing == true }.count }
        let removed = pending.reduce(0) { $0 + Set($1.base?.tags ?? []).subtracting($1.edited?.tags ?? []).count }
        let rename = pending.filter { $0.renameName != nil }.count
        return String(localized: "保存 \(pending.count) 本资料，清空 \(clear) 个字段，移除 \(removed) 个标签，改名 \(rename) 个文件。已保存的资料不会因取消或后续失败撤回。", table: "MetadataExchange")
    }
    func save() async {
        guard !saving, !invalidSelection, !pending.isEmpty, let preview else { return }
        saving = true; cancellationRequested = false; completed = 0; total = pending.count; error = nil
        let task = Task {
            self.result = await service.applyMetadata(preview) { completed, total in
                await MainActor.run { self.completed = completed; self.total = total }
            }
        }
        work = task; await task.value; work = nil; saving = false
    }
    func cancel() { guard work != nil else { return }; cancellationRequested = true; work?.cancel() }
    func reviewAgain() async {
        guard let session = preview?.session else { return }
        loading = true; error = nil
        defer { loading = false }
        do { preview = try await service.metadataPreview(session); issues = (preview?.diagnostics ?? []).map { Issue(value: $0) }; result = nil }
        catch { self.error = ReaderMessages.error(error) }
    }
    func diagnosticFile() throws -> LibraryExport? {
        guard let diagnostics = preview?.diagnostics, !diagnostics.isEmpty else { return nil }
        return try LibraryExport { directory in
            let url = directory.appendingPathComponent("metadata-errors.jsonl")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            for item in diagnostics {
                struct Diagnostic: Encodable {
                    let sourceLine: UInt64?, recordIndex: UInt64?
                    let code: String, field: String?, contentSha256: String?, message: String
                }
                try handle.write(contentsOf: encoder.encode(Diagnostic(sourceLine: item.sourceLine, recordIndex: item.recordIndex, code: item.code, field: item.field, contentSha256: item.contentSha256, message: item.message)))
                try handle.write(contentsOf: Data([10]))
            }
            return [url]
        }
    }
}
