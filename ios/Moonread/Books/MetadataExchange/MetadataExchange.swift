import Foundation

/// The import owns disposable package contents and cover drafts, never the source file.
final class MetadataImportSession: @unchecked Sendable {
    let document: MetadataDocument
    let configuration: UUID
    private var drafts: Set<URL> = []
    init(document: MetadataDocument, configuration: UUID) { self.document = document; self.configuration = configuration }
    func retainDrafts(_ urls: [URL]) { drafts.formUnion(urls) }
    deinit { for url in drafts { try? FileManager.default.removeItem(at: url) } }
}

/// Rust exposes JSON record_index as a zero-based array subscript; JSONL uses a 1-based source_line.
nonisolated func metadataSourceDescription(sourceLine: UInt64?, recordIndex: UInt64?) -> String? {
    if let sourceLine { return String(localized: "第 \(sourceLine) 行", table: "MetadataExchange") }
    return recordIndex.map { "books[\($0)]" }
}

enum MetadataField: String, CaseIterable, Identifiable, Sendable {
    case author, description, tags, readingState, cover, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .author: String(localized: "作者")
        case .tags: String(localized: "标签")
        case .description: String(localized: "简介")
        case .cover: String(localized: "封面")
        case .readingState: String(localized: "阅读状态")
        case .title: String(localized: "修改文件名", table: "MetadataExchange")
        }
    }
    var metadataKey: String {
        switch self { case .description: "synopsis"; case .readingState: "status"; default: rawValue }
    }
    var transportKey: String { self == .readingState ? "reading_state" : rawValue }
}
struct MetadataOption: Identifiable, Sendable {
    let id: String
    var text: String?
    var tags: [String] = []
    var cover: BookCoverAsset?
    var sources: [String]
    var clearing = false
    var display: String {
        if clearing { return String(localized: "将清空", table: "MetadataExchange") }
        if let cover { return "\(cover.width) × \(cover.height)" }
        if text == "tags" { return tags.isEmpty ? String(localized: "没有标签", table: "MetadataExchange") : tags.joined(separator: "、") }
        return text ?? ""
    }
    static func status(_ text: String) -> BookReadingStatus? {
        switch text { case "unread": .unread; case "reading": .reading; case "finished": .finished; case "paused": .paused; default: nil }
    }
}
struct MetadataFieldChoice: Identifiable, Sendable {
    let field: MetadataField
    var options: [MetadataOption]
    var selected: String?
    var replaceTags = false
    var id: MetadataField { field }
    var chosen: MetadataOption? { options.first { $0.id == selected } }
}
enum MetadataPreviewDisposition: Equatable, Sendable {
    case changes, unchanged, unmatched, skipped
}
struct MetadataPreviewBook: Identifiable, Sendable {
    let id: String
    let title: String
    enum Source: Sendable {
        case none
        case unique(MetadataExchangeFile)
        case multiple(Int)

