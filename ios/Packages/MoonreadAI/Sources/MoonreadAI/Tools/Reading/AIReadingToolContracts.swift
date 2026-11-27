import AISDKProvider
import AISDKProviderUtils
import CryptoKit
import Foundation
import SwiftAISDK

public struct AIToolError: Error, LocalizedError, Sendable {
  public let code: String
  public let field: String?
  public let message: String
  public init(_ code: String, field: String? = nil, message: String? = nil) {
    self.code = code
    self.field = field
    self.message =
      message ?? [
        "not_found": "The referenced object is not available. Look it up again.",
        "stale_reference":
          "The reference no longer matches current content. Fetch a fresh reference.",
        "stale_cursor": "The query or content changed. Start again without cursor.",
        "needs_preparation": "Prepare the book before reading it.",
        "invalid_argument": "Check the supplied fields and their constraints.",
      ][code] ?? code
  }
  public var errorDescription: String? { field.map { "\($0): \(message)" } ?? message }
}

public protocol AIReadingInput: Codable, Sendable {
  static var constraints: [String: [String: JSONValue]] { get }
  func validate() throws
}
extension AIReadingInput {
  public static var constraints: [String: [String: JSONValue]] { [:] }
  public func validate() throws {}
  public static var schema: JSONValue {
    var root = JSONSchemaGenerator.generate(for: Self.self).object
    var fields = root["properties"]?.object ?? [:]
    let required = Set(root["required"]?.strings ?? [])
    for (name, field) in fields {
      var value = field.object
      if name.hasSuffix("Ref") || name == "cursor" {
        value["minLength"] = .number(1)
        value["description"] = .string(
          "Use a reference returned by a tool. Omit or use null when unused; never send an empty string."
        )
      }
      if name == "limit" {
        value["minimum"] = .number(1)
      }
      let descriptions: [String: String] = [
        "parentRef": "Folder reference from list_shelf. Omit to list shelf roots.",
        "scopeRef": "Shelf or folder reference from list_shelf; searches inside it. Omit for all shelves.",
        "fileRef": "File reference from list_shelf or find_books. Supply fileRef or bookRef, not both.",
        "prepare": "Default false. Set true only when the text must be prepared first; the app asks the reader.",
        "fromDate": "Inclusive local date YYYY-MM-DD.",
        "toDate": "Inclusive local date YYYY-MM-DD.",
        "view": "summary for totals; days/books/sessions for detail pages; chapters requires bookRef.",
        "markRef": "A mark from list_marks. With markRef the result is that mark with its full note, paged by cursor.",
        "variantRef": "One version of a conflicting annotation, from list_marks with markRef.",
        "bookRef": "Exact bookRef from the reading attachment or a book tool.",
        "bookRefs": "Exact bookRef values. Prefer one book.",
        "chapterRef": "Chapter from list_chapters; omit for the whole book.",
        "around": "A positionRef from search_text, read_text, list_chapters or list_marks; reads the paragraphs around it.",
        "beforeParagraphs": "Paragraphs before the position. Default 3.",
        "afterParagraphs": "Paragraphs after the position. Default 3.",
        "cursor": "Copy page.nextCursor for more, keeping the other fields unchanged. Omit on the first call.",
        "maxBytes": "Text size per page; default and maximum 51200. nextCursor continues without losing text.",
        "limit": "Maximum items on this page. Use nextCursor for more.",
        "maxHits": "Maximum matches on this page (default 100).",
        "caseSensitive": "Default true.",
        "mode": "regex (default) or literal. Write the pattern only, no command flags."
      ]
      if constraints[name]?["type"] != nil { value = [:] }
      for (key, constraint) in constraints[name] ?? [:] { value[key] = constraint }
      if let description = descriptions[name] { value["description"] = .string(description) }
      fields[name] =
        required.contains(name)
        ? .object(value)
        : .object(["anyOf": .array([.object(value), .object(["type": .string("null")])])])
    }
    root["properties"] = .object(fields)
    root["additionalProperties"] = .bool(false)
    return .object(root)
  }
}
// The pinned SDK cannot infer nil Optional<Enum/Array> fields. Keep enum
// values derived from the Codable type, and supplement only those schemas.
private func enumField<E: RawRepresentable & CaseIterable>(_ type: E.Type) -> [String: JSONValue]
where E.RawValue == String {
  ["type": .string("string"), "enum": .array(E.allCases.map { .string($0.rawValue) })]
}
public enum AIToolSort: String, Codable, CaseIterable, Sendable { case name, recent }
public enum AILibraryKind: String, Codable, CaseIterable, Sendable { case all, folders, books }
public enum AIMarkKind: String, Codable, CaseIterable, Sendable { case all, bookmark, annotation }
public enum AISearchMode: String, Codable, CaseIterable, Sendable { case literal, regex }
public enum AIReadingStatus: String, Codable, CaseIterable, Sendable {
  case unread, reading, finished, paused
}
/// A read filter can include unsupported states; mutation proposals still accept known states only.
public enum AIReadingStatusFilter: String, Codable, CaseIterable, Sendable {
  case unread, reading, finished, paused, other
}
public enum AIStatisticsView: String, Codable, CaseIterable, Sendable {
  case summary, days, books, sessions, chapters
}
public enum AIEnvironmentField: String, Codable, CaseIterable, Sendable { case time, locale }
public struct AILSInput: AIReadingInput {
  public var parentRef: String?
  public var kind: AILibraryKind?
  public var sort: AIToolSort?
  public var limit: Int?
  public var cursor: String?
  public static var constraints: [String: [String: JSONValue]] {
    ["kind": enumField(AILibraryKind.self), "sort": enumField(AIToolSort.self)]
  }
}
public struct AIGetBookInput: AIReadingInput {
  public var bookRef: String?
  public var fileRef: String?
  public var prepare: Bool?
}
public struct AIChaptersInput: AIReadingInput {
  public var bookRef: String
  public var query: String?
  public var limit: Int?
  public var cursor: String?
  public static var constraints: [String: [String: JSONValue]] { ["query": ["description": .string("Optional literal chapter-title filter, e.g. 番外 or 第316章. Omit to list all chapters.")]] }

