import AISDKProvider
import SwiftData
import XCTest

@testable import Moonread

@MainActor final class AIReadingToolsTests: XCTestCase {
  func testPreparationConfirmationIncludesEveryIncompleteBookOnce() async throws {
    var visited: [String] = []
    let prompt = try await AIReadingTools.preparationConfirmation(["a", "ready", "b", "a"]) { ref in
      visited.append(ref)
      return ref == "ready" ? nil : (ref == "a" ? "第一本" : "第二本")
    }
    XCTAssertEqual(visited, ["a", "ready", "b"])
    XCTAssertTrue(try XCTUnwrap(prompt).contains("《第一本》、《第二本》"))
    let unnecessary = try await AIReadingTools.preparationConfirmation(["ready"]) { _ in nil }
    XCTAssertNil(unnecessary)
  }
  private func fixture(paragraphs: Int = 220) async throws -> (
    URL, ReaderService, ImportText, UserDataStore, AIReadingTools
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("book.txt")
    try ("第一章 月\n\n" + String(repeating: "甲乙丙丁你好。\n", count: paragraphs) + "第二章 星\n再次阅读\n").write(
      to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Book")
    let container = try ModelContainer(
      for: UserDataStore.schema,
      configurations: [
        ModelConfiguration(
          schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      ])
    let store = UserDataStore(modelContainer: container)
    let reader = ReaderService(
      core: core, sourceDefaultsSuite: "AI-\(root.lastPathComponent)",
      userStoreFactory: { _, _ in store })
    let shelf = try await reader.registerLibraryShelf(root)
    try await reader.refreshLibraryShelf(shelf)
    let fileEntry = try await reader.allLibraryBooks(shelf).first!
    try core.linkLibraryFile(fileId: fileEntry.id, bookId: book.id)
    return (root, reader, book, store, AIReadingTools(reader: reader))
  }
  private func invoke(_ tools: AIReadingTools, _ name: String, _ args: [String: JSONValue])
    async throws -> JSONValue
  {
    let tool = try XCTUnwrap(tools.definitions().first { $0.name == name })
    let value = JSONValue.object(args)
    let validation = await tool.sdkTool.inputSchema.resolve().validate(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)))
    if case .failure(let error) = validation { throw error }
    guard let execute = tool.sdkTool.execute else { throw AIAgentFailure.invalidTool }
    do { return try await execute(value, .init(toolCallId: UUID().uuidString, messages: [])).resolve() }
    catch let error as AIToolError { return AIAgentRuntime.errorResult(error.code, field: error.field, message: error.message) }
    catch ReaderError.InvalidRange { return AIAgentRuntime.errorResult("invalid_argument") }

  }
  func testPartialSearchPagesRemainUsableAsCommittedMetadataSources() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = AIReadingTools.bookRef(book.contentSha256), owner = "partial-search"
    let first = try await invoke(tools, "rg", ["bookRefs": .array([.string(ref)]), "query": .string("甲")])
    XCTAssertEqual(first.object["status"], .string("partial"))
    let firstHits = try XCTUnwrap(first.object["data"]?.object["hits"]?.array)
    XCTAssertEqual(firstHits.count, 100)
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let second = try await invoke(tools, "rg", ["bookRefs": .array([.string(ref)]), "query": .string("甲"), "maxHits": .number(2), "cursor": .string(cursor)])
    XCTAssertEqual(second.object["status"], .string("partial"))
    let secondHits = try XCTUnwrap(second.object["data"]?.object["hits"]?.array); XCTAssertEqual(secondHits.count, 2)
    let refs = [try XCTUnwrap(firstHits.first?.object["sourceRef"]?.string), try XCTUnwrap(secondHits.first?.object["sourceRef"]?.string)]
    let url = root.appending(path: "ai-sources.store"), repository = try await AIRepository.open(url: url)
    try await repository.create(.init(id: owner, title: "Search"))
    let entries = [first, second].enumerated().map { sequence, output in
      AIAgentEntry(sequence: sequence, turn: "search", provider: "fixture", model: "fixture", message: .object([
        "role": .string("tool"), "content": .array([.object(["type": .string("tool-result"), "toolCallId": .string("rg-\(sequence)"), "toolName": .string("rg"), "output": .object(["type": .string("json"), "value": output])])])
      ]))
    }
    var head = AIAgentHead(); head.nextSequence = entries.count
    try await repository.commit(owner, head: head, entries: entries)
    let reopened = try await AIRepository.open(url: url), registry = AIProposalRegistry(reader: reader)
    registry.history = { try await reopened.history($0, limit: nil) }
    let sources = try await registry.resolveSources(refs, owner: owner); XCTAssertEqual(sources.map(\.id), refs)
    _ = try await registry.prepare(.metadata(.init(proposalRef: "partial", bookRef: ref, author: "Author", sourceRefs: refs)), owner: owner)
  }
  func testSearchBudgetHasNoDuplicateSourcesAndKeepsPagination() async throws {
    let (root, _, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try await invoke(tools, "rg", ["bookRefs": .array([.string(AIReadingTools.bookRef(book.contentSha256))]), "query": .string("甲"), "maxHits": .number(50)])
    XCTAssertLessThan(try JSONEncoder().encode(result).count, 51200)
    XCTAssertTrue(result.object["sources"]?.array?.isEmpty ?? true)
    XCTAssertNotNil(result.object["page"]?.object["nextCursor"]?.string)
    let hit = try XCTUnwrap(result.object["data"]?.object["hits"]?.array?.first)
    XCTAssertNotNil(AIResultSource(hit))
    let next = try await invoke(tools, "read", ["bookRef": .string(AIReadingTools.bookRef(book.contentSha256)), "contextOffsetUtf8": hit.object["range"]!.object["startUtf8"]!, "beforeParagraphs": .number(1), "afterParagraphs": .number(1)])
    XCTAssertEqual(next.object["status"], .string("ok"))
    XCTAssertEqual(AIResultSource.all(in: next).count, 1)
    XCTAssertNil(next.object["data"]?.object["requestedRange"])
    XCTAssertNil(next.object["data"]?.object["textComplete"])
  }
  func testAllTenToolsAndCorrectedSearchUTF8AndNoReadingSideEffects() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertEqual(tools.definitions().count, 10)
    let ref = AIReadingTools.bookRef(book.contentSha256)
    let r = JSONValue.string(ref)
    let roots = try await invoke(tools, "ls", [:])
    XCTAssertEqual(roots.object["status"], .string("ok"))
    let books = try await invoke(tools, "search_books", ["query": .string("book")])
    XCTAssertTrue(String(decoding: try JSONEncoder().encode(books), as: UTF8.self).contains(ref))
    let details = try await invoke(tools, "get_book", ["bookRef": r])
    XCTAssertEqual(details.object["data"]?.object["bookRef"], r)
    try await reader.correctChapter(book.id, offset: 0, title: "已修正", level: 1)
    let chapters = try await invoke(tools, "get_chapters", ["bookRef": r])
    XCTAssertTrue(
      String(decoding: try JSONEncoder().encode(chapters), as: UTF8.self).contains("已修正"))
    let filtered = try await invoke(tools, "get_chapters", ["bookRef": r, "query": .string("已修正")])
    XCTAssertEqual(filtered.object["data"]?.object["items"]?.array?.count, 1)
    let absent = try await invoke(tools, "get_chapters", ["bookRef": r, "query": .string("无此章节")])
    XCTAssertTrue(absent.object["data"]?.object["items"]?.array?.isEmpty ?? false)
    let result = try await invoke(tools, "read", ["bookRef": r, "maxBytes": .number(1024)])
    let text = try XCTUnwrap(result.object["data"]?.object["text"]?.string)
    XCTAssertLessThanOrEqual(text.utf8.count, 1024)
    let cursor = try XCTUnwrap(result.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(
      tools, "read", ["bookRef": r, "maxBytes": .number(1024), "cursor": .string(cursor)])
    XCTAssertEqual(
      next.object["data"]?.object["range"]?.object["startUtf8"],
      result.object["data"]?.object["range"]?.object["endUtf8"])
    let invalid = try await invoke(
      tools, "read", ["bookRef": r, "startUtf8": .number(1), "endUtf8": .number(10)])
    XCTAssertEqual(invalid.object["status"], .string("error"))
    let hits = try await invoke(
      tools, "rg", ["bookRefs": .array([r]), "query": .string("甲"), "maxHits": .number(2)])
    XCTAssertTrue(String(decoding: try JSONEncoder().encode(hits), as: UTF8.self).contains("已修正"))
    let mark = try await reader.annotate(book.id, start: 0, end: 9)
    let marks = try await invoke(tools, "get_marks", ["bookRef": r])
    XCTAssertTrue(
      String(decoding: try JSONEncoder().encode(marks), as: UTF8.self).contains("annotation"))
    let full = try await invoke(
      tools, "get_mark", ["bookRef": r, "markRef": .string(AIReadingTools.ref("mark", mark.id))])
    XCTAssertEqual(full.object["status"], .string("ok"))
    let stats = try await invoke(
      tools, "get_reading_statistics",
      ["fromDate": .string("2026-10-01"), "toDate": .string("2026-10-03")])
    XCTAssertEqual(stats.object["data"]?.object["durationMs"], .number(0))
    let env = try await invoke(tools, "get_environment", [:])
    XCTAssertNotNil(env.object["data"]?.object["timeZone"])
    let after = try await reader.book(book.id)
    XCTAssertEqual(after.positionUtf8, 0)
  }
  func testScopedSearchAndContextReadUseToolBoundaries() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = AIReadingTools.bookRef(book.contentSha256)
    let chapters = try await reader.chapters(book.id).items
    let start = try XCTUnwrap(chapters.last).startUtf8
    let chapterRef = AIReadingTools.ref("c", "\(ref):\(start)")
    let result = try await invoke(tools, "rg", [
      "bookRefs": .array([.string(ref)]), "query": .string("再次"),
      "chapterRef": .string(chapterRef),
    ])
    let hit = try XCTUnwrap(result.object["data"]?.object["hits"]?.array?.first)
    let offset = try XCTUnwrap(hit.object["range"]?.object["startUtf8"])
    let context = try await invoke(tools, "read", [
      "bookRef": .string(ref), "contextOffsetUtf8": offset,
      "beforeParagraphs": .number(1), "afterParagraphs": .number(1),
      "chapterRef": .string(chapterRef),
    ])
    let text = try XCTUnwrap(context.object["data"]?.object["text"]?.string)
    XCTAssertTrue(text.contains("第二章"))
    XCTAssertTrue(text.contains("再次阅读"))
    XCTAssertFalse(text.contains("甲乙"))
    let earlier = try await invoke(tools, "rg", [
      "bookRefs": .array([.string(ref)]), "query": .string("再次"),
      "endUtf8": .number(Double(start)),
    ])
    XCTAssertEqual(earlier.object["data"]?.object["hits"]?.array?.count, 0)
    let invalid = try await invoke(tools, "read", [
      "bookRef": .string(ref), "contextOffsetUtf8": offset, "startUtf8": .number(0),
    ])
    XCTAssertEqual(invalid.object["status"], .string("error"))
    let tooLate = try await invoke(tools, "rg", [
      "bookRefs": .array([.string(ref)]), "query": .string("再次"),
      "chapterRef": .string(chapterRef), "startUtf8": .number(0),
    ])
    XCTAssertEqual(tooLate.object["status"], .string("error"))
    let after = try await reader.book(book.id)
    XCTAssertEqual(after.positionUtf8, 0)
  }

  func testUnknownFieldsAndConflictingAnnotationsDoNotPickWinner() async throws {
    let (root, _, book, store, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let tool = tools.definitions().first { $0.name == "read" }!
    let invalidSchema = await tool.sdkTool.inputSchema.resolve().validate(["bookRef": ref.string!, "path": "/tmp/file"])
    guard case .failure = invalidSchema else { return XCTFail("SDK must reject unknown fields") }
    let a = AnnotationCandidate(
      id: "a", ancestors: [], content: .init(start: 0, end: 9, excerpt: "第一章", note: "甲"),
      created: 1, bookmark: false)
    let b = AnnotationCandidate(
      id: "b", ancestors: [], content: .init(start: 0, end: 12, excerpt: "第一章 月", note: "乙"),
      created: 2, bookmark: false)
    try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: a)
    try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: b)
    let result = try await invoke(
      tools, "get_mark", ["bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "m"))])
    XCTAssertEqual(result.object["data"]?.object["hasConflict"], .bool(true))
  }
  func testReadLineBudgetContinuesAcrossToolInstances() async throws {
    let (root, reader, book, _, tools) = try await fixture(paragraphs: 2500)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let first = try await invoke(tools, "read", ["bookRef": ref])
    let prefix = try XCTUnwrap(first.object["data"]?.object["text"]?.string)
    XCTAssertEqual(prefix.filter { $0 == "\n" }.count, 2000)
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(AIReadingTools(reader: reader), "read", ["bookRef": ref, "cursor": .string(cursor)])
    let suffix = try XCTUnwrap(next.object["data"]?.object["text"]?.string)
    XCTAssertEqual(next.object["page"]?.object["complete"], .bool(true))
    let full = try await reader.textRange(book.id, start: 0, end: book.byteCount)
    XCTAssertEqual(prefix + suffix, full.text)
  }
  func testPreparationSharesLeaseAndDoesNotWriteReadingState() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let shelf = try await reader.shelves().first!
    let file = try await reader.allLibraryBooks(shelf.id).first!
    let definition = tools.definitions().first { $0.name == "get_book" }!
    let args = JSONValue.object([
      "fileRef": .string(AIReadingTools.ref("f", file.id)), "prepare": .bool(true),
    ])
    let prompt = try await definition.confirmation(args)
    XCTAssertNotNil(prompt)
    async let first = reader.aiPrepare(file.source)
    async let second = reader.aiPrepare(file.source)
    let (one, two) = try await (first, second)
    XCTAssertEqual(one.id, two.id)
    let current = try await reader.snapshot(one.id)
    XCTAssertEqual(current.book.contentSha256, book.contentSha256)
    XCTAssertEqual(current.book.positionUtf8, 0)
    let source = await reader.readingSourceIDs[one.id]
    XCTAssertNil(source)
    let stats = try await reader.statistics(first: 0, last: 30000)
    XCTAssertTrue(stats.books.isEmpty)
  }

}

