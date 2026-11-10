import AISDKProvider
import AISDKProviderUtils
import CryptoKit
import Foundation
import SwiftAISDK

actor AIReadingTools {
  private let reader: AppDataService
  private struct Cursor: Codable {
    var signature: String
    var offset: Int
  }
  private let lineLimit: Int
  init(reader: AppDataService = .shared, lineLimit: Int = 2000) {
    precondition((1...2000).contains(lineLimit))
    self.reader = reader; self.lineLimit = lineLimit
  }
  nonisolated func definitions() -> [AIAgentTool] {
    [
      .init(
        name: "ls",
        description:
          "Browse one level of authorized shelves. Omit parentRef to list roots. Optional fields may be omitted or null; never use empty references.",
        input: AILSInput.self, execute: { try await self.list($0) }),
      .init(
        name: "search_books",
        description: "Find novels by indexed title, author, synopsis, tags and reading status.",
        input: AISearchBooksInput.self, execute: { try await self.searchBooks($0) }),
      .init(
        name: "get_book",
        description:
          "Read metadata. Supply exactly one bookRef or fileRef; omit or null the other. prepare requests confirmation for file preparation.",
        input: AIGetBookInput.self, confirmation: { try await self.confirmBook($0) },
        execute: { try await self.getBook($0) }),
      .init(
        name: "get_chapters",
        description:
          "Read corrected chapter outline. Use query to find a title such as 番外 or 第316章 without paging through the whole outline. Omit cursor on first call; use the returned nextCursor for later pages.",
        input: AIChaptersInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.chapters($0) }),
      .init(
        name: "read",
        description:
          "Read by chapter/range, or set contextOffsetUtf8 to a hit startUtf8 with beforeParagraphs/afterParagraphs (default 3 each, non-empty paragraphs). Context cannot combine with explicit range. Omit cursor initially; keep query unchanged for pagination. Use tool-provided UTF-8 boundaries.",
        input: AIReadInput.self, confirmation: { try await self.confirmText([$0.bookRef]) },
        execute: { try await self.readText($0) }),
      .init(
        name: "rg",
        description:
          "Search novel text, not a shell command. Example: query=年龄, mode=literal (rg -F); query=年龄|岁, mode=regex. Start with a specific phrase and one book. Search books with literal text or single-line Rust regex. For one book, optionally restrict chapterRef and/or startUtf8/endUtf8 before scanning. Use get_chapters for range boundaries. To inspect a hit call read with its bookRef and contextOffsetUtf8=range.startUtf8, beforeParagraphs=3, afterParagraphs=3; do not calculate byte offsets. Use nextCursor with the same search; maxHits may change between pages. Continue partial searches with nextCursor.",
        input: AIRGInput.self, confirmation: { try await self.confirmText($0.bookRefs) },
        execute: { try await self.searchText($0) }),
      .init(
        name: "get_marks",
        description: "List bookmarks and annotations with short note/excerpt previews. Use get_mark for the full comment and read with the returned range for original text. Conflicts remain explicit.",
        input: AIMarksInput.self, execute: { try await self.marks($0) }),
      .init(
        name: "get_mark",
        description:
          "Read an annotation comment in pages; nextCursor continues the comment, excerpt is only a preview. Use read for full original text. Select variantRef for conflicts; this never resolves a conflict.",
        input: AIMarkInput.self, execute: { try await self.mark($0) }),
      .init(
        name: "get_reading_statistics",
        description:
          "Read recorded local-day statistics for an inclusive date range. Concurrent device durations are summed. Distinguish recorded facts from interpretation when analyzing reading.",
        input: AIStatisticsInput.self, execute: { try await self.statistics($0) }),
      .init(
        name: "get_environment",
        description:
          "Read current time, time zone and application locale. Omit fields for both time and locale.",
        input: AIEnvironmentInput.self, execute: { await self.environment($0) }),
    ].sorted { $0.name < $1.name }
  }
  static func ref(_ type: String, _ key: String) -> String {
    type + ":" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func bookRef(_ sha: String) -> String { "b:" + sha }
  private func sha(_ ref: String) throws -> String { try AIReadingReferences.parseBookReference(ref) }
  private func files() async throws -> [LibraryEntry] { try await AIReadingReferences(reader: reader).files() }
  private func location(_ ref: String) async throws -> LibraryLocation { try await AIReadingReferences(reader: reader).location(ref) }
  private func file(_ ref: String) async throws -> LibraryEntry { try await AIReadingReferences(reader: reader).file(ref) }
  private func bookID(_ ref: String) async throws -> String { try await AIReadingReferences(reader: reader).bookID(ref) }
  private func confirmBook(_ input: AIGetBookInput) async throws -> String? { try await AIReadingReferences(reader: reader).confirmBook(input) }
  private func confirmText(_ refs: [String]) async throws -> String? { try await AIReadingReferences(reader: reader).confirmText(refs) }
  private func ready(_ ref: String) async throws -> String { try await AIReadingReferences(reader: reader).ready(ref) }
  static func preparationConfirmation(_ refs: [String], isolation: isolated (any Actor)? = #isolation, title: (String) async throws -> String?) async throws -> String? {
    var seen = Set<String>()
    var titles: [String] = []
    for ref in refs where seen.insert(ref).inserted {
      if let value = try await title(ref) { titles.append(value) }
    }
    guard !titles.isEmpty else { return nil }
    let books = titles.map { "《\($0)》" }.joined(separator: "、")
    return String(localized: "准备以下书籍的正文，用于本次查询：\(books)")
  }

  private func signature<T: Encodable>(_ name: String, _ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return name + String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private func cursorOffset(_ token: String?, signature: String) throws -> Int {
    guard let token else { return 0 }
    guard let data = Data(base64Encoded: token),
      let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
      cursor.signature == signature, cursor.offset >= 0
    else { throw AIToolError("stale_cursor", field: "cursor") }
    return cursor.offset
  }
  private func cursor(_ offset: Int, signature: String) throws -> String {
    try JSONEncoder().encode(Cursor(signature: signature, offset: offset)).base64EncodedString()
  }
  private func page<T: Codable & Sendable>(
    _ items: [T], signature: String, cursor token: String?, limit: Int
  ) throws -> ([T], AIToolPage) {
    let start = try cursorOffset(token, signature: signature)
    guard start <= items.count else { throw AIToolError("stale_cursor", field: "cursor") }
    var end = min(items.count, start + min(limit, items.count - start))
    while end > start + 1, try JSONEncoder().encode(Array(items[start..<end])).count > 50 * 1024 {
      end -= 1
    }
    guard end > start || start == items.count else { throw AIToolError("resource_limit") }
    var next: String?
    if end < items.count {
      next = try cursor(end, signature: signature)
    }
    return (Array(items[start..<end]), .init(nextCursor: next, complete: end == items.count))
  }
  private func source(_ ref: String, _ range: AIToolRange, title: String = "") -> AIToolSource {
    .init(
      sourceRef: Self.ref("source", "\(ref):\(range.startUtf8):\(range.endUtf8)"), bookRef: ref,
      title: title, range: range)
  }
  private func availability(_ row: LibraryEntry) -> String {
    row.needsDownload ? "needs_download" : row.bookId == nil ? "needs_parse" : "ready"
  }
  private func fileResult(_ row: LibraryEntry) -> AIFileResult {
    .init(
      fileRef: Self.ref("f", row.id), name: row.name,
      parentRef: row.parentPath.isEmpty
        ? Self.ref("s", row.shelfId) : Self.ref("d", row.shelfId + "/" + row.parentPath),
      availability: availability(row), sizeBytes: row.size,
      bookRef: row.metadata.map { Self.bookRef($0.sha) })
  }
  private func statusName(_ status: BookReadingStatus) -> String { LibraryQueryRules.statusName(status) }
  private func addMetadata(
    _ metadata: BookMetadata, to result: inout AIBookResult, snippet: Bool = false
  ) {
    result.bookRef = Self.bookRef(metadata.sha)
    result.author = metadata.author
    if snippet {
      result.synopsisSnippet = String(metadata.synopsis.prefix(500))
    } else {
      result.synopsis = metadata.synopsis
    }
    result.synopsisTruncated = metadata.synopsis.count > (snippet ? 500 : metadata.synopsis.count)
    result.tags = metadata.tags
    result.readingStatus = statusName(metadata.status)
    result.cover = metadata.cover.map {
      .init(assetRef: Self.ref("asset", $0.id), width: $0.width, height: $0.height)
    }
  }
  private func list(_ input: AILSInput) async throws -> AIToolResponse<AILibraryResult> {
    let items: [AIFileResult]
    if let parent = input.parentRef {
      let rows = try await reader.aiLibraryEntries(
        location(parent), sort: input.sort == .recent ? .reading : .name)
      items = rows.filter {
        input.kind == nil || input.kind == .all
          || ($0.directory ? input.kind == .folders : input.kind == .books)
      }.map {
        var item = fileResult($0)
        item.kind = $0.directory ? "folder" : "file"
        item.ref = Self.ref(
          $0.directory ? "d" : "f", $0.directory ? $0.shelfId + "/" + $0.relativePath : $0.id)
        item.childBookCount = UInt64($0.childBookCount)
        return item
      }
    } else {
      items = try await reader.shelves().map {
        .init(
          name: $0.name, availability: $0.error == nil ? "ready" : "unavailable",
          ref: Self.ref("s", $0.id), kind: "shelf", childBookCount: UInt64($0.bookCount))
      }
    }
    var query = input
    query.cursor = nil
    query.limit = nil
    query.kind = query.kind ?? .all
    query.sort = query.sort ?? .name
    let (rows, page) = try page(
      items, signature: signature("ls", query), cursor: input.cursor, limit: input.limit ?? 100)
    return .init(data: .init(items: rows, parentRef: input.parentRef), page: page)
  }
  private func searchBooks(_ input: AISearchBooksInput) async throws -> AIToolResponse<
    AIBooksResult
  > {
    let scope: LibraryLocation?
    if let ref = input.scopeRef { scope = try await location(ref) } else { scope = nil }
    let rows = try await reader.searchCatalogue(scope, spec: .init(profile: .ai, query: input.query ?? "", author: input.author, tags: input.tags ?? [], status: input.readingStatus?.rawValue, nameOrder: input.sort == .name))
    var items: [AIBookResult] = []
    for row in rows {
      var item = AIBookResult(
        title: row.title, availability: availability(row), files: [fileResult(row)])
      item.filesTruncated = false
      if let metadata = row.metadata { addMetadata(metadata, to: &item, snippet: true) }
      items.append(item)
    }
    var queryInput = input
    queryInput.cursor = nil
    queryInput.limit = nil
    queryInput.sort = queryInput.sort ?? .recent
    let (pageItems, page) = try page(
      items, signature: signature("search_books", queryInput), cursor: input.cursor,
      limit: input.limit ?? 100)
    return .init(data: .init(items: pageItems), page: page)
  }
  private func getBook(_ input: AIGetBookInput) async throws -> AIToolResponse<AIBookResult> {
    let entry: LibraryEntry?
    let contentSHA: String?
    switch try ReadingToolTarget(input) {
    case .book(let reference):
      entry = nil
      contentSHA = reference.sha
    case .file(let reference, let policy):
      let source = try await file(reference.value)
      entry = source
      switch policy {
      case .prepare:
        let lease = try await reader.aiPrepare(source.source)
        contentSHA = try parseSha256(value: await reader.snapshot(lease.id).book.contentSha256)
      case .existingOnly:
        contentSHA = try source.metadata.map { try parseSha256(value: $0.sha) }
      }
    }
    guard let contentSHA else {
      return .init(
        data: .init(
          title: entry?.title ?? "", availability: entry.map(availability) ?? "unavailable",
          files: entry.map { [fileResult($0)] } ?? []))
    }
    let details = try await reader.details(sha: contentSHA)
    let files = try await files().filter { $0.metadata?.sha == details.metadata.sha }
    var data = AIBookResult(
      title: details.book?.title ?? entry?.title ?? "",
      availability: details.book == nil ? "unavailable" : "ready",
      files: files.map(fileResult))
    addMetadata(details.metadata, to: &data)
    data.wordCount = details.wordCount
    data.chapterCount = details.chapterCount
    data.filesTruncated = false
    if let book = details.book {
      data.totalUtf8 = book.byteCount
      data.progress = .init(
        offsetUtf8: book.positionUtf8,
        percent: book.byteCount == 0 ? 0 : Double(book.positionUtf8) * 100 / Double(book.byteCount),
        chapterTitle: details.currentChapter)
    }
    return .init(data: data)
  }
  private func chapters(_ input: AIChaptersInput) async throws -> AIToolResponse<AIChaptersResult> {
    let id = try await ready(input.bookRef)
    let outline = try await reader.chapters(id)
    let book = try await reader.book(id)
    let items: [AIChapterResult] = outline.items.enumerated().map { index, chapter in
      let end =
        outline.items.dropFirst(index + 1).first { $0.level <= chapter.level }?.startUtf8
        ?? book.byteCount
      return .init(
        chapterRef: Self.ref("c", "\(input.bookRef):\(chapter.startUtf8)"), title: chapter.title,
        level: chapter.level,
        parentChapterRef: chapter.parentUtf8.map { Self.ref("c", "\(input.bookRef):\($0)") },
        range: .init(startUtf8: chapter.startUtf8, endUtf8: end), wordCount: chapter.wordCount,
        countComplete: chapter.countComplete, estimatedCoveredCharacters: chapter.coveredCharacters,
        estimatedCoveragePercent: chapter.coveredCharacters.map {
          chapter.wordCount == 0 ? 0 : min(100, Double($0) * 100 / Double(chapter.wordCount))
        })
    }
    let filtered = items.filter { item in input.query.map { item.title.localizedCaseInsensitiveContains($0) } ?? true }
    var query = input
    query.cursor = nil; query.limit = nil
    let (rows, page) = try page(
      filtered, signature: signature("chapters", query), cursor: input.cursor, limit: input.limit ?? 100)
    return .init(
      data: .init(items: rows, bookRef: input.bookRef, outlineComplete: outline.isComplete),
      page: page)
  }
  private func textBounds(_ id: String, chapterRef: String?, size: UInt64, ref: String) async throws -> AIToolRange {
    guard let chapterRef else { return .init(startUtf8: 0, endUtf8: size) }
    let chapters = try await reader.chapters(id).items
    guard let index = chapters.firstIndex(where: { Self.ref("c", "\(ref):\($0.startUtf8)") == chapterRef }) else {
      throw AIToolError("stale_reference", field: "chapterRef")
    }
    return .init(startUtf8: chapters[index].startUtf8,
      endUtf8: chapters.dropFirst(index + 1).first { $0.level <= chapters[index].level }?.startUtf8 ?? size)
  }
  private func readText(_ input: AIReadInput) async throws -> AIToolResponse<AIReadResult> {
    let ref = input.bookRef
    let id = try await ready(ref)
    let book = try await reader.book(id)
    let bounds = try await textBounds(id, chapterRef: input.chapterRef, size: book.byteCount, ref: ref)
    let lower = bounds.startUtf8
    let upper = bounds.endUtf8
    var context: TextRange?
    if let offset = input.contextOffsetUtf8 {
      guard UInt64(offset) >= lower, UInt64(offset) < upper else {
        throw AIToolError("invalid_argument", field: "contextOffsetUtf8")
      }
      context = try await reader.textContext(id, at: UInt64(offset),
        before: UInt32(clamping: input.beforeParagraphs ?? 3), after: UInt32(clamping: input.afterParagraphs ?? 3))
    }
    let requestedStart = context.map { max(lower, $0.startUtf8) } ?? UInt64(input.startUtf8 ?? Int(lower))
    let requestedEnd = context.map { min(upper, $0.endUtf8) } ?? UInt64(input.endUtf8 ?? Int(upper))
    guard requestedStart >= lower, requestedEnd <= upper, requestedStart < requestedEnd else {
      throw AIToolError(
        "invalid_argument", field: "startUtf8/endUtf8",
        message: "The range must be inside the selected book or chapter.")
    }
    var query = input
    query.cursor = nil
    query.maxBytes = nil
    let signature = try signature("read", query) + ":\(lower):\(upper):\(requestedStart):\(requestedEnd)"
    var start = requestedStart
    if input.cursor != nil { start = UInt64(try cursorOffset(input.cursor, signature: signature)) }
    guard start >= requestedStart, start < requestedEnd else { throw AIToolError("stale_cursor", field: "cursor") }
    var end = min(requestedEnd, start + min(requestedEnd - start, UInt64(min(input.maxBytes ?? 51200, 51200))))
    var value: TextRange?
    for _ in 0..<4 {
      do {
        value = try await reader.textRange(id, start: start, end: end)
        break
      } catch ReaderError.InvalidRange {
        if end == requestedEnd {
          throw AIToolError(
            "invalid_argument", field: "startUtf8/endUtf8",
            message: "Use valid UTF-8 boundaries from tool results.")
        }
        end -= 1
      }
    }
    guard let text = value else {
      throw AIToolError(
        "invalid_argument", field: "startUtf8", message: "Must be a UTF-8 character boundary.")
    }
    guard end > start else { throw AIToolError("invalid_argument", field: "maxBytes", message: "The byte budget must fit the next UTF-8 character.") }
    var content = text.text
    var lines = 0
    if let boundary = content.indices.first(where: { index in
      if content[index] == "\n" { lines += 1 }
      return lines == lineLimit
    }) {
      content = String(content[...boundary])
      end = start + UInt64(content.utf8.count)
    }
    var next: String?
    if end < requestedEnd {
      next = try cursor(Int(end), signature: signature)
    }
    let range = AIToolRange(startUtf8: start, endUtf8: end)
    return .init(
      data: .init(
        bookRef: ref, text: content, range: range,
        sourceRef: source(ref, range).sourceRef),
      page: .init(nextCursor: next, complete: end == requestedEnd))
  }
  private func searchText(_ input: AIRGInput) async throws -> AIToolResponse<AISearchResult> {
    var query = input
    query.cursor = nil; query.maxHits = nil
    query.mode = query.mode ?? .regex; query.caseSensitive = query.caseSensitive ?? true
    let querySignature = try signature("rg", query)
    let offset = try cursorOffset(input.cursor, signature: querySignature)
    let pageLimit = input.maxHits ?? 100
    let (requested, overflow) = offset.addingReportingOverflow(pageLimit)
    guard !overflow, requested < Int.max else { throw AIToolError("invalid_argument", field: "maxHits") }
    let target = requested + 1
    var hits: [AISearchHitResult] = []
    var coverage: [AISearchCoverage] = []
    var truncated = false
    for ref in input.bookRefs {
      let id = try await ready(ref)
      let size = try await reader.book(id).byteCount
      let bounds = try await textBounds(id, chapterRef: input.chapterRef, size: size, ref: ref)
      let start = UInt64(input.startUtf8 ?? Int(bounds.startUtf8))
      let end = UInt64(input.endUtf8 ?? Int(bounds.endUtf8))
      guard start >= bounds.startUtf8, end <= bounds.endUtf8, start < end else {
        throw AIToolError("invalid_argument", field: "startUtf8/endUtf8")
      }
      let job = try await reader.search(
        id, query: input.query, regex: (input.mode ?? .regex) == .regex,
        caseSensitive: input.caseSensitive ?? true, range: .init(startUtf8: start, endUtf8: end))
      defer { job.cancel() }
      var skippedContent = false
      try await withTaskCancellationHandler {
        while true {
          try Task.checkCancellation()
          let batch = try await reader.aiSearchBatch(job)
          // Coverage warnings never terminate a scan. Completion/cancellation
          // and this tool's explicit pagination budget are independent signals.
          skippedContent = skippedContent || batch.truncated
          truncated = truncated || batch.truncated
          hits += batch.hits.prefix(max(0, target - hits.count)).map { hit in
            let range = AIToolRange(startUtf8: hit.startUtf8, endUtf8: hit.endUtf8)
            return .init(
              bookRef: ref, range: range, excerpt: String(hit.excerpt.prefix(500)),
              chapterTitle: hit.chapter, sourceRef: source(ref, range).sourceRef)
          }
          if batch.done || batch.cancelled || hits.count >= target {
            truncated = truncated || batch.cancelled || hits.count >= target
            coverage.append(
              .init(
                bookRef: ref, requestedRange: .init(startUtf8: start, endUtf8: end),
                scannedUtf8: batch.scannedUtf8, availableUtf8: batch.availableUtf8,
                complete: batch.done && !skippedContent && !batch.partialBook))
            break
          }
          await Task.yield()
        }
      } onCancel: {
        job.cancel()
      }
      if hits.count >= target { break }
    }
    let scanned = Set(coverage.map(\.bookRef))
    for ref in input.bookRefs where !scanned.contains(ref) {
      coverage.append(.init(bookRef: ref, complete: false, status: "not_scanned"))
    }
    let (rows, page) = try page(
      hits, signature: querySignature, cursor: input.cursor, limit: pageLimit)
    return .init(
      status: truncated ? "partial" : "ok",
      data: .init(hits: rows, coverage: coverage, truncated: truncated),
      page: page)
  }
  private func marks(_ input: AIMarksInput) async throws -> AIToolResponse<AIMarksResult> {
    let ref = input.bookRef
    let groups = try await reader.aiMarks(sha: sha(ref))
    var rows: [(UInt64, String, AIMarkResult)] = []
    for (markID, heads) in groups {
      guard let candidate = heads.first(where: { $0.content != nil }),
        let content = candidate.content
      else { continue }
      let kind: AIMarkKind = candidate.bookmark ? .bookmark : .annotation
      let conflict = AnnotationReduction.conflicts(heads)
      if let filter = input.kind, filter != .all, filter != kind { continue }
      if let query = input.query, !query.isEmpty,
        !heads.contains(where: {
          ($0.content?.note.localizedCaseInsensitiveContains(query) ?? false)
            || ($0.content?.excerpt.localizedCaseInsensitiveContains(query) ?? false)
        })
      {
        continue
      }
      if let start = input.startUtf8, let end = input.endUtf8,
        !heads.contains(where: { c in
          guard let value = c.content else { return false }
          return candidate.bookmark
            ? value.start >= UInt64(start) && value.start < UInt64(end)
            : value.start < UInt64(end) && value.end > UInt64(start)
        })
      {
        continue
      }
      let range = AIToolRange(startUtf8: content.start, endUtf8: content.end)
      let item = AIMarkResult(
        markRef: Self.ref("mark", markID), kind: kind.rawValue, range: range,
        excerpt: conflict ? "" : String(content.excerpt.prefix(500)),
        note: conflict ? "" : String(content.note.prefix(500)),
        noteTruncated: content.note.count > 500, excerptTruncated: content.excerpt.count > 500,
        hasConflict: conflict, createdAt: timestamp(Int64(candidate.created)),
        sourceRef: source(ref, range).sourceRef)
      rows.append((content.start, markID, item))
    }
    rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    var query = input
    query.cursor = nil
    query.limit = nil
    query.kind = query.kind ?? .all
    let (items, page) = try page(
      rows.map(\.2), signature: signature("get_marks", query), cursor: input.cursor,
      limit: input.limit ?? 100)
    return .init(
      data: .init(bookRef: ref, items: items),
      page: page)
  }
  private func mark(_ input: AIMarkInput) async throws -> AIToolResponse<AIMarkResult> {
    let ref = input.bookRef
    let groups = try await reader.aiMarks(sha: sha(ref))
    guard let heads = groups.first(where: { Self.ref("mark", $0.key) == input.markRef })?.value
    else { throw AIToolError("not_found", field: "markRef") }
    if AnnotationReduction.conflicts(heads), input.variantRef == nil {
      return .init(
        data: .init(
          markRef: input.markRef, hasConflict: true,
          variants: heads.map {
            .init(
              variantRef: Self.ref("v", $0.id), deleted: $0.content == nil,
              range: $0.content.map { .init(startUtf8: $0.start, endUtf8: $0.end) },
              noteSnippet: String(($0.content?.note ?? "").prefix(500)))
          }))
    }
    guard
      let candidate = input.variantRef.flatMap({ v in heads.first { Self.ref("v", $0.id) == v } })
        ?? (input.variantRef == nil ? heads.first : nil)
    else { throw AIToolError("stale_reference", field: "variantRef") }
    guard let content = candidate.content else {
      return .init(data: .init(markRef: input.markRef, deleted: true))
    }
    // Byte offsets keep continuation stable when maxBytes changes.
    let bytes = Array(content.note.utf8)
    let signature = "mark:\(ref):\(input.markRef):\(candidate.id)"
    var start = 0
    start = try cursorOffset(input.cursor, signature: signature)
    guard start <= bytes.count, String(bytes: bytes.prefix(start), encoding: .utf8) != nil else {
      throw AIToolError("stale_cursor", field: "cursor")
    }
    var end = min(bytes.count, start + min(bytes.count - start, min(input.maxBytes ?? 51200, 51200)))
    while end > start, String(bytes: bytes[start..<end], encoding: .utf8) == nil { end -= 1 }
    guard end > start || start == bytes.count else { throw AIToolError("invalid_argument", field: "maxBytes", message: "The byte budget must fit the next UTF-8 character.") }
    var next: String?
    if end < bytes.count {
      next = try cursor(end, signature: signature)
    }
    let range = AIToolRange(startUtf8: content.start, endUtf8: content.end)
    return .init(
      data: .init(
        markRef: input.markRef, bookRef: ref, kind: candidate.bookmark ? "bookmark" : "annotation", range: range,
        excerpt: content.excerpt,
        noteText: String(decoding: bytes[start..<end], as: UTF8.self),
        excerptTruncated: false, sourceRef: source(ref, range).sourceRef),
      page: .init(nextCursor: next, complete: end == bytes.count))
  }
  private func timestamp(_ ms: Int64) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }
  private func statistics(_ input: AIStatisticsInput) async throws -> AIToolResponse<
    AIStatisticsResult
  > {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let first = formatter.date(from: input.fromDate),
      let last = formatter.date(from: input.toDate),
      formatter.string(from: first) == input.fromDate, formatter.string(from: last) == input.toDate,
      last >= first
    else {
      throw AIToolError(
        "invalid_argument", field: "fromDate/toDate",
        message: "Use real YYYY-MM-DD dates in order.")
    }
    if input.view == .chapters {
      guard let ref = input.bookRef else {
        throw AIToolError(
          "invalid_argument", field: "bookRef", message: "Required for chapter statistics.")
      }
      let result = try await chapters(.init(bookRef: ref, limit: input.limit, cursor: input.cursor))
      return .init(data: .init(chapters: result.data), page: result.page)
    }
    let firstDay = Int64(first.timeIntervalSince1970 / 86400)
    let lastDay = Int64(last.timeIntervalSince1970 / 86400)
    let key = try input.bookRef.map(sha)
    let overview = try await reader.statistics(first: firstDay, last: lastDay, book: key)
    let view = input.view ?? .summary
    if view == .summary {
      guard input.cursor == nil else {
        throw AIToolError(
          "invalid_argument", field: "cursor", message: "Summary has no pages. Omit cursor.")
      }
      return .init(
        data: .init(
          durationMs: overview.books.reduce(0) { $0 + $1.durationMs },
          bookCount: overview.books.count,
          readingDays: overview.days.filter { $0.durationMs > 0 }.count,
          recordingEnabledOnDevice: overview.preferences.enabled, dateBasis: "recorded_local_day"))
    }
    func date(_ day: Int64) -> String {
      formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86400))
    }
    let items: [AIStatisticsRow]
    switch view {
    case .days:
      items = overview.days.map {
        .init(date: date($0.day), durationMs: $0.durationMs, bookCount: $0.bookCount)
      }
    case .books:
      items = overview.books.map {
        .init(
          durationMs: $0.durationMs,
          bookRef: (try? parseSha256(value: $0.contentKey)) != nil ? Self.bookRef($0.contentKey) : nil, title: $0.title,
          firstReadAt: timestamp($0.firstReadMs), lastReadAt: timestamp($0.lastReadMs),
          readingDays: $0.readingDays)
      }
    case .sessions:
      items = try await reader.activities(first: firstDay, last: lastDay, book: key).map {
        .init(
          durationMs: UInt64(max(0, $0.endedMs - $0.startedMs)),
          bookRef: (try? parseSha256(value: $0.contentKey)) != nil ? Self.bookRef($0.contentKey) : nil, title: $0.title,
          sessionRef: Self.ref("session", $0.id), startedAt: timestamp($0.startedMs),
          endedAt: timestamp($0.endedMs), recordedDate: date($0.localDay),
          utcOffsetSeconds: $0.utcOffsetSeconds, preview: $0.preview)
      }
    default: throw AIToolError("invalid_argument", field: "view")
    }
    var query = input
    query.cursor = nil
    query.limit = nil
    query.view = view
    let (rows, page) = try page(
      items, signature: signature("statistics", query), cursor: input.cursor,
      limit: input.limit ?? 100)
    return .init(data: .init(items: rows), page: page)
  }
  private func environment(_ input: AIEnvironmentInput) -> AIToolResponse<AIEnvironmentResult> {
    let fields = input.fields ?? [.time, .locale]
    return .init(
      data: .init(
        now: fields.contains(.time) ? ISO8601DateFormatter().string(from: Date()) : nil,
        timeZone: fields.contains(.time) ? TimeZone.current.identifier : nil,
        utcOffsetSeconds: fields.contains(.time) ? TimeZone.current.secondsFromGMT() : nil,
        appLanguage: fields.contains(.locale)
          ? Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
          : nil, region: fields.contains(.locale) ? Locale.current.region?.identifier : nil))
  }
}
