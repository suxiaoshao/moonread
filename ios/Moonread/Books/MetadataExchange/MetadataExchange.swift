import Foundation

/// The import owns disposable package contents and cover drafts, never the source file.
final class MetadataImportSession: @unchecked Sendable {
    let document: MetadataDocument
    let configuration: UUID
    private var drafts: [URL] = []
    init(document: MetadataDocument, configuration: UUID) { self.document = document; self.configuration = configuration }
    func retainDraft(_ url: URL) { drafts.append(url) }
    deinit { for url in drafts { try? FileManager.default.removeItem(at: url) } }
}

enum MetadataField: String, CaseIterable, Identifiable, Sendable {
    case author, tags, description, cover, readingState, title
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
struct MetadataPreviewBook: Identifiable, Sendable {
    let id: String
    let title: String
    let base: BookMetadata?
    let source: LibraryEntry?
    let sourceCount: Int
    var fields: [MetadataFieldChoice]
    var messages: [String]
    var selectionError: String?
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
    let message: String?
}
struct MetadataBatchResult: Sendable {
    var outcomes: [MetadataImportOutcome] = []
    var remaining: [MetadataImportOutcome] = []
    var cancelled = false
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
