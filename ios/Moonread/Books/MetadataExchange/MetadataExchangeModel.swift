import SwiftUI

@MainActor @Observable final class MetadataExchangeModel {
    let service: AppDataService
    struct Issue: Identifiable {
        let id: Int
        let value: MetadataDiagnostic
    }
    private struct Review {
        var preview: MetadataImportPreview
        var result: MetadataBatchResult?
    }
    private struct ApplyContext {
        let token = UUID()
        let preview: MetadataImportPreview
        var completed = 0
        let total: Int
        var cancellationRequested = false
    }
    private enum ExchangeState {
        case idle
        case reading(previous: Review?)
        case reviewing(MetadataImportPreview)
        case applying(ApplyContext)
        case finished(MetadataImportPreview, MetadataBatchResult)
        case failed(String, previous: Review?)

        var review: Review? {
            switch self {
            case .idle: nil
            case .reading(let previous), .failed(_, let previous): previous
            case .reviewing(let preview): Review(preview: preview)
            case .applying(let context): Review(preview: context.preview)
            case .finished(let preview, let result): Review(preview: preview, result: result)
            }
        }
    }
    private var state = ExchangeState.idle
    var preview: MetadataImportPreview? { state.review?.preview }
    var issues: [Issue] { (preview?.diagnostics ?? []).enumerated().map { Issue(id: $0.offset, value: $0.element) } }
    var result: MetadataBatchResult? { state.review?.result }
    var loading: Bool { if case .reading = state { true } else { false } }
    var saving: Bool { if case .applying = state { true } else { false } }
    var cancellationRequested: Bool { applying?.cancellationRequested ?? false }
    var error: String? { if case .failed(let message, _) = state { message } else { nil } }
    var completed: Int { applying?.completed ?? 0 }
    var total: Int { applying?.total ?? 0 }
    private var applying: ApplyContext? { if case .applying(let context) = state { context } else { nil } }

    func showError(_ message: String) { state = .failed(message, previous: state.review) }
    func review(_ preview: MetadataImportPreview) { state = .reviewing(preview) }
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
        guard !loading, !saving else { return }
        state = .reading(previous: nil); query = ""; filter = 0
        do { review(try await service.previewMetadata(url)) }
        catch { showError(ReaderMessages.error(error)) }
    }
    func binding(_ id: String) -> Binding<MetadataPreviewBook>? {
        guard let book = books.first(where: { $0.id == id }) else { return nil }
        return Binding(get: { self.books.first { $0.id == id } ?? book }, set: { value in
            guard !self.saving, !self.loading, var preview = self.preview,
                  let index = preview.books.firstIndex(where: { $0.id == id }) else { return }
            var value = value
            value.validateSelection(using: self.service)
            preview.books[index] = value
            self.review(preview)
        })
    }
    func adopt(_ enabled: Bool, replaceTags: Bool = false) {
        guard !saving, !loading, var preview else { return }
        for index in preview.books.indices {
            preview.books[index].adopt(enabled, replaceTags: replaceTags)
            preview.books[index].validateSelection(using: service)
        }
        review(preview)
    }
    var confirmation: String {
        let clear = pending.reduce(0) { $0 + $1.fields.filter { $0.chosen?.clearing == true }.count }
        let removed = pending.reduce(0) { $0 + Set($1.base?.tags ?? []).subtracting($1.edited?.tags ?? []).count }
        let rename = pending.filter { $0.renameName != nil }.count
        return String(localized: "保存 \(pending.count) 本资料，清空 \(clear) 个字段，移除 \(removed) 个标签，改名 \(rename) 个文件。已保存的资料不会因取消或后续失败撤回。", table: "MetadataExchange")
    }
    func save() async {
        guard !saving, !loading, !invalidSelection, !pending.isEmpty, let preview else { return }
        let context = ApplyContext(preview: preview, total: pending.count)
        state = .applying(context)
        let task = Task {
            let result = await service.applyMetadata(preview) { completed, _ in
                await MainActor.run {
                    guard var current = self.applying, current.token == context.token else { return }
                    current.completed = completed
                    self.state = .applying(current)
                }
            }
            guard self.applying?.token == context.token else { return }
            self.state = .finished(preview, result)
        }
        work = task; await task.value; work = nil
    }
    func cancel() {
        guard var context = applying else { return }
        context.cancellationRequested = true
        state = .applying(context)
        work?.cancel()
    }
    func reviewAgain() async {
        guard !saving, !loading, let previous = state.review else { return }
        state = .reading(previous: previous)
        do { review(try await service.metadataPreview(previous.preview.session)) }
        catch { showError(ReaderMessages.error(error)) }
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