    public init(
        bookRef: String,
        query: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) {
        self.bookRef = bookRef
        self.query = query
        self.limit = limit
        self.cursor = cursor
    }
}
public struct AIReadInput: AIReadingInput {
  public var bookRef: String
  public var chapterRef: String?
  public var around: String?
  public var beforeParagraphs: Int?
  public var afterParagraphs: Int?
  public var maxBytes: Int?
  public var cursor: String?
  public static var constraints: [String: [String: JSONValue]] {
    ["maxBytes": ["minimum": .number(1)],
     "beforeParagraphs": ["minimum": .number(0)],
     "afterParagraphs": ["minimum": .number(0)]]
  }
  public func validate() throws {
    if around == nil && (beforeParagraphs != nil || afterParagraphs != nil) {
      throw AIToolError("invalid_argument", field: "around", message: "beforeParagraphs/afterParagraphs need around.")
    }
  }
}
public struct AIRGInput: AIReadingInput {
  public var bookRefs: [String]
  public var chapterRef: String?
  public var query: String
  public var mode: AISearchMode?
  public var caseSensitive: Bool?
  public var maxHits: Int?
  public var cursor: String?
  public func validate() throws {
    if chapterRef != nil && bookRefs.count != 1 {
      throw AIToolError("invalid_argument", field: "bookRefs", message: "chapterRef requires exactly one book.")
    }
  }
  public static var constraints: [String: [String: JSONValue]] {
    [
      "mode": enumField(AISearchMode.self),
      "bookRefs": [
        "minItems": .number(1),
        "items": .object([
          "type": .string("string"), "minLength": .number(1),
        ]),
      ], "query": ["minLength": .number(1)],
      "maxHits": ["minimum": .number(1)],
    ]
  }
}
public struct AIMarksInput: AIReadingInput {
  public var bookRef: String
  public var kind: AIMarkKind?
  public var query: String?
  public var chapterRef: String?
  public var markRef: String?
  public var variantRef: String?
  public var limit: Int?
  public var cursor: String?
  public static var constraints: [String: [String: JSONValue]] {
    ["kind": enumField(AIMarkKind.self), "query": [:]]
  }
  public func validate() throws {
    if variantRef != nil && markRef == nil {
      throw AIToolError("invalid_argument", field: "variantRef", message: "variantRef needs markRef.")
    }
  }
}
public struct AIStatisticsInput: AIReadingInput {
  public var bookRef: String?
  public var fromDate: String
  public var toDate: String
  public var view: AIStatisticsView?
  public var limit: Int?
  public var cursor: String?
  public static var constraints: [String: [String: JSONValue]] {
    [
      "view": enumField(AIStatisticsView.self),
      "fromDate": ["pattern": .string("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")],
      "toDate": ["pattern": .string("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")],
    ]
  }
}
public struct AIEnvironmentInput: AIReadingInput {
  public var fields: [AIEnvironmentField]?
  public static var constraints: [String: [String: JSONValue]] {
    [
      "fields": [
        "type": .string("array"), "minItems": .number(1),
        "items": .object(enumField(AIEnvironmentField.self)),
      ]
    ]
  }
}
public struct AIToolRange: Codable, Sendable {
  public var startUtf8: UInt64
  public var endUtf8: UInt64

