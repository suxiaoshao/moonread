import MoonreadDesign
import MoonreadDataTypes
import MoonreadData
import MoonreadCoreBindings
import Foundation

/// The import owns disposable package contents and cover drafts, never the source file.
public final class MetadataImportSession: @unchecked Sendable {
    public let document: MetadataImportDocument
    public let configuration: UUID
    private var drafts: Set<URL> = []
    public init(document: MetadataImportDocument, configuration: UUID) { self.document = document; self.configuration = configuration }
    public func retainDrafts(_ urls: [URL]) { drafts.formUnion(urls) }
    deinit { for url in drafts { try? FileManager.default.removeItem(at: url) } }
}

/// Rust exposes JSON record_index as a zero-based array subscript; JSONL uses a 1-based source_line.
public nonisolated func metadataSourceDescription(sourceLine: UInt64?, recordIndex: UInt64?) -> String? {
    if let sourceLine { return String(localized: "第 \(sourceLine) 行", table: "MetadataExchange") }
    return recordIndex.map { "books[\($0)]" }
}

public enum MetadataField: String, CaseIterable, Identifiable, Sendable {
    case author, description, tags, readingState, cover, title
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .author: String(localized: "作者")
        case .tags: String(localized: "标签")
        case .description: String(localized: "简介")
        case .cover: String(localized: "封面")
        case .readingState: String(localized: "阅读状态")
        case .title: String(localized: "修改文件名", table: "MetadataExchange")
        }
    }
    public var metadataKey: String {
        switch self { case .description: "synopsis"; case .readingState: "status"; default: rawValue }
    }
    public var transportKey: String { self == .readingState ? "reading_state" : rawValue }
}
public struct MetadataOption: Identifiable, Sendable {
    public let id: String
    public var text: String?
    public var tags: [String] = []
    public var cover: BookCoverAsset?
    public var sources: [String]
    public var clearing = false
    public var display: String {
        if clearing { return String(localized: "将清空", table: "MetadataExchange") }
        if let cover { return "\(cover.width) × \(cover.height)" }
        if text == "tags" { return tags.isEmpty ? String(localized: "没有标签", table: "MetadataExchange") : tags.joined(separator: "、") }
        return text ?? ""
    }
    public static func status(_ text: String) -> BookReadingStatus? {
        switch text { case "unread": .unread; case "reading": .reading; case "finished": .finished; case "paused": .paused; default: nil }
    }

    public init(id: String,
                text: String? = nil,
                tags: [String] = [],
                cover: BookCoverAsset? = nil,
                sources: [String],
                clearing: Bool = false) {
        self.id = id
        self.text = text
        self.tags = tags
        self.cover = cover
        self.sources = sources
        self.clearing = clearing
    }
}
public struct MetadataFieldChoice: Identifiable, Sendable {
    public let field: MetadataField
    public var options: [MetadataOption]
    public var selected: String?
    public var replaceTags = false
    public var id: MetadataField { field }
    public var chosen: MetadataOption? { options.first { $0.id == selected } }

    public init(field: MetadataField, options: [MetadataOption], selected: String? = nil, replaceTags: Bool = false) {
        self.field = field
        self.options = options
        self.selected = selected
        self.replaceTags = replaceTags
    }
}
public enum MetadataPreviewDisposition: Equatable, Sendable {
    case changes, unchanged, unmatched, skipped
}
public struct MetadataPreviewBook: Identifiable, Sendable {
    public let id: String
    public let title: String
    public enum Source: Sendable {
        case none
        case unique(MetadataExchangeFile)
        case multiple(Int)

