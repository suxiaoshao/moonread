import MoonreadSearchText
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import AISDKProvider
import AISDKProviderUtils
import Foundation

public actor AIReadingTools {
  private let reader: AIReadingAccess
  private let owner: String?
  private struct Cursor: Codable {
    var signature: String
    var offset: Int
  }
  private let lineLimit: Int
  public init(reader: AIReadingAccess, lineLimit: Int = 2000, owner: String? = nil) {
    precondition((1...2000).contains(lineLimit))
    self.reader = reader; self.lineLimit = lineLimit; self.owner = owner
  }
  public static func ref(_ type: String, _ key: String) -> String {
    AIReference.make(type, key)
  }
  public static func bookRef(_ sha: String) -> String { "b:" + sha }
  public static func scopeRef(shelfID: String, path: String) -> String {
    path.isEmpty ? ref("s", shelfID) : ref("d", shelfID + "/" + path)
  }
  private func sha(_ ref: String) throws -> String { try AIReadingReferences.parseBookReference(ref).sha }
  private func position(_ bookRef: String, _ offset: UInt64) -> String? {
    (try? sha(bookRef)).map { AIPosition.ref(bookSHA: $0, offset: offset) }
  }
  private func files() async throws -> [LibraryEntry] { try await AIReadingReferences(access: reader).files() }
  private func location(_ ref: String) async throws -> LibraryLocation { try await AIReadingReferences(access: reader).location(ref) }
  private func file(_ ref: String) async throws -> LibraryEntry { try await AIReadingReferences(access: reader).file(ref) }
  private func bookID(_ ref: String) async throws -> String { try await AIReadingReferences(access: reader).bookID(ref) }
  func confirmBook(_ input: AIGetBookInput) async throws -> String? { try await AIReadingReferences(access: reader).confirmBook(input) }
  func confirmText(_ refs: [String]) async throws -> String? { try await AIReadingReferences(access: reader).confirmText(refs) }
  private func ready(_ ref: String) async throws -> String { try await AIReadingReferences(access: reader).ready(ref) }
  public static func preparationConfirmation(_ refs: [String], isolation: isolated (any Actor)? = #isolation, title: (String) async throws -> String?) async throws -> String? {
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
    return try pageWindow(Array(items.dropFirst(start).prefix(limit)), start: start, total: items.count, signature: signature)
  }

  private func pageWindow<T: Codable & Sendable>(
    _ items: [T], start: Int, total: Int, signature: String
  ) throws -> ([T], AIToolPage) {
    guard start <= total else { throw AIToolError("stale_cursor", field: "cursor") }
    var count = items.count
    while count > 1, try JSONEncoder().encode(Array(items.prefix(count))).count > 50 * 1024 { count -= 1 }
    guard count > 0 || start == total else { throw AIToolError("resource_limit") }
    let end = start + count
    let next = end < total ? try cursor(end, signature: signature) : nil
    return (Array(items.prefix(count)), .init(nextCursor: next, complete: end == total))
  }
  private func source(_ ref: String, _ range: AIToolRange, title: String = "") -> AIToolSource {
    .init(
      sourceRef: Self.ref("source", "\(ref):\(range.startUtf8):\(range.endUtf8)"), bookRef: ref,
      title: title, range: range)
  }

  func listFilterOptions(_ input: AIFilterOptionsInput) async throws -> AIToolResponse<AIFilterOptionsResult> {
    let names: [String]
    switch input.field {
    case .tag: names = try await reader.metadataOptions(nil).tags.map(\.name)
    case .author: names = try await reader.metadataOptions(nil).authors
    case .shelf: names = LibraryQueryRules.filterShelves(try await reader.shelves()).map(LibraryQueryRules.filterShelfName)
    }
    let term = input.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var seen = Set<Data>()
    let matches = LibraryQueryRules.filterSuggestions(names, query: term).filter { seen.insert(Data($0.utf8)).inserted }
    let query = AIFilterOptionsInput(field: input.field, query: term)
    let (rows, page) = try page(matches, signature: signature("list_filter_values", query), cursor: input.cursor, limit: 100)
    return .init(data: .init(names: rows), page: page)
  }

  func proposeBookFilter(_ input: AIBookFilterArguments) async throws -> AIToolResponse<AIBookFilterSuggestion> {
    let (suggestion, _) = try await validatedBookFilter(input.stored())
    return .init(data: suggestion)
  }

  private func validatedBookFilter(_ input: AIBookFilterInput) async throws -> (AIBookFilterSuggestion, [LibraryShelf]) {
    _ = try input.configuration(resolveShelf: { $0 })
    if input.nodes.contains(where: { $0.kind == .author || $0.kind == .tag }) {
      let options = try await reader.metadataOptions(nil)
      let tags = Set(options.tags.map { Data($0.name.utf8) })
      let authors = Set(options.authors.map { Data($0.utf8) })
      for node in input.nodes where node.kind == .tag || node.kind == .author {
        let candidates = node.kind == .tag ? tags : authors
        if let missing = node.values?.first(where: { !candidates.contains(Data($0.utf8)) }) {
          throw AIToolError("not_found", field: node.kind.rawValue,
                            message: "No exact match for “\(missing)”. Use list_filter_values or ask the user; do not drop the condition.")
        }
      }
    }
    let names = input.shelfNames
    var references: [AIBookFilterSuggestion.Shelf] = []
    let shelves = names.isEmpty ? [] : LibraryQueryRules.filterShelves(try await reader.shelves())
    if !names.isEmpty {
      for name in names {
        let matches = shelves.filter { LibraryQueryRules.filterShelfName($0).utf8.elementsEqual(name.utf8) }
        guard let shelf = matches.first else {
          throw AIToolError("not_found", field: "shelf",
                            message: "No exact shelf name “\(name)”. Use list_filter_values or ask the user.")
        }
        if matches.count == 1 { references.append(.init(name: name, reference: AIBookFilterSuggestion.shelfReference(shelf))) }
      }
    }
    return (.init(filter: input, shelves: references), shelves)
  }
  func findBooks(_ input: AIFindBooksInput) async throws -> AIToolResponse<AIFilteredBooksResult> {
    try input.validate()
    var configuration = BookSearchConfiguration()
    if let stored = try input.stored() {
      let (suggestion, shelves) = try await validatedBookFilter(stored)
      let resolution = suggestion.resolveShelves(shelves)
      if let ambiguous = resolution.choices.first {
        throw AIToolError("invalid_argument", field: "shelves",
                          message: "More than one shelf is named “\(ambiguous.name)”. Ask the reader to choose with propose_book_filter.")
      }
      configuration = try resolution.configuration(suggestion)
    }
    let scope: LibraryLocation?
    if let ref = input.scopeRef { scope = try await location(ref) } else { scope = nil }
    var query = input
    query.cursor = nil; query.limit = nil
    let signature = try signature("find_books", query)
    let start = try cursorOffset(input.cursor, signature: signature)
    let found = try await reader.aiFoundBookPage(input.query ?? "", scope, configuration, start, input.limit ?? 20)
    let items = found.books.map { hit in
      let entry = hit.entry, metadata = entry.displayMetadata
      return AIFilteredBookResult(title: entry.title, author: metadata.flatMap { $0.author.isEmpty ? nil : $0.author },
        readingStatus: hit.status.map(statusName), availability: availability(entry),
        fileRef: Self.ref("f", entry.id), bookRef: entry.readingIdentity?.formalSHA256.map(Self.bookRef),
        tags: entry.metadata.flatMap { $0.tags.isEmpty ? nil : $0.tags })
    }
    let (rows, page) = try pageWindow(items, start: start, total: found.count, signature: signature)
    return .init(status: found.unknownCount == 0 ? "ok" : "partial",
                 data: .init(totalMatches: found.count, unknownCount: found.unknownCount, items: rows), page: page)
  }

  func showBookList(_ input: AIShowBookListInput) async throws -> (AIToolResponse<AIShownBooksResult>, [AIBookListPresentation]) {
    try input.validate()
    let resolved = try await reader.aiBookListEntries(input.refs, true)
    let entries = try input.refs.enumerated().map { index, ref in
      let field = "refs[\(index)]"
      if resolved.folders.contains(ref) { throw AIToolError("invalid_argument", field: field) }
      guard let entry = resolved.entries[ref] else { throw AIToolError("not_found", field: field) }
      return entry
    }
    var books: [AIBookListPresentation] = []
    for (ref, entry) in zip(input.refs, entries) {
      let author = entry.displayMetadata?.author
      let book = AIShownBooksResult.Item(ref: ref, title: entry.title, author: author.flatMap { $0.isEmpty ? nil : $0 })
      var thumbnail: String?
      if let owner, let cover = entry.displayMetadata?.cover,
         let bytes = await reader.aiBookListThumbnail(cover) {
        thumbnail = try await AIImageStore.shared.save(bytes, owner: owner).id
      }
      try Task.checkCancellation()
      books.append(.init(book: book, needsDownload: entry.needsDownload, progress: entry.libraryProgressFraction,
                         coverSeed: entry.readingIdentity?.formalSHA256, thumbnail: thumbnail))
    }
    return (.init(data: .init(items: books.map(\.book))), books)
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
  func list(_ input: AILSInput) async throws -> AIToolResponse<AILibraryResult> {
    let items: [AIFileResult]
    if let parent = input.parentRef {
      let rows = try await reader.aiLibraryEntries(
        location(parent), input.sort == .recent ? .reading : .name)
      items = rows.filter {
        input.kind == nil || input.kind == .all
          || ($0.directory ? input.kind == .folders : input.kind == .books)
      }.map {
        var item = fileResult($0)
        switch $0.item {
        case .folder(let row):
          item.kind = "folder"
          item.ref = Self.ref("d", $0.shelfId + "/" + $0.relativePath)
          item.childBookCount = row.childBookCount
        case .book:
          item.kind = "file"
          item.ref = Self.ref("f", $0.id)
          item.childBookCount = 0
        }
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
      items, signature: signature("list_shelf", query), cursor: input.cursor, limit: input.limit ?? 100)
    return .init(data: .init(items: rows, parentRef: input.parentRef), page: page)
  }
  func getBook(_ input: AIGetBookInput) async throws -> AIToolResponse<AIBookResult> {
    let entry: LibraryEntry?
    let contentSHA: String?
    switch try ReadingToolTarget(input) {
    case .book(let reference):
      entry = nil
      contentSHA = reference.sha
    case .file(let reference, let policy):
      let source = try await AIReadingReferences(access: reader).file(reference)
      entry = source
      switch policy {
      case .prepare:
        let prepared = try await reader.preparedBookIdentity(source.source)
        guard let sha = prepared.formalSHA256 else { throw AIToolError("needs_preparation") }
        contentSHA = sha
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
    let details = try await reader.details(contentSHA)
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
        percent: ReadingProgress.percentage(book.positionUtf8, of: book.byteCount),
        chapterTitle: details.currentChapter)
      data.progress?.positionRef = AIPosition.ref(bookSHA: contentSHA, offset: book.positionUtf8)
    }
    return .init(data: data)
  }
  func chapters(_ input: AIChaptersInput) async throws -> AIToolResponse<AIChaptersResult> {
    let id = try await ready(input.bookRef)
    let outline = try await reader.chapters(id)
    let book = try await reader.book(id)
    let items: [AIChapterResult] = outline.items.enumerated().map { index, chapter in
      let end =
        outline.items.dropFirst(index + 1).first { $0.level <= chapter.level }?.startUtf8
        ?? book.byteCount
      var item = AIChapterResult(
        chapterRef: Self.ref("c", "\(input.bookRef):\(chapter.startUtf8)"), title: chapter.title,
        level: chapter.level,
        parentChapterRef: chapter.parentUtf8.map { Self.ref("c", "\(input.bookRef):\($0)") },
        range: .init(startUtf8: chapter.startUtf8, endUtf8: end), wordCount: chapter.wordCount,
        countComplete: chapter.countComplete, estimatedCoveredCharacters: chapter.coveredCharacters,
        estimatedCoveragePercent: chapter.coveredCharacters.map {
          chapter.wordCount == 0 ? 0 : min(100, Double($0) * 100 / Double(chapter.wordCount))
        })
      item.positionRef = position(input.bookRef, chapter.startUtf8)
      return item
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
  func readText(_ input: AIReadInput) async throws -> AIToolResponse<AIReadResult> {
    let ref = input.bookRef
    let id = try await ready(ref)
    let book = try await reader.book(id)
    let bounds = try await textBounds(id, chapterRef: input.chapterRef, size: book.byteCount, ref: ref)
    let lower = bounds.startUtf8
    let upper = bounds.endUtf8
    var context: TextRange?
    if let around = input.around {
      let offset = try AIPosition.offset(around, bookSHA: sha(ref), field: "around")
      guard offset >= lower, offset < upper else {
        throw AIToolError("invalid_argument", field: "around", message: "The position is outside the selected chapter.")
      }
      context = try await reader.textContext(id, offset,
        UInt32(clamping: input.beforeParagraphs ?? 3), UInt32(clamping: input.afterParagraphs ?? 3))
    }
    let requestedStart = context.map { max(lower, $0.startUtf8) } ?? lower
    let requestedEnd = context.map { min(upper, $0.endUtf8) } ?? upper
    guard requestedStart < requestedEnd else {
      throw AIToolError("invalid_argument", field: "around", message: "There is no text here.")
    }
    var query = input
    query.cursor = nil
    query.maxBytes = nil
    let signature = try signature("read_text", query) + ":\(lower):\(upper):\(requestedStart):\(requestedEnd)"
    var start = requestedStart
    if input.cursor != nil { start = UInt64(try cursorOffset(input.cursor, signature: signature)) }
    guard start >= requestedStart, start < requestedEnd else { throw AIToolError("stale_cursor", field: "cursor") }
    var end = min(requestedEnd, start + min(requestedEnd - start, UInt64(min(input.maxBytes ?? 51200, 51200))))
    var value: TextRange?
    for _ in 0..<4 {
      do {
        value = try await reader.textRange(id, start, end)
        break
      } catch ReaderError.InvalidRange {
        if end == requestedEnd { throw AIToolError("stale_reference", field: "around") }
        end -= 1
      }
    }
    guard let text = value else { throw AIToolError("stale_reference", field: "around") }
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
    var data = AIReadResult(bookRef: ref, text: content, range: range, sourceRef: source(ref, range).sourceRef)
    data.positionRef = position(ref, start)
    return .init(
      data: data,
      page: .init(nextCursor: next, complete: end == requestedEnd))
  }
  func searchText(_ input: AIRGInput) async throws -> AIToolResponse<AISearchResult> {
    var query = input
    query.cursor = nil; query.maxHits = nil
    query.mode = query.mode ?? .regex; query.caseSensitive = query.caseSensitive ?? true
    let querySignature = try signature("search_text", query)
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
      let start = bounds.startUtf8, end = bounds.endUtf8
      let job = try await reader.search(
        id, input.query, (input.mode ?? .regex) == .regex,
        input.caseSensitive ?? true, .init(startUtf8: start, endUtf8: end))
      defer { job.cancel() }
      var skippedContent = false
      try await withTaskCancellationHandler {
        while true {
          try Task.checkCancellation()
          let batch = try await reader.searchBatch(job)
          // Coverage warnings never terminate a scan. Completion/cancellation
          // and this tool's explicit pagination budget are independent signals.
          skippedContent = skippedContent || batch.truncated
          truncated = truncated || batch.truncated
          hits += batch.hits.prefix(max(0, target - hits.count)).map { hit in
            let range = AIToolRange(startUtf8: hit.startUtf8, endUtf8: hit.endUtf8)
            var item = AISearchHitResult(
              bookRef: ref, range: range, excerpt: String(hit.excerpt.prefix(500)),
              chapterTitle: hit.chapter, sourceRef: source(ref, range).sourceRef)
            item.positionRef = position(ref, hit.startUtf8)
            return item
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
  func marks(_ input: AIMarksInput) async throws -> AIToolResponse<AIMarksResult> {
    if let markRef = input.markRef {
      let one = try await mark(bookRef: input.bookRef, markRef: markRef, variantRef: input.variantRef, pageCursor: input.cursor)
      return .init(data: .init(bookRef: input.bookRef, items: [one.data]), page: one.page)
    }
    let ref = input.bookRef
    let groups = try await reader.aiMarks(sha(ref))
    var scope: AIToolRange?
    if input.chapterRef != nil {
      let id = try await ready(ref)
      scope = try await textBounds(id, chapterRef: input.chapterRef, size: reader.book(id).byteCount, ref: ref)
    }
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
      if let scope,
        !heads.contains(where: { c in
          guard let value = c.content else { return false }
          return candidate.bookmark
            ? value.start >= scope.startUtf8 && value.start < scope.endUtf8
            : value.start < scope.endUtf8 && value.end > scope.startUtf8
        })
      {
        continue
      }
      let range = AIToolRange(startUtf8: content.start, endUtf8: content.end)
      // Short notes arrive whole; only long notes need markRef to read on.
      var item = AIMarkResult(
        markRef: Self.ref("mark", markID), kind: kind.rawValue, range: range,
        excerpt: conflict ? "" : String(content.excerpt.prefix(500)),
        note: conflict ? "" : String(content.note.prefix(2000)),
        noteTruncated: content.note.count > 2000, excerptTruncated: content.excerpt.count > 500,
        hasConflict: conflict, createdAt: timestamp(Int64(candidate.created)),
        sourceRef: source(ref, range).sourceRef)
      item.positionRef = position(ref, content.start)
      rows.append((content.start, markID, item))
    }
    rows.sort { ($0.0, $0.1) < ($1.0, $1.1) }
    var query = input
    query.cursor = nil
    query.limit = nil
    query.kind = query.kind ?? .all
    let (items, page) = try page(
      rows.map(\.2), signature: signature("list_marks", query), cursor: input.cursor,
      limit: input.limit ?? 100)
    return .init(
      data: .init(bookRef: ref, items: items),
      page: page)
  }
  private func mark(bookRef ref: String, markRef: String, variantRef: String?, pageCursor: String?) async throws -> AIToolResponse<AIMarkResult> {
    let groups = try await reader.aiMarks(sha(ref))
    guard let heads = groups.first(where: { Self.ref("mark", $0.key) == markRef })?.value
    else { throw AIToolError("not_found", field: "markRef") }
    let readable = heads.compactMap { candidate in
      candidate.content.map { (candidate: candidate, content: $0) }
    }
    if variantRef == nil, !readable.isEmpty, AnnotationReduction.conflicts(heads) {
      return .init(
        data: .init(
          markRef: markRef, hasConflict: true,
          variants: readable.map { candidate, content in
            var variant = AIMarkVariant(
              variantRef: Self.ref("v", candidate.id),
              range: .init(startUtf8: content.start, endUtf8: content.end),
              noteSnippet: String(content.note.prefix(500)))
            variant.positionRef = position(ref, content.start)
            return variant
          }))
    }
    let selected = if let variant = variantRef {
      readable.first { Self.ref("v", $0.candidate.id) == variant }
    } else {
      readable.first
    }
    guard let (candidate, content) = selected else {
      throw AIToolError(variantRef == nil ? "not_found" : "stale_reference",
                        field: variantRef == nil ? "markRef" : "variantRef")
    }
    // Byte offsets keep continuation stable when maxBytes changes.
    let bytes = Array(content.note.utf8)
    let signature = "mark:\(ref):\(markRef):\(candidate.id)"
    var start = 0
    start = try cursorOffset(pageCursor, signature: signature)
    guard start <= bytes.count, String(bytes: bytes.prefix(start), encoding: .utf8) != nil else {
      throw AIToolError("stale_cursor", field: "cursor")
    }
    var end = min(bytes.count, start + min(bytes.count - start, 51200))
    while end > start, String(bytes: bytes[start..<end], encoding: .utf8) == nil { end -= 1 }
    var next: String?
    if end < bytes.count {
      next = try cursor(end, signature: signature)
    }
    let range = AIToolRange(startUtf8: content.start, endUtf8: content.end)
    var data = AIMarkResult(
      markRef: markRef, bookRef: ref, kind: candidate.bookmark ? "bookmark" : "annotation", range: range,
      excerpt: content.excerpt,
      noteText: String(decoding: bytes[start..<end], as: UTF8.self),
      excerptTruncated: false, sourceRef: source(ref, range).sourceRef)
    data.positionRef = position(ref, content.start)
    return .init(
      data: data,
      page: .init(nextCursor: next, complete: end == bytes.count))
  }
  private func timestamp(_ ms: Int64) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }
  func statistics(_ input: AIStatisticsInput) async throws -> AIToolResponse<
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
    let view = input.view ?? .summary
    let overview = view == .sessions ? nil : try await reader.statisticsRead(firstDay, lastDay, key)
    var incomplete = overview?.compatibilityNotice == nil ? nil : true
    if view == .summary {
      guard input.cursor == nil else {
        throw AIToolError(
          "invalid_argument", field: "cursor", message: "Summary has no pages. Omit cursor.")
      }
      guard let summary = overview?.value else { throw ReaderError.InvalidRange }
      return .init(
        data: .init(
          durationMs: summary.totalDurationMs, bookCount: summary.books.count,
          readingDays: summary.activeDayCount,
          recordingEnabledOnDevice: summary.preferences.enabled, dateBasis: "recorded_local_day",
          incomplete: incomplete))
    }
    func date(_ day: Int64) -> String {
      formatter.string(from: Date(timeIntervalSince1970: Double(day) * 86400))
    }
    let items: [AIStatisticsRow]
    switch view {
    case .days:
      guard let days = overview?.value.days else { throw ReaderError.InvalidRange }
      items = days.map {
        .init(date: date($0.day), durationMs: $0.durationMs, bookCount: $0.bookCount)
      }
    case .books:
      guard let books = overview?.value.books else { throw ReaderError.InvalidRange }
      items = books.map {
        .init(
          durationMs: $0.durationMs,
          bookRef: $0.contentKey.formalSHA256.map(Self.bookRef), title: $0.title,
          firstReadAt: timestamp($0.firstReadMs), lastReadAt: timestamp($0.lastReadMs),
          readingDays: $0.readingDays)
      }
    case .sessions:
      let read = try await reader.activitiesRead(firstDay, lastDay, key)
      incomplete = read.compatibilityNotice == nil ? nil : true
      items = read.value.map {
        .init(
          durationMs: $0.durationMs,
          bookRef: $0.contentKey.formalSHA256.map(Self.bookRef), title: $0.title,
          sessionRef: Self.ref("session", $0.id.reference), startedAt: timestamp($0.startedMs),
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
    return .init(data: .init(items: rows, incomplete: incomplete), page: page)
  }
  func environment(_ input: AIEnvironmentInput) -> AIToolResponse<AIEnvironmentResult> {
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