    public init(startUtf8: UInt64, endUtf8: UInt64) {
        self.startUtf8 = startUtf8
        self.endUtf8 = endUtf8
    }
}
public struct AIToolSource: Codable, Sendable {
  public var sourceRef: String
  public var bookRef: String
  public var title: String
  public var range: AIToolRange

    public init(
        sourceRef: String,
        bookRef: String,
        title: String,
        range: AIToolRange
    ) {
        self.sourceRef = sourceRef
        self.bookRef = bookRef
        self.title = title
        self.range = range
    }
}
public struct AIToolPage: Codable, Sendable {
  public var nextCursor: String?
  public var complete: Bool

    public init(nextCursor: String? = nil, complete: Bool) {
        self.nextCursor = nextCursor
        self.complete = complete
    }
}
public struct AIToolResponse<Payload: Codable & Sendable>: Codable, Sendable {
  public var status = "ok"
  public var data: Payload
  public var sources: [AIToolSource] = []
  public var warnings: [String] = []
  public var page: AIToolPage?

    public init(
        status: String = "ok",
        data: Payload,
        sources: [AIToolSource] = [],
        warnings: [String] = [],
        page: AIToolPage? = nil
    ) {
        self.status = status
        self.data = data
        self.sources = sources
        self.warnings = warnings
        self.page = page
    }
}
public struct AIFileResult: Codable, Sendable {
  public var fileRef: String?
  public var name: String
  public var parentRef: String?
  public var availability: String
  public var sizeBytes: UInt64?
  public var bookRef: String?
  public var ref: String?
  public var kind: String?
  public var childBookCount: UInt64?

    public init(
        fileRef: String? = nil,
        name: String,
        parentRef: String? = nil,
        availability: String,
        sizeBytes: UInt64? = nil,
        bookRef: String? = nil,
        ref: String? = nil,
        kind: String? = nil,
        childBookCount: UInt64? = nil
    ) {
        self.fileRef = fileRef
        self.name = name
        self.parentRef = parentRef
        self.availability = availability
        self.sizeBytes = sizeBytes
        self.bookRef = bookRef
        self.ref = ref
        self.kind = kind
        self.childBookCount = childBookCount
    }
}
public struct AILibraryResult: Codable, Sendable {
  public var items: [AIFileResult]
  public var parentRef: String?