extension AIReadingToolsTests {
  func testRecordedEmptyReferencesAreRejectedBySDKAndNullMeansAbsent() async throws {
    let (root, _, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let invalid: [(String, [String: JSONValue])] = [
      ("get_book", ["bookRef": ref, "fileRef": .string("")]),
      ("get_chapters", ["bookRef": ref, "cursor": .string("")]),
      ("read", ["bookRef": ref, "chapterRef": .string(""), "cursor": .string("")]),
      ("rg", ["bookRefs": .array([ref]), "query": .string("甲"), "maxHits": .number(0)]),
      ("get_environment", ["fields": .array([.string("secrets")])]),
    ]
    for (name, args) in invalid {
      do { _ = try await invoke(tools, name, args); XCTFail("SDK should reject \(name): \(args.keys)") }
      catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    let bookResult = try await invoke(tools, "get_book", ["bookRef": ref, "fileRef": .null])
    XCTAssertEqual(bookResult.object["status"], .string("ok"))
    let chapters = try await invoke(tools, "get_chapters", ["bookRef": ref, "cursor": .null])
    XCTAssertEqual(chapters.object["status"], .string("ok"))
    let text = try await invoke(tools, "read", ["bookRef": ref, "chapterRef": .null, "cursor": .null, "maxBytes": .number(1024)])
    XCTAssertEqual(text.object["status"], .string("ok"))
    let conflict = try await invoke(tools, "get_book", ["bookRef": ref, "fileRef": .string("f:unused")])
    XCTAssertEqual(conflict.object["error"]?.object["field"], .string("bookRef/fileRef"))
    XCTAssertNotNil(conflict.object["error"]?.object["message"]?.string)
  }

  func testSearchCursorAcceptsChangedPageSizeButRejectsChangedQuery() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let first = try await invoke(tools, "rg", ["bookRefs": .array([ref]), "query": .string("甲"), "maxHits": .number(8)])
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(AIReadingTools(reader: reader), "rg", ["bookRefs": .array([ref]), "query": .string("甲"), "mode": .string("regex"), "caseSensitive": .bool(true), "maxHits": .number(22), "cursor": .string(cursor)])
    XCTAssertEqual(next.object["status"], .string("partial"))
    let firstHits = try XCTUnwrap(first.object["data"]?.object["hits"]?.array)
    let nextHits = try XCTUnwrap(next.object["data"]?.object["hits"]?.array)
    XCTAssertEqual(firstHits.count, 8); XCTAssertEqual(nextHits.count, 22)
    XCTAssertLessThan(try XCTUnwrap(firstHits.last?.object["range"]?.object["startUtf8"]?.int), try XCTUnwrap(nextHits.first?.object["range"]?.object["startUtf8"]?.int))
    let changed = try await invoke(tools, "rg", ["bookRefs": .array([ref]), "query": .string("乙"), "cursor": .string(cursor)])
    XCTAssertEqual(changed.object["error"]?.object["code"], .string("stale_cursor"))
  }

  func testSDKGeneratedSchemaKeepsEveryTypedFieldAndEnums() async throws {
    let tools = AIReadingTools().definitions()
    XCTAssertEqual(tools.count, 10)
    let schema = try XCTUnwrap(tools.first { $0.name == "ls" }).schema.object
    XCTAssertEqual(Set(schema["properties"]!.object.keys), ["parentRef", "kind", "sort", "limit", "cursor"])
    XCTAssertTrue(String(decoding: try JSONEncoder().encode(schema["properties"]!.object["kind"]!), as: UTF8.self).contains("folders"))
    XCTAssertEqual(schema["additionalProperties"], .bool(false))
    let examples: [(String, JSONValue)] = [
      ("ls", .object(["kind": .string("folders"), "sort": .string("name")])),
      ("search_books", .object(["tags": .array([.string("奇幻")]), "readingStatus": .string("reading"), "sort": .string("recent")])),
      ("get_marks", .object(["bookRef": .string("b:fixture"), "kind": .string("annotation")])),
      ("get_reading_statistics", .object(["fromDate": .string("2026-10-01"), "toDate": .string("2026-10-04"), "view": .string("days")])),
      ("get_environment", .object(["fields": .array([.string("time"), .string("locale")])])),
    ]
    for (name, input) in examples {
      let definition = try XCTUnwrap(tools.first { $0.name == name })
      let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
      guard case .success = await definition.sdkTool.inputSchema.resolve().validate(value) else { return XCTFail("Invalid generated schema for \(name)") }
    }
  }
}


extension AIReadingToolsTests {
  func testNoteCursorUsesUTF8OffsetWhenPageSizeChanges() async throws {
    let (root, _, book, store, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let note = String(repeating: "甲乙🙂", count: 500)
    let candidate = AnnotationCandidate(id: "long-note", ancestors: [], content: .init(start: 0, end: 9, excerpt: "第一章", note: note), created: 1, bookmark: false)
    try await store.receiveFixture(key: book.contentSha256, mark: "long", candidate: candidate)
    let listing = try await invoke(tools, "get_marks", ["bookRef": .string(AIReadingTools.bookRef(book.contentSha256))])
    let preview = try XCTUnwrap(listing.object["data"]?.object["items"]?.array?.first)
    XCTAssertEqual(preview.object["note"]?.string?.count, 500)
    XCTAssertEqual(preview.object["noteTruncated"], .bool(true))
    XCTAssertLessThan(try JSONEncoder().encode(listing).count, 8000)
    XCTAssertEqual(AIResultSource.all(in: listing).count, 1)
    var args: [String: JSONValue] = ["bookRef": .string(AIReadingTools.bookRef(book.contentSha256)), "markRef": .string(AIReadingTools.ref("mark", "long")), "maxBytes": .number(1024)]
    var joined = ""
    for _ in 0..<10 {
      let result = try await invoke(tools, "get_mark", args)
      XCTAssertEqual(result.object["status"], .string("ok"))
      joined += try XCTUnwrap(result.object["data"]?.object["noteText"]?.string)
      guard let cursor = result.object["page"]?.object["nextCursor"]?.string else { break }
      args["cursor"] = .string(cursor)
      args["maxBytes"] = .number(2048)
    }
    XCTAssertEqual(joined, note)
  }
}
