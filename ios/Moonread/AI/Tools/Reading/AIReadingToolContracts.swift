import AISDKProvider
import AISDKProviderUtils
import CryptoKit
import Foundation
import SwiftAISDK

struct AIToolError: Error, LocalizedError, Sendable {
  let code: String
  let field: String?
  let message: String
  init(_ code: String, field: String? = nil, message: String? = nil) {
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
  var errorDescription: String? { field.map { "\($0): \(message)" } ?? message }
}

protocol AIReadingInput: Codable, Sendable {
  static var constraints: [String: [String: JSONValue]] { get }
  func validate() throws
}
extension AIReadingInput {
  static var constraints: [String: [String: JSONValue]] { [:] }
  func validate() throws {}
  static var schema: JSONValue {
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
      if name == "startUtf8" || name == "endUtf8" || name == "contextOffsetUtf8" {
        value["minimum"] = .number(0)
        value["maximum"] = .number(9_007_199_254_740_991)
      }
      if name == "limit" {
        value["minimum"] = .number(1)
      }
      let descriptions: [String: String] = [
        "parentRef": "Folder reference from ls. Omit to list shelf roots; ls lists direct children only.",
        "scopeRef": "Shelf or folder reference from ls. Search recursively within it; omit to search all shelves.",
        "fileRef": "File reference from ls or search_books. For get_book supply fileRef OR bookRef, never both.",
        "prepare": "Default false. Set true only when get_book must prepare an unavailable text; the app asks the user before downloading.",
        "fromDate": "Inclusive local date YYYY-MM-DD.",
        "toDate": "Inclusive local date YYYY-MM-DD.",
        "view": "summary for totals; days/books/sessions for paginated detail; chapters requires bookRef.",
        "variantRef": "Candidate reference from get_mark when hasConflict is true. Omit for an ordinary annotation.",
        "bookRef": "Exact bookRef from the reading attachment or search_books. Do not invent it.",
        "bookRefs": "Search scope: exact bookRef values from attachments or search_books, not file paths. Prefer one book.",
        "chapterRef": "Optional chapter scope from get_chapters; omit to use the whole book.",
        "startUtf8": "Inclusive byte boundary returned by a tool; not a character or page number. Usually omit.",
        "endUtf8": "Exclusive byte boundary returned by a tool. Usually omit.",
        "contextOffsetUtf8": "To read around a search hit, copy its range.startUtf8 here; omit startUtf8/endUtf8.",
        "beforeParagraphs": "Paragraphs before the hit (like rg -B, but paragraphs). Default 3.",
        "afterParagraphs": "Paragraphs after the hit (like rg -A, but paragraphs). Default 3.",
        "cursor": "For more results copy page.nextCursor, retaining the same query and scope. Omit on the first call.",
        "maxBytes": "Maximum UTF-8 bytes of text per page; default 51200 for read. A nextCursor continues without losing text.",
        "limit": "Maximum items on this page; a byte budget may return fewer. Use nextCursor for more.",
        "maxHits": "Maximum matches on this page (default 100). Like an output head limit, not rg -m per-file semantics.",
        "caseSensitive": "Default true. Set false for rg -i matching.",
        "mode": "regex (default) uses Rust regular expressions; literal matches rg -F. Do not put command flags in query."
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
enum AIToolSort: String, Codable, CaseIterable, Sendable { case name, recent }
enum AILibraryKind: String, Codable, CaseIterable, Sendable { case all, folders, books }
enum AIMarkKind: String, Codable, CaseIterable, Sendable { case all, bookmark, annotation }
enum AISearchMode: String, Codable, CaseIterable, Sendable { case literal, regex }
enum AIReadingStatus: String, Codable, CaseIterable, Sendable {
  case unread, reading, finished, paused
}
/// A read filter can include unsupported states; mutation proposals still accept known states only.
enum AIReadingStatusFilter: String, Codable, CaseIterable, Sendable {
  case unread, reading, finished, paused, other
}
enum AIStatisticsView: String, Codable, CaseIterable, Sendable {
  case summary, days, books, sessions, chapters
}
enum AIEnvironmentField: String, Codable, CaseIterable, Sendable { case time, locale }
struct AILSInput: AIReadingInput {
  var parentRef: String?
  var kind: AILibraryKind?
  var sort: AIToolSort?
  var limit: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    ["kind": enumField(AILibraryKind.self), "sort": enumField(AIToolSort.self)]
  }
}
struct AISearchBooksInput: AIReadingInput {
  var query: String?
  var scopeRef: String?
  var author: String?
  var tags: [String]?
  var readingStatus: AIReadingStatusFilter?
  var sort: AIToolSort?
  var limit: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    [
      "sort": enumField(AIToolSort.self), "readingStatus": enumField(AIReadingStatusFilter.self),

      "tags": [
        "type": .string("array"),
        "items": .object([
          "type": .string("string"), "minLength": .number(1),
        ]),
      ],
    ]
  }
}
struct AIGetBookInput: AIReadingInput {
  var bookRef: String?
  var fileRef: String?
  var prepare: Bool?
  func validate() throws {
    guard (bookRef == nil) != (fileRef == nil) else {
      throw AIToolError(
        "invalid_argument", field: "bookRef/fileRef",
        message: "Supply exactly one reference. Omit the unused field or set it to null.")
    }
  }
}
struct AIChaptersInput: AIReadingInput {
  var bookRef: String
  var query: String?
  var limit: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] { ["query": ["description": .string("Optional literal chapter-title filter, e.g. 番外 or 第316章. Omit to list all chapters.")]] }
}
struct AIReadInput: AIReadingInput {
  var bookRef: String
  var chapterRef: String?
  var contextOffsetUtf8: Int?
  var beforeParagraphs: Int?
  var afterParagraphs: Int?
  var startUtf8: Int?
  var endUtf8: Int?
  var maxBytes: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    ["maxBytes": ["minimum": .number(1)],
     "beforeParagraphs": ["minimum": .number(0)],
     "afterParagraphs": ["minimum": .number(0)]]
  }
  func validate() throws {
    if contextOffsetUtf8 != nil && (startUtf8 != nil || endUtf8 != nil) {
      throw AIToolError("invalid_argument", message: "Use contextOffsetUtf8 or startUtf8/endUtf8, not both.")
    }
    if contextOffsetUtf8 == nil && (beforeParagraphs != nil || afterParagraphs != nil) {
      throw AIToolError("invalid_argument", field: "contextOffsetUtf8")
    }

    if let startUtf8, let endUtf8, startUtf8 >= endUtf8 {
      throw AIToolError(
        "invalid_argument", field: "endUtf8", message: "Must be greater than startUtf8.")
    }
  }
}
struct AIRGInput: AIReadingInput {
  var bookRefs: [String]
  var chapterRef: String?
  var startUtf8: Int?
  var endUtf8: Int?
  var query: String
  var mode: AISearchMode?
  var caseSensitive: Bool?
  var maxHits: Int?
  var cursor: String?
  func validate() throws {
    if (chapterRef != nil || startUtf8 != nil || endUtf8 != nil) && bookRefs.count != 1 {
      throw AIToolError("invalid_argument", field: "bookRefs", message: "Scoped search requires exactly one book.")
    }
    if let startUtf8, let endUtf8, startUtf8 >= endUtf8 {
      throw AIToolError("invalid_argument", field: "endUtf8")
    }
  }
  static var constraints: [String: [String: JSONValue]] {
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
struct AIMarksInput: AIReadingInput {
  var bookRef: String
  var kind: AIMarkKind?
  var query: String?
  var startUtf8: Int?
  var endUtf8: Int?
  var limit: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    ["kind": enumField(AIMarkKind.self), "query": [:]]
  }
  func validate() throws {
    guard (startUtf8 == nil) == (endUtf8 == nil) else {
      throw AIToolError(
        "invalid_argument", field: "startUtf8/endUtf8",
        message: "Supply both range boundaries or neither.")
    }
    if let startUtf8, let endUtf8, startUtf8 >= endUtf8 {
      throw AIToolError(
        "invalid_argument", field: "endUtf8", message: "Must be greater than startUtf8.")
    }
  }
}
struct AIMarkInput: AIReadingInput {
  var bookRef: String
  var markRef: String
  var variantRef: String?
  var maxBytes: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    ["maxBytes": ["minimum": .number(1)]]
  }
}
struct AIStatisticsInput: AIReadingInput {
  var bookRef: String?
  var fromDate: String
  var toDate: String
  var view: AIStatisticsView?
  var limit: Int?
  var cursor: String?
  static var constraints: [String: [String: JSONValue]] {
    [
      "view": enumField(AIStatisticsView.self),
      "fromDate": ["pattern": .string("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")],
      "toDate": ["pattern": .string("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")],
    ]
  }
}
struct AIEnvironmentInput: AIReadingInput {
  var fields: [AIEnvironmentField]?
  static var constraints: [String: [String: JSONValue]] {
    [
      "fields": [
        "type": .string("array"), "minItems": .number(1),
        "items": .object(enumField(AIEnvironmentField.self)),
      ]
    ]
  }
}
struct AIToolRange: Codable, Sendable {
  var startUtf8: UInt64
  var endUtf8: UInt64
}
struct AIToolSource: Codable, Sendable {
  var sourceRef: String
  var bookRef: String
  var title: String
  var range: AIToolRange
}
struct AIToolPage: Codable, Sendable {
  var nextCursor: String?
  var complete: Bool
}
struct AIToolResponse<Payload: Codable & Sendable>: Codable, Sendable {
  var status = "ok"
  var data: Payload
  var sources: [AIToolSource] = []
  var warnings: [String] = []
  var page: AIToolPage?
}
struct AIFileResult: Codable, Sendable {
  var fileRef: String?
  var name: String
  var parentRef: String?
  var availability: String
  var sizeBytes: UInt64?
  var bookRef: String?
  var ref: String?
  var kind: String?
  var childBookCount: UInt64?
}
struct AILibraryResult: Codable, Sendable {
  var items: [AIFileResult]
  var parentRef: String?
}
struct AICoverResult: Codable, Sendable {
  var assetRef: String
  var width: UInt32
  var height: UInt32
}
struct AIProgressResult: Codable, Sendable {
  var offsetUtf8: UInt64
  var percent: Double
  var chapterTitle: String?
}
struct AIBookResult: Codable, Sendable {
  var title: String
  var availability: String
  var files: [AIFileResult]
  var bookRef: String?
  var author: String?
  var synopsis: String?
  var synopsisSnippet: String?
  var synopsisTruncated: Bool?
  var tags: [String]?
  var readingStatus: String?
  var cover: AICoverResult?
  var filesTruncated: Bool?
  var wordCount: UInt64?
  var chapterCount: UInt64?
  var totalUtf8: UInt64?
  var progress: AIProgressResult?
}
struct AIBooksResult: Codable, Sendable { var items: [AIBookResult] }
struct AIChapterResult: Codable, Sendable {
  var chapterRef: String
  var title: String
  var level: UInt32
  var parentChapterRef: String?
  var range: AIToolRange
  var wordCount: UInt64
  var countComplete: Bool
  var estimatedCoveredCharacters: UInt64?
  var estimatedCoveragePercent: Double?
}
struct AIChaptersResult: Codable, Sendable {
  var items: [AIChapterResult]
  var bookRef: String
  var outlineComplete: Bool
}
struct AIReadResult: Codable, Sendable {
  var bookRef: String
  var text: String
  var range: AIToolRange
  var sourceRef: String
}
struct AISearchHitResult: Codable, Sendable {
  var bookRef: String
  var range: AIToolRange
  var excerpt: String
  var chapterTitle: String?
  var sourceRef: String
}
struct AISearchCoverage: Codable, Sendable {
  var bookRef: String
  var requestedRange: AIToolRange?
  var scannedUtf8: UInt64?
  var availableUtf8: UInt64?
  var complete: Bool
  var status: String?
}
struct AISearchResult: Codable, Sendable {
  var hits: [AISearchHitResult]
  var coverage: [AISearchCoverage]
  var truncated: Bool
}
struct AIMarkVariant: Codable, Sendable {
  var variantRef: String
  var deleted: Bool
  var range: AIToolRange?
  var noteSnippet: String
}
struct AIMarkResult: Codable, Sendable {
  var markRef: String
  var bookRef: String?
  var kind: String?
  var range: AIToolRange?
  var excerpt: String?
  var note: String?
  var noteText: String?
  var noteTruncated: Bool?
  var excerptTruncated: Bool?
  var hasConflict: Bool?
  var createdAt: String?
  var sourceRef: String?
  var deleted: Bool?
  var variants: [AIMarkVariant]?
}
struct AIMarksResult: Codable, Sendable { var bookRef: String; var items: [AIMarkResult] }
struct AIStatisticsRow: Codable, Sendable {
  var date: String?
  var durationMs: UInt64
  var bookCount: UInt64?
  var bookRef: String?
  var title: String?
  var firstReadAt: String?
  var lastReadAt: String?
  var readingDays: UInt64?
  var sessionRef: String?
  var startedAt: String?
  var endedAt: String?
  var recordedDate: String?
  var utcOffsetSeconds: Int32?
  var preview: Bool?
}
struct AIStatisticsResult: Codable, Sendable {
  var items: [AIStatisticsRow]?
  var durationMs: UInt64?
  var bookCount: Int?
  var readingDays: Int?
  var recordingEnabledOnDevice: Bool?
  var dateBasis: String?
  var chapters: AIChaptersResult?
}
struct AIEnvironmentResult: Codable, Sendable {
  var now: String?
  var timeZone: String?
  var utcOffsetSeconds: Int?
  var appLanguage: String?
  var region: String?
}