    public init(items: [AIFileResult], parentRef: String? = nil) {
        self.items = items
        self.parentRef = parentRef
    }
}
public struct AICoverResult: Codable, Sendable {
  public var assetRef: String
  public var width: UInt32
  public var height: UInt32

    public init(assetRef: String, width: UInt32, height: UInt32) {
        self.assetRef = assetRef
        self.width = width
        self.height = height
    }
}
public struct AIProgressResult: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var offsetUtf8: UInt64
  public var percent: Double
  public var chapterTitle: String?

    public init(offsetUtf8: UInt64, percent: Double, chapterTitle: String? = nil) {
        self.offsetUtf8 = offsetUtf8
        self.percent = percent
        self.chapterTitle = chapterTitle
    }
}
public struct AIBookResult: Codable, Sendable {
  public var title: String
  public var availability: String
  public var files: [AIFileResult]
  public var bookRef: String?
  public var author: String?
  public var synopsis: String?
  public var synopsisSnippet: String?
  public var synopsisTruncated: Bool?
  public var tags: [String]?
  public var readingStatus: String?
  public var cover: AICoverResult?
  public var filesTruncated: Bool?
  public var wordCount: UInt64?
  public var chapterCount: UInt64?
  public var totalUtf8: UInt64?
  public var progress: AIProgressResult?

    public init(
        title: String,
        availability: String,
        files: [AIFileResult],
        bookRef: String? = nil,
        author: String? = nil,
        synopsis: String? = nil,
        synopsisSnippet: String? = nil,
        synopsisTruncated: Bool? = nil,
        tags: [String]? = nil,
        readingStatus: String? = nil,
        cover: AICoverResult? = nil,
        filesTruncated: Bool? = nil,
        wordCount: UInt64? = nil,
        chapterCount: UInt64? = nil,
        totalUtf8: UInt64? = nil,
        progress: AIProgressResult? = nil
    ) {
        self.title = title
        self.availability = availability
        self.files = files
        self.bookRef = bookRef
        self.author = author
        self.synopsis = synopsis
        self.synopsisSnippet = synopsisSnippet
        self.synopsisTruncated = synopsisTruncated
        self.tags = tags
        self.readingStatus = readingStatus
        self.cover = cover
        self.filesTruncated = filesTruncated
        self.wordCount = wordCount
        self.chapterCount = chapterCount
        self.totalUtf8 = totalUtf8
        self.progress = progress
    }
}
public struct AIBooksResult: Codable, Sendable {
  public var items: [AIBookResult]
  public init(items: [AIBookResult]) {
    self.items = items
  }
}
public struct AIChapterResult: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var chapterRef: String
  public var title: String
  public var level: UInt32
  public var parentChapterRef: String?
  public var range: AIToolRange
  public var wordCount: UInt64
  public var countComplete: Bool
  public var estimatedCoveredCharacters: UInt64?
  public var estimatedCoveragePercent: Double?

    public init(
        chapterRef: String,
        title: String,
        level: UInt32,
        parentChapterRef: String? = nil,
        range: AIToolRange,
        wordCount: UInt64,
        countComplete: Bool,
        estimatedCoveredCharacters: UInt64? = nil,
        estimatedCoveragePercent: Double? = nil
    ) {
        self.chapterRef = chapterRef
        self.title = title
        self.level = level
        self.parentChapterRef = parentChapterRef
        self.range = range
        self.wordCount = wordCount
        self.countComplete = countComplete
        self.estimatedCoveredCharacters = estimatedCoveredCharacters
        self.estimatedCoveragePercent = estimatedCoveragePercent
    }
}
public struct AIChaptersResult: Codable, Sendable {
  public var items: [AIChapterResult]
  public var bookRef: String
  public var outlineComplete: Bool