        init(_ book: MetadataExchangeBook?) {
            if let source = book?.uniqueSource { self = .unique(source) }
            else if let book { self = .multiple(Int(book.sourceCount)) }
            else { self = .none }
        }
        var count: Int {
            switch self {
            case .none: 0
            case .unique: 1
            case .multiple(let count): count
            }
        }
    }
    struct MatchedBook: Sendable {
        let base: BookMetadata
        let source: Source
        var choices: [MetadataFieldChoice] = []
        var selectionError: String?
    }
    enum Match: Sendable {
        case unmatched
        case skipped(reason: String, Source)
        case matched(MatchedBook)
    }
    var match: Match
    var messages: [String] = []
    var base: BookMetadata? { if case .matched(let book) = match { book.base } else { nil } }
    var source: MetadataExchangeFile? {
        guard case .matched(let book) = match, case .unique(let source) = book.source else { return nil }
        return source
    }
    var sourceCount: Int {
        switch match {
        case .unmatched: 0
        case .skipped(_, let source): source.count
        case .matched(let book): book.source.count
        }
    }
    var fields: [MetadataFieldChoice] {
        get { if case .matched(let book) = match { book.choices } else { [] } }
        set {
            guard case .matched(var book) = match else { return }
            book.choices = newValue
            match = .matched(book)
        }
    }
    var selectionError: String? {
        get { if case .matched(let book) = match { book.selectionError } else { nil } }
        set {
            guard case .matched(var book) = match else { return }
            book.selectionError = newValue
            match = .matched(book)
        }
    }
    var coverFiles: [String] = []
    var coverUnavailable = false
    var incomingCovers: [MetadataOption] { fields.first { $0.field == .cover }?.options.filter { $0.cover != nil } ?? [] }
    mutating func validateSelection(using service: AppDataService) {
        guard let base, let edited else { selectionError = nil; return }
        do {
            _ = try service.metadataEditPlan(base: base, edited: edited, fields: Set(fields.filter { $0.chosen != nil }.map { $0.field.metadataKey }))
            selectionError = nil
        } catch {
            selectionError = String(localized: "所选资料超出编辑限制；请减少标签、改为替换或保留现有值。", table: "MetadataExchange")
        }
    }
    func suggestedName(_ option: MetadataOption) -> String? {
        guard let stem = option.text, let source else { return nil }
        let ext = (source.name as NSString).pathExtension
        return stem + (ext.isEmpty ? "" : "." + ext)
    }
    var renameName: String? {
        guard let option = fields.first(where: { $0.field == .title })?.chosen,
              let name = suggestedName(option), name != source?.name else { return nil }
        return name
    }
    var edited: BookMetadata? {
        guard var value = base else { return nil }
        for choice in fields {
            guard let option = choice.chosen else { continue }
            switch choice.field {
            case .author: value.author = option.text ?? ""
            case .description: value.synopsis = option.text ?? ""
            case .tags: value.tags = option.clearing ? [] : choice.replaceTags ? option.tags : value.tags + option.tags
            case .cover: value.cover = option.cover
            case .readingState: if let text = option.text, let status = MetadataOption.status(text) { value.status = status }
            case .title: break
            }
        }
        return value.normalizedForSaving
    }
    /// Presentation classification only; skipped or unmatched data is never a successful no-op.
    var disposition: MetadataPreviewDisposition {
        switch match {
        case .unmatched: .unmatched
        case .skipped: .skipped
        case .matched:
            !changedFields.isEmpty ? .changes : messages.isEmpty ? .unchanged : .skipped
        }
    }
    var summary: String {
        switch disposition {
        case .changes:
            let changes = changedFields
            let fields = changedMetadataFields
            if fields.isEmpty { return String(localized: "仅修改文件名", table: "MetadataExchange") }
            var parts = [String(localized: "\(fields.count) 项将更新", table: "MetadataExchange")]
            if fields.contains(.cover) { parts.append(String(localized: "含封面", table: "MetadataExchange")) }
            if changes.contains(.title) { parts.append(String(localized: "文件将改名", table: "MetadataExchange")) }
            return parts.joined(separator: " · ")
        case .unchanged: return String(localized: "无变化", table: "MetadataExchange")
        case .unmatched: return String(localized: "未匹配", table: "MetadataExchange")
        case .skipped: return String(localized: "已跳过", table: "MetadataExchange")
        }
    }
    var hasSuggestedChanges: Bool {
        for index in fields.indices {
            for option in fields[index].options {
                var proposed = self; proposed.fields[index].selected = option.id
                if proposed.changedFields.contains(fields[index].field) { return true }
            }
        }
        return false
    }
    var changedMetadataFields: [MetadataField] { changedFields.filter { $0 != .title } }
    var changedFields: [MetadataField] {
        guard let base, let edited else { return [] }
        return fields.compactMap { choice in
            guard choice.chosen != nil else { return nil }
            let changed: Bool
            switch choice.field {
            case .author: changed = edited.author != base.author
            case .description: changed = edited.synopsis != base.synopsis
            case .tags: changed = Set(edited.tags) != Set(base.tags)
            case .cover: changed = edited.cover != base.cover
            case .readingState: changed = edited.status != base.status
            case .title: changed = renameName != nil
            }
            return changed ? choice.field : nil
        }
    }
    static func stateTitle(_ status: BookReadingStatus) -> String {
        switch status {
        case .unread: String(localized: "未读")
        case .reading: String(localized: "阅读中")
        case .finished: String(localized: "读完")
        case .paused: String(localized: "暂搁")
        case .other: String(localized: "其他（当前版本不支持）")
        }
    }
    func current(_ field: MetadataField) -> String {
        guard let base else { return "" }
        switch field {
        case .author: return base.author
        case .description: return base.synopsis
        case .tags: return base.tags.joined(separator: "、")
        case .cover: return base.cover == nil ? String(localized: "无", table: "MetadataExchange") : String(localized: "已有封面", table: "MetadataExchange")
        case .readingState: return Self.stateTitle(base.status)
        case .title: return source?.name ?? ""
        }
    }
    mutating func adopt(_ enabled: Bool, replaceTags: Bool = false) {
        for index in fields.indices {
            let choice = fields[index]
            // Bulk adoption never resolves conflicts or authorizes clear/rename.
            fields[index].selected = enabled && choice.field != .title && choice.options.count == 1 && !choice.options[0].clearing ? choice.options[0].id : nil
            if choice.field == .tags { fields[index].replaceTags = replaceTags }
        }
    }
}
struct MetadataImportPreview: Sendable {
    let session: MetadataImportSession
    var books: [MetadataPreviewBook]
    var diagnostics: [MetadataDiagnostic]
}
struct MetadataImportOutcome: Identifiable, Sendable {
    let id: String
    let title: String
    let saved: Bool
    var message: String?
    var cover: BookCoverAsset? = nil
    var savedFieldCount = 0
    var renamed = false
    var renameAttempted = false
    var summary: String {
        if !saved && renamed { return String(localized: "文件已改名", table: "MetadataExchange") }
        if !saved && renameAttempted { return message ?? String(localized: "文件未改名", table: "MetadataExchange") }
        guard saved else { return message ?? String(localized: "尚未开始保存", table: "MetadataExchange") }
        var parts = [String(localized: "\(savedFieldCount) 项资料已保存", table: "MetadataExchange")]
        if renamed { parts.append(String(localized: "文件已改名", table: "MetadataExchange")) }
        return parts.joined(separator: " · ")
    }
}
struct MetadataBatchResult: Sendable {
    var outcomes: [MetadataImportOutcome] = []
    var remaining: [MetadataImportOutcome] = []
    var cancelled = false
    var requiresNewPreview = false
    var failure: String?
    var remainingRenames: [MetadataImportOutcome] = []
}