        public init(_ book: MetadataExchangeBook?) {
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
    public struct MatchedBook: Sendable {
        public let base: BookMetadata
        public let source: Source
        public var choices: [MetadataFieldChoice] = []
        public var selectionError: String?

        public init(base: BookMetadata, source: Source, choices: [MetadataFieldChoice] = [], selectionError: String? = nil) {
            self.base = base
            self.source = source
            self.choices = choices
            self.selectionError = selectionError
        }
    }
    public enum Match: Sendable {
        case unmatched
        case skipped(reason: String, Source)
        case matched(MatchedBook)
    }
    public var match: Match
    public var messages: [String] = []
    public var base: BookMetadata? { if case .matched(let book) = match { book.base } else { nil } }
    public var source: MetadataExchangeFile? {
        guard case .matched(let book) = match, case .unique(let source) = book.source else { return nil }
        return source
    }
    public var sourceCount: Int {
        switch match {
        case .unmatched: 0
        case .skipped(_, let source): source.count
        case .matched(let book): book.source.count
        }
    }
    public var fields: [MetadataFieldChoice] {
        get { if case .matched(let book) = match { book.choices } else { [] } }
        set {
            guard case .matched(var book) = match else { return }
            book.choices = newValue
            match = .matched(book)
        }
    }
    public var selectionError: String? {
        get { if case .matched(let book) = match { book.selectionError } else { nil } }
        set {
            guard case .matched(var book) = match else { return }
            book.selectionError = newValue
            match = .matched(book)
        }
    }
    public var coverFiles: [String] = []
    public var coverUnavailable = false
    public var incomingCovers: [MetadataOption] { fields.first { $0.field == .cover }?.options.filter { $0.cover != nil } ?? [] }
    public mutating func validateSelection() {
        guard let base, let edited else { selectionError = nil; return }
        do {
            _ = try BookMetadataEditPlan.make(base: base, edited: edited, fields: Set(fields.filter { $0.chosen != nil }.map { $0.field.metadataKey }))
            selectionError = nil
        } catch {
            selectionError = String(localized: "所选资料超出编辑限制；请减少标签、改为替换或保留现有值。", table: "MetadataExchange")
        }
    }
    public func suggestedName(_ option: MetadataOption) -> String? {
        guard let stem = option.text, let source else { return nil }
        let ext = (source.name as NSString).pathExtension
        return stem + (ext.isEmpty ? "" : "." + ext)
    }
    public var renameName: String? {
        guard let option = fields.first(where: { $0.field == .title })?.chosen,
              let name = suggestedName(option), name != source?.name else { return nil }
        return name
    }
    public var edited: BookMetadata? {
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
    public var disposition: MetadataPreviewDisposition {
        switch match {
        case .unmatched: .unmatched
        case .skipped: .skipped
        case .matched:
            !changedFields.isEmpty ? .changes : messages.isEmpty ? .unchanged : .skipped
        }
    }
    public var summary: String {
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
    public var hasSuggestedChanges: Bool {
        for index in fields.indices {
            for option in fields[index].options {
                var proposed = self; proposed.fields[index].selected = option.id
                if proposed.changedFields.contains(fields[index].field) { return true }
            }
        }
        return false
    }
    public var changedMetadataFields: [MetadataField] { changedFields.filter { $0 != .title } }
    public var changedFields: [MetadataField] {
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
    public static func stateTitle(_ status: BookReadingStatus) -> String {
        switch status {
        case .unread: String(localized: "未读")
        case .reading: String(localized: "阅读中")
        case .finished: String(localized: "读完")
        case .paused: String(localized: "暂搁")
        case .other: String(localized: "其他（当前版本不支持）")
        }
    }
    public func current(_ field: MetadataField) -> String {
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

    public init(id: String,
                title: String,
                match: Match,
                messages: [String] = [],
                coverFiles: [String] = [],
                coverUnavailable: Bool = false) {
        self.id = id
        self.title = title
        self.match = match
        self.messages = messages
        self.coverFiles = coverFiles
        self.coverUnavailable = coverUnavailable
    }
}
public struct MetadataImportPreview: Sendable {
    public let session: MetadataImportSession
    public var books: [MetadataPreviewBook]
    public var diagnostics: [MetadataDiagnostic]

    public init(session: MetadataImportSession, books: [MetadataPreviewBook], diagnostics: [MetadataDiagnostic]) {
        self.session = session
        self.books = books
        self.diagnostics = diagnostics
    }
}
public struct MetadataImportOutcome: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let saved: Bool
    public var message: String?
    public var cover: BookCoverAsset? = nil
    public var savedFieldCount = 0
    public var renamed = false
    public var renameAttempted = false
    public var summary: String {
        if !saved && renamed { return String(localized: "文件已改名", table: "MetadataExchange") }
        if !saved && renameAttempted { return message ?? String(localized: "文件未改名", table: "MetadataExchange") }
        guard saved else { return message ?? String(localized: "尚未开始保存", table: "MetadataExchange") }
        var parts = [String(localized: "\(savedFieldCount) 项资料已保存", table: "MetadataExchange")]
        if renamed { parts.append(String(localized: "文件已改名", table: "MetadataExchange")) }
        return parts.joined(separator: " · ")
    }

    public init(id: String,
                title: String,
                saved: Bool,
                message: String? = nil,
                cover: BookCoverAsset? = nil,
                savedFieldCount: Int = 0,
                renamed: Bool = false,
                renameAttempted: Bool = false) {
        self.id = id
        self.title = title
        self.saved = saved
        self.message = message
        self.cover = cover
        self.savedFieldCount = savedFieldCount
        self.renamed = renamed
        self.renameAttempted = renameAttempted
    }
}
public struct MetadataBatchResult: Sendable {
    public var outcomes: [MetadataImportOutcome] = []
    public var remaining: [MetadataImportOutcome] = []
    public var cancelled = false
    public var requiresNewPreview = false
    public var failure: String?
    public var remainingRenames: [MetadataImportOutcome] = []

    public init(outcomes: [MetadataImportOutcome] = [],
                remaining: [MetadataImportOutcome] = [],
                cancelled: Bool = false,
                requiresNewPreview: Bool = false,
                failure: String? = nil,
                remainingRenames: [MetadataImportOutcome] = []) {
        self.outcomes = outcomes
        self.remaining = remaining
        self.cancelled = cancelled
        self.requiresNewPreview = requiresNewPreview
        self.failure = failure
        self.remainingRenames = remainingRenames
    }
}

public struct MetadataBatchBudget: Equatable, Sendable {
    public var keys: Int
    public var text: Int
    public var covers: Int
    public static let target = Self(keys: 512, text: 4 * 1024 * 1024, covers: 4 * 1024 * 1024)
    public static let zero = Self(keys: 0, text: 0, covers: 0)

    public func adding(_ cost: Self, within limit: Self) -> Self? {
        guard keys <= limit.keys, text <= limit.text, covers <= limit.covers,
              cost.keys <= limit.keys - keys, cost.text <= limit.text - text, cost.covers <= limit.covers - covers else { return nil }
        return .init(keys: keys + cost.keys, text: text + cost.text, covers: covers + cost.covers)
    }

    public init(keys: Int, text: Int, covers: Int) {
        self.keys = keys
        self.text = text
        self.covers = covers
    }
}

public struct MetadataApplyProgress: Sendable {
    public enum Phase: Sendable { case saving, renaming }
    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public enum MetadataPreparationProgress: Sendable {
    case readingPackage
    case matchingBooks(Int)
    case preparingBooks(completed: Int, total: Int)
}

public struct MetadataConfirmedImport: Sendable {
    public let session: MetadataImportSession
    public let books: [MetadataPreviewBook]
    public let writeIndices: [Int]
    public let renameIndices: [Int]
    public let lease: DataSessionLease
    public let deletionTokens: [String: UUID]
    public var committed = 0
    public var renamedThrough = 0
    public var outcomes: [Int: MetadataImportOutcome] = [:]

    public init(session: MetadataImportSession,
                books: [MetadataPreviewBook],
                writeIndices: [Int],
                renameIndices: [Int],
                lease: DataSessionLease,
                deletionTokens: [String: UUID],
                committed: Int = 0,
                renamedThrough: Int = 0,
                outcomes: [Int: MetadataImportOutcome] = [:]) {
        self.session = session
        self.books = books
        self.writeIndices = writeIndices
        self.renameIndices = renameIndices
        self.lease = lease
        self.deletionTokens = deletionTokens
        self.committed = committed
        self.renamedThrough = renamedThrough
        self.outcomes = outcomes
    }
}
public struct MetadataSkippedFile: Identifiable, Sendable {
    public let id: String
    public let shelf: String
    public let path: String

    public init(id: String, shelf: String, path: String) {
        self.id = id
        self.shelf = shelf
        self.path = path
    }
}
public struct MetadataExportResult: Sendable {
    public let file: ShareFiles
    public let count: Int
    public let skipped: [MetadataSkippedFile]
    public let warnings: [String]
    public func shareCopy() throws -> ShareFiles {
        try ShareFiles { directory in
            try file.urls.map { source in
                let target = directory.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
        }
    }

    public init(file: ShareFiles, count: Int, skipped: [MetadataSkippedFile], warnings: [String]) {
        self.file = file
        self.count = count
        self.skipped = skipped
        self.warnings = warnings
    }
}