    public init(items: [AIChapterResult], bookRef: String, outlineComplete: Bool) {
        self.items = items
        self.bookRef = bookRef
        self.outlineComplete = outlineComplete
    }
}
public struct AIReadResult: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var bookRef: String
  public var text: String
  public var range: AIToolRange
  public var sourceRef: String

    public init(
        bookRef: String,
        text: String,
        range: AIToolRange,
        sourceRef: String
    ) {
        self.bookRef = bookRef
        self.text = text
        self.range = range
        self.sourceRef = sourceRef
    }
}
public struct AISearchHitResult: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var bookRef: String
  public var range: AIToolRange
  public var excerpt: String
  public var chapterTitle: String?
  public var sourceRef: String

    public init(
        bookRef: String,
        range: AIToolRange,
        excerpt: String,
        chapterTitle: String? = nil,
        sourceRef: String
    ) {
        self.bookRef = bookRef
        self.range = range
        self.excerpt = excerpt
        self.chapterTitle = chapterTitle
        self.sourceRef = sourceRef
    }
}
public struct AISearchCoverage: Codable, Sendable {
  public var bookRef: String
  public var requestedRange: AIToolRange?
  public var scannedUtf8: UInt64?
  public var availableUtf8: UInt64?
  public var complete: Bool
  public var status: String?

    public init(
        bookRef: String,
        requestedRange: AIToolRange? = nil,
        scannedUtf8: UInt64? = nil,
        availableUtf8: UInt64? = nil,
        complete: Bool,
        status: String? = nil
    ) {
        self.bookRef = bookRef
        self.requestedRange = requestedRange
        self.scannedUtf8 = scannedUtf8
        self.availableUtf8 = availableUtf8
        self.complete = complete
        self.status = status
    }
}
public struct AISearchResult: Codable, Sendable {
  public var hits: [AISearchHitResult]
  public var coverage: [AISearchCoverage]
  public var truncated: Bool

    public init(hits: [AISearchHitResult], coverage: [AISearchCoverage], truncated: Bool) {
        self.hits = hits
        self.coverage = coverage
        self.truncated = truncated
    }
}
public struct AIMarkVariant: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var variantRef: String
  public var range: AIToolRange?
  public var noteSnippet: String

    public init(
        variantRef: String,
        range: AIToolRange? = nil,
        noteSnippet: String
    ) {
        self.variantRef = variantRef
        self.range = range
        self.noteSnippet = noteSnippet
    }
}
public struct AIMarkResult: Codable, Sendable {
  /// Copy into read_text around, propose_bookmark at or propose_note near.
  public var positionRef: String? = nil
  public var markRef: String
  public var bookRef: String?
  public var kind: String?
  public var range: AIToolRange?
  public var excerpt: String?
  public var note: String?
  public var noteText: String?
  public var noteTruncated: Bool?
  public var excerptTruncated: Bool?
  public var hasConflict: Bool?
  public var createdAt: String?
  public var sourceRef: String?
  public var variants: [AIMarkVariant]?

    public init(
        markRef: String,
        bookRef: String? = nil,
        kind: String? = nil,
        range: AIToolRange? = nil,
        excerpt: String? = nil,
        note: String? = nil,
        noteText: String? = nil,
        noteTruncated: Bool? = nil,
        excerptTruncated: Bool? = nil,
        hasConflict: Bool? = nil,
        createdAt: String? = nil,
        sourceRef: String? = nil,
        variants: [AIMarkVariant]? = nil
    ) {
        self.markRef = markRef
        self.bookRef = bookRef
        self.kind = kind
        self.range = range
        self.excerpt = excerpt
        self.note = note
        self.noteText = noteText
        self.noteTruncated = noteTruncated
        self.excerptTruncated = excerptTruncated
        self.hasConflict = hasConflict
        self.createdAt = createdAt
        self.sourceRef = sourceRef
        self.variants = variants
    }
}
public struct AIMarksResult: Codable, Sendable {
  public var bookRef: String
  public var items: [AIMarkResult]
  public init(bookRef: String, items: [AIMarkResult]) {
    self.bookRef = bookRef
    self.items = items
  }
}
public struct AIStatisticsRow: Codable, Sendable {
  public var date: String?
  public var durationMs: UInt64
  public var bookCount: UInt64?
  public var bookRef: String?
  public var title: String?
  public var firstReadAt: String?
  public var lastReadAt: String?
  public var readingDays: UInt64?
  public var sessionRef: String?
  public var startedAt: String?
  public var endedAt: String?
  public var recordedDate: String?
  public var utcOffsetSeconds: Int32?
  public var preview: Bool?