struct MetadataBatchBudget: Equatable, Sendable {
    var keys: Int
    var text: Int
    var covers: Int
    static let target = Self(keys: 512, text: 4 * 1024 * 1024, covers: 4 * 1024 * 1024)
    static let zero = Self(keys: 0, text: 0, covers: 0)

    func adding(_ cost: Self, within limit: Self) -> Self? {
        guard keys <= limit.keys, text <= limit.text, covers <= limit.covers,
              cost.keys <= limit.keys - keys, cost.text <= limit.text - text, cost.covers <= limit.covers - covers else { return nil }
        return .init(keys: keys + cost.keys, text: text + cost.text, covers: covers + cost.covers)
    }
}

struct MetadataApplyProgress: Sendable {
    enum Phase: Sendable { case saving, renaming }
    let phase: Phase
    let completed: Int
    let total: Int
}

enum MetadataPreparationProgress: Sendable {
    case readingPackage
    case matchingBooks(Int)
    case preparingBooks(completed: Int, total: Int)
}

struct MetadataConfirmedImport: Sendable {
    let session: MetadataImportSession
    let books: [MetadataPreviewBook]
    let writeIndices: [Int]
    let renameIndices: [Int]
    let store: UserDataStore
    let storeID: UUID
    let deletionTokens: [String: UUID]
    var committed = 0
    var renamedThrough = 0
    var outcomes: [Int: MetadataImportOutcome] = [:]
}
struct MetadataSkippedFile: Identifiable, Sendable {
    let id: String
    let shelf: String
    let path: String
}
struct MetadataExportResult: Sendable {
    let file: LibraryExport
    let count: Int
    let skipped: [MetadataSkippedFile]
    let warnings: [String]
    func shareCopy() throws -> LibraryExport {
        try LibraryExport { directory in
            try file.urls.map { source in
                let target = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
        }
    }
}