    public init(
        date: String? = nil,
        durationMs: UInt64,
        bookCount: UInt64? = nil,
        bookRef: String? = nil,
        title: String? = nil,
        firstReadAt: String? = nil,
        lastReadAt: String? = nil,
        readingDays: UInt64? = nil,
        sessionRef: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        recordedDate: String? = nil,
        utcOffsetSeconds: Int32? = nil,
        preview: Bool? = nil
    ) {
        self.date = date
        self.durationMs = durationMs
        self.bookCount = bookCount
        self.bookRef = bookRef
        self.title = title
        self.firstReadAt = firstReadAt
        self.lastReadAt = lastReadAt
        self.readingDays = readingDays
        self.sessionRef = sessionRef
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.recordedDate = recordedDate
        self.utcOffsetSeconds = utcOffsetSeconds
        self.preview = preview
    }
}
public struct AIStatisticsResult: Codable, Sendable {
  public var items: [AIStatisticsRow]?
  public var durationMs: UInt64?
  public var bookCount: Int?
  public var readingDays: Int?
  public var recordingEnabledOnDevice: Bool?
  public var dateBasis: String?
  public var chapters: AIChaptersResult?
  public var incomplete: Bool?

    public init(
        items: [AIStatisticsRow]? = nil,
        durationMs: UInt64? = nil,
        bookCount: Int? = nil,
        readingDays: Int? = nil,
        recordingEnabledOnDevice: Bool? = nil,
        dateBasis: String? = nil,
        chapters: AIChaptersResult? = nil,
        incomplete: Bool? = nil
    ) {
        self.items = items
        self.durationMs = durationMs
        self.bookCount = bookCount
        self.readingDays = readingDays
        self.recordingEnabledOnDevice = recordingEnabledOnDevice
        self.dateBasis = dateBasis
        self.chapters = chapters
        self.incomplete = incomplete
    }
}
public struct AIEnvironmentResult: Codable, Sendable {
  public var now: String?
  public var timeZone: String?
  public var utcOffsetSeconds: Int?
  public var appLanguage: String?
  public var region: String?

    public init(
        now: String? = nil,
        timeZone: String? = nil,
        utcOffsetSeconds: Int? = nil,
        appLanguage: String? = nil,
        region: String? = nil
    ) {
        self.now = now
        self.timeZone = timeZone
        self.utcOffsetSeconds = utcOffsetSeconds
        self.appLanguage = appLanguage
        self.region = region
    }
}

public enum AIReference {
    public static func make(_ type: String, _ key: String) -> String {
        type + ":" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A text position the model copies back instead of byte offsets. The check digits bind it
/// to its book, so an edited or misplaced reference is rejected rather than read elsewhere.
public enum AIPosition {
    public static func ref(bookSHA: String, offset: UInt64) -> String {
        "p:\(offset):" + check(bookSHA, offset)
    }
    public static func offset(_ ref: String, bookSHA: String, field: String) throws -> UInt64 {
        guard let offset = offset(of: ref), ref == Self.ref(bookSHA: bookSHA, offset: offset) else {
            throw AIToolError("stale_reference", field: field, message: "Use a positionRef returned for this book.")
        }
        return offset
    }
    /// The offset for display only; it is not validated against a book.
    public static func offset(of ref: String) -> UInt64? {
        let parts = ref.split(separator: ":")
        guard parts.count == 3, parts[0] == "p" else { return nil }
        return UInt64(parts[1])
    }
    private static func check(_ sha: String, _ offset: UInt64) -> String {
        SHA256.hash(data: Data("moonread-position:\(sha):\(offset)".utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
