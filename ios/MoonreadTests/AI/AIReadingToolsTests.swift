@testable import MoonreadData
@testable import MoonreadAI
import MoonreadCoreBindings
import AISDKProvider
import SwiftData
import XCTest

@testable import Moonread

final class AIReadingToolsTests: AIReadingToolsFixture {
  func testFilteredLookupSharesSearchOrderCountsAndExactBookListTargets() async throws {
    let (root, reader, book, store, tools) = try await fixture()
    defer { try? store.index.session.close(); try? FileManager.default.removeItem(at: root) }
    let shelf = try await reader.shelves().first { !$0.builtin }
    let shelfID = try XCTUnwrap(shelf?.id)
    let folder = root.appendingPathComponent("Subfolder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: root.appendingPathComponent("book.txt"), to: root.appendingPathComponent("a.txt"))
    try "Not indexed".write(to: folder.appendingPathComponent("unindexed.txt"), atomically: true, encoding: .utf8)
    try await reader.refreshLibraryShelf(shelfID)
    let files = try await reader.allLibraryBooks(shelfID)
    try store.index.linkLibraryFile(fileId: XCTUnwrap(files.first { $0.name == "a.txt" }?.id), bookId: book.id)
    let filter: JSONValue = .object(["match": .string("all"), "rules": .array([.object(["status": .array([.string("unread")])])])])
    let sorts: JSONValue = .array([.object(["field": .string("name"), "descending": .bool(false)])])
    let configuration = try JSONDecoder().decode(AIBookFilterArguments.self, from: JSONEncoder().encode(
      JSONValue.object(["filter": filter, "sorts": sorts]))).stored().configuration { $0 }
    let search = try await reader.searchLibrary(query: "", configuration: configuration)
    XCTAssertEqual(search.entries.count, 2)
    XCTAssertEqual(search.unknownCount, 1)

    let first = try await invoke(tools, "find_books", ["filter": filter, "sorts": sorts, "limit": .number(1)])
    XCTAssertEqual(first.object["status"], .string("partial"))
    XCTAssertEqual(first.object["data"]?.object["totalMatches"]?.int, search.entries.count)
    XCTAssertEqual(first.object["data"]?.object["unknownCount"]?.int, search.unknownCount)
    let item = try XCTUnwrap(first.object["data"]?.object["items"]?.array?.first?.object)
    XCTAssertEqual(item["readingStatus"], .string("unread"))
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"])
    let second = try await invoke(tools, "find_books", ["filter": filter, "sorts": sorts, "limit": .number(5), "cursor": cursor])
    let next = try XCTUnwrap(second.object["data"]?.object["items"]?.array?.first?.object)
    XCTAssertEqual([item["fileRef"]?.string, next["fileRef"]?.string], search.entries.map { AIReference.make("f", $0.id) })
    XCTAssertEqual(second.object["page"]?.object["complete"], .bool(true))
    XCTAssertEqual(item["bookRef"], next["bookRef"], "Duplicate files have distinct file references and the same formal book reference")
    let stale = try await invoke(tools, "find_books", ["sorts": sorts, "cursor": cursor])
    XCTAssertEqual(stale.object["error"]?.object["code"], .string("stale_cursor"))

    let everything = try await invoke(tools, "find_books", [:])
    XCTAssertGreaterThanOrEqual(everything.object["data"]?.object["totalMatches"]?.int ?? 0, search.entries.count,
      "Without keywords, filter or sorts the whole library is listed")
    let excluded = try await invoke(tools, "find_books", ["query": .string(search.entries[0].title),
      "filter": .object(["match": .string("all"), "rules": .array([.object(["status": .array([.string("finished")])])])])])
    XCTAssertEqual(excluded.object["data"]?.object["totalMatches"]?.int, 0, "Keywords never bypass the filter")
    let generalSearch = try await invoke(tools, "find_books", ["query": .string(search.entries[0].title)])
    let formal = try XCTUnwrap(generalSearch.object["data"]?.object["items"]?.array?.first?.object["bookRef"])
    let contents = try await invoke(tools, "list_shelf", ["parentRef": .string(AIReference.make("d", shelfID + "/Subfolder"))])
    let fromFolder = try XCTUnwrap(contents.object["data"]?.object["items"]?.array?.first?.object["fileRef"])
    let refs = [try XCTUnwrap(next["fileRef"]), formal, fromFolder]
    let details = AIToolResultDetails(item: .init(id: "query", kind: .tool, name: "find_books",
      input: .object(["filter": filter, "sorts": sorts, "limit": .number(1)]), output: first), outcome: .completed, hasReplyResult: false)
    XCTAssertTrue(details.opensDetail)
    XCTAssertEqual(details.bookResult?.rows.map(\.text), [search.entries[0].title])
    XCTAssertNotNil(details.requestedFilter?.root)
    let shown = try await invoke(tools, "show_books", ["refs": .array(refs)])
    XCTAssertEqual(shown.object["data"]?.object["items"]?.array?.compactMap { $0.object["ref"] }, refs)
    for rejected in [[refs[0], refs[0]], Array(repeating: refs[0], count: 6)] {
      let args = try JSONDecoder().decode(AIShowBookListInput.self, from: JSONEncoder().encode(["refs": JSONValue.array(rejected)]))
      XCTAssertThrowsError(try args.validate()) { XCTAssertEqual(($0 as? AIToolError)?.code, "invalid_argument") }
    }
    let entries = try await reader.libraryEntries(.init(shelfID: shelfID))
    let folderID = try XCTUnwrap(entries.first(where: \.directory)?.id)
    let folderRef = JSONValue.string(AIReference.make("f", folderID))
    let invalid = try await invoke(tools, "show_books", ["refs": .array([folderRef])])
    XCTAssertEqual(invalid.object["error"]?.object["field"], .string("refs[0]"))
    XCTAssertEqual(invalid.object["error"]?.object["code"], .string("invalid_argument"))

    try FileManager.default.removeItem(at: root.appendingPathComponent(search.entries[1].relativePath))
    try await reader.refreshLibraryShelf(shelfID)
    let resolved = try await reader.aiBookListEntries(refs.compactMap(\.string))
    XCTAssertNil(resolved.entries[refs[0].string!])
    XCTAssertNotNil(resolved.entries[refs[1].string!], "Removing a selected file does not discard a separate formal book target")
  }

  func testFilterToolsKeepExactNamesAndReplayOnlySuccessfulCommittedSuggestions() async throws {
    let (root, reader, book, store, tools) = try await fixture()
    defer { try? store.index.session.close(); try? FileManager.default.removeItem(at: root) }
    let base = try await reader.details(sha: book.fixtureSHA256).metadata
    var edited = base
    edited.author = "Fixture Author"
    edited.tags = ["推理", "e\u{301}"]
    try await reader.saveMetadata(base: base, edited: edited)

    let options = try await invoke(tools, "list_filter_values", ["field": .string("tag"), "query": .string("推理")])
    XCTAssertEqual(options.object["data"], .object(["names": .array([.string("推理")])]))
    let authors = try await invoke(tools, "list_filter_values", ["field": .string("author")])
    XCTAssertEqual(authors.object["data"], .object(["names": .array([.string("Fixture Author")])]))
    let sorts: [JSONValue] = [
      .object(["field": .string("recent"), "descending": .bool(true)]),
      .object(["field": .string("name"), "descending": .bool(false)]),
    ]
    var rules: [JSONValue] = [
      .object(["match": .string("any"), "exclude": .bool(true), "rules": .array([
        .object(["authors": .array([.string("Fixture Author")])]),
        .object(["untagged": .bool(true)]),
      ])]),
      .object(["tags": .array([.string("推理")]), "tagMatch": .string("any")]),
      .object(["status": .array([.string("unread")])]),
    ]
    let result = try await invoke(tools, "propose_book_filter", [
      "filter": .object(["match": .string("all"), "rules": .array(rules)]), "sorts": .array(sorts)])
    func history(_ value: JSONValue, role: String = "tool") -> AIAgentEntry {
      .init(sequence: 2, turn: "fixture", provider: "fixture", model: "fixture",
            message: .object(["role": .string(role), "content": .array([.object([
              "type": .string("tool-result"), "toolName": .string("propose_book_filter"), "toolCallId": .string("call"),
              "output": .object(["type": .string("json"), "value": value]),
            ])])]))
    }
    let persisted = try JSONDecoder().decode(AIAgentEntry.self, from: JSONEncoder().encode(history(result)))
    let card = try XCTUnwrap(AICommittedResultDecoder.results(persisted, sessionID: "session").first)
    guard case .bookFilter(let suggestion, _) = card.body else { return XCTFail("Expected a filter card") }
    let configuration = try suggestion.resolveShelves([]).configuration(suggestion)
    XCTAssertEqual(configuration.sorts, [.init(field: .recent, descending: true), .init(field: .name)])
    XCTAssertEqual(configuration.root.children.first?.group, .any)
    XCTAssertEqual(configuration.root.children.first?.excluded, true)
    XCTAssertEqual(configuration.root.children.first?.children.last?.values, [.untagged])
    let matches = try await reader.searchLibrary(query: "", configuration: configuration)
    XCTAssertTrue(matches.entries.isEmpty, "An excluded author must not be dropped during replay")
    XCTAssertTrue(AICommittedResultDecoder.results(history(result, role: "assistant"), sessionID: "session").isEmpty)

    let sortOnly = try await invoke(tools, "propose_book_filter", ["sorts": .array(sorts)])
    XCTAssertEqual(sortOnly.object["status"], .string("ok"))
    rules[1] = .object(["tags": .array([.string("é")])])
    let failed = try await invoke(tools, "propose_book_filter", [
      "filter": .object(["match": .string("all"), "rules": .array(rules)]), "sorts": .array([])])
    XCTAssertEqual(failed.object["error"]?.object["field"], .string("tag"), "Canonically equivalent names must still match the stored UTF-8")
    XCTAssertTrue(AICommittedResultDecoder.results(history(failed), sessionID: "session").isEmpty)
  }

  func testFilterShelfResolutionKeepsAmbiguityAndResolvesOnlyLocalIDs() throws {
    let input = try JSONDecoder().decode(AIBookFilterInput.self, from: Data("""
      {"nodes":[{"kind":"group","relation":"all"},{"kind":"shelf","parent":0,"values":["Fixture"]}],"sorts":[]}
      """.utf8))
    let first = LibraryShelf(id: "first", name: "Fixture", bookmark: Data(), location: "external", builtin: false, error: nil, bookCount: 0)
    let second = LibraryShelf(id: "second", name: "Fixture", bookmark: Data(), location: "icloud", builtin: false, error: nil, bookCount: 0)
    let unresolved = AIBookFilterSuggestion(filter: input, shelves: [])
    let choices = unresolved.resolveShelves([first, second])
    XCTAssertFalse(choices.complete)
    XCTAssertEqual(choices.choices.first?.candidates.map(\.id), [first.id, second.id])
    let selection = unresolved.resolveShelves([first, second], selected: [Data("Fixture".utf8): second.id])
    XCTAssertEqual(try selection.configuration(unresolved).root.children.first?.values, [.text(second.id)])
    let saved = AIBookFilterSuggestion(filter: input, shelves: [.init(name: first.name, reference: AIBookFilterSuggestion.shelfReference(first))])
    XCTAssertEqual(try saved.resolveShelves([first, second]).configuration(saved).root.children.first?.values, [.text(first.id)])
    XCTAssertFalse(saved.resolveShelves([second]).complete, "A same-name replacement needs a new local choice")
    XCTAssertEqual(saved.resolveShelves([]).unavailable, [first.name])
  }

  func testSearchContinuesAfterSkippedLongRegexLine() async throws {
    let text = String(repeating: "a", count: 1024 * 1024 + 8192) + "\n"
      + String(repeating: "b", count: 512 * 1024) + "\n后续命中🌙\n"
    let (root, _, book, _, tools) = try await fixture(text: text)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let result = try await invoke(tools, "search_text", ["bookRefs": .array([ref]), "query": .string("后续命中")])
    let data = try XCTUnwrap(result.object["data"])
    let hits = try XCTUnwrap(data.object["hits"]?.array)
    XCTAssertEqual(hits.count, 1, "A skipped line must not terminate later batches")
    XCTAssertTrue(hits.first?.object["excerpt"]?.string?.contains("后续命中") == true)
    let coverage = try XCTUnwrap(data.object["coverage"]?.array?.first)
    XCTAssertEqual(coverage.object["scannedUtf8"], .number(Double(book.byteCount)))
    XCTAssertEqual(coverage.object["complete"], .bool(false))
    XCTAssertEqual(data.object["truncated"], .bool(true))
    XCTAssertEqual(result.object["status"], .string("partial"))
  }

  // #378: 模型只回传工具给出的位置引用；批注用「附近位置 + 原文」定位，改过的引用被拒绝。
  func testPositionReferencesAndQuotedNoteRanges() async throws {
    let text = "第一章 开端\n甲乙丙丁。重复的句子。\n戊己庚辛。重复的句子。\n"
    let (root, reader, book, _, tools) = try await fixture(text: text)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let hit = try await invoke(tools, "search_text", ["bookRefs": .array([ref]), "query": .string("戊己"), "mode": .string("literal")])
    let position = try XCTUnwrap(hit.object["data"]?.object["hits"]?.array?.first?.object["positionRef"]?.string)
    let around = try await invoke(tools, "read_text", ["bookRef": ref, "around": .string(position)])
    XCTAssertTrue(around.object["data"]?.object["text"]?.string?.contains("戊己庚辛") == true)
    let tampered = position.replacingOccurrences(of: "p:", with: "p:1")
    let rejected = try await invoke(tools, "read_text", ["bookRef": ref, "around": .string(tampered)])
    XCTAssertEqual(rejected.object["error"]?.object["code"], .string("stale_reference"))

    let registry = await AIProposalRegistry(reader: reader)
    let references = AIReadingReferences(reader: reader)
    let (start, end) = try await registry.quoteRange(bookRef: ref.string!, near: position, quote: "庚辛", references: references)
    let quoted = try await reader.textRange(book.id, start: start, end: end)
    XCTAssertEqual(quoted.text, "庚辛")
    for quote in ["重复的句子", "不存在的句子"] {
      do {
        _ = try await registry.quoteRange(bookRef: ref.string!, near: position, quote: quote, references: references)
        XCTFail("An ambiguous or missing quote must be rejected: \(quote)")
      } catch let error as AIToolError { XCTAssertEqual(error.field, "quote") }
    }
  }

  // #378: 原文查找范围的终点按字节估算，落在中文字中间时仍按所在段落取，不因对齐失败报错。
  func testQuotedNoteWindowEndsInsideMultibyteText() async throws {
    let text = "开头\n\n" + String(repeating: "字", count: 30000) + "\n结尾。\n"
    let (root, reader, book, _, tools) = try await fixture(text: text)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let hit = try await invoke(tools, "search_text", ["bookRefs": .array([ref]), "query": .string("开头"), "mode": .string("literal")])
    let position = try XCTUnwrap(hit.object["data"]?.object["hits"]?.array?.first?.object["positionRef"]?.string)
    let registry = await AIProposalRegistry(reader: reader)
    let (start, end) = try await registry.quoteRange(bookRef: ref.string!, near: position, quote: "开头",
                                                     references: AIReadingReferences(reader: reader))
    let quoted = try await reader.textRange(book.id, start: start, end: end)
    XCTAssertEqual(quoted.text, "开头")
  }

  // S131: AI 准备未完整书籍必须列出准确确认对象，不遗漏或重复授权范围。
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

  // S134: 保留一个 read 工具边界：传正确 book/scope 给 AppDataService，映射 UTF-8 结果且不产生阅读写入；删十工具成功矩阵和底层算法重测。
  func testAllTenToolsAndCorrectedSearchUTF8AndNoReadingSideEffects() async throws {
    let (root, reader, book, _, tools) = try await fixture(paragraphs: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let before = try await reader.book(book.id)
    let result = try await invoke(tools, "read_text", ["bookRef": ref, "maxBytes": .number(32)])
    XCTAssertEqual(result.object["status"], .string("ok"))
    let value = try XCTUnwrap(result.object["data"]?.object["text"]?.string)
    XCTAssertFalse(value.contains("�"))
    XCTAssertFalse(value.isEmpty)
    XCTAssertEqual(result.object["data"]?.object["bookRef"], ref)
    let after = try await reader.book(book.id)
    XCTAssertEqual(
      after.positionUtf8, before.positionUtf8,
      "tool reads must not change the user's reading position")
  }

  // S136: 工具返回真实冲突/未知状态，不代用户选赢家；冲突算法只在用户事实测试保留。
  func testUnknownFieldsAndConflictingAnnotationsDoNotPickWinner() async throws {
    let (root, _, book, store, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let tool = tools.definitions().first { $0.name == "read_text" }!
    let invalidSchema = await tool.sdkTool.inputSchema.resolve().validate([
      "bookRef": ref.string!, "path": "/tmp/file",
    ])
    guard case .failure = invalidSchema else { return XCTFail("SDK must reject unknown fields") }
    let a = AnnotationCandidate(
      id: "a", ancestors: [], content: .init(start: 0, end: 9, excerpt: "第一章", note: "甲"),
      created: 1, bookmark: false)
    let b = AnnotationCandidate(
      id: "b", ancestors: [], content: .init(start: 0, end: 12, excerpt: "第一章 月", note: "乙"),
      created: 2, bookmark: false)
    try store.seedAnnotation(key: book.fixtureSHA256, mark: "m", candidate: a)
    try store.seedAnnotation(key: book.fixtureSHA256, mark: "m", candidate: b)
    let deletedVariant = AnnotationCandidate(
      id: "removed-variant", ancestors: [], content: nil, created: 3, bookmark: false)
    let deletedMark = AnnotationCandidate(
      id: "removed-mark", ancestors: [], content: nil, created: 4, bookmark: false)
    try store.seedAnnotation(key: book.fixtureSHA256, mark: "m", candidate: deletedVariant)
    try store.seedAnnotation(key: book.fixtureSHA256, mark: "removed", candidate: deletedMark)

    let args: [String: JSONValue] = [
      "bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "m")),
    ]
    let result = try await invoke(tools, "list_marks", args)
    let data = try XCTUnwrap(result.object["data"]?.object["items"]?.array?.first)
    XCTAssertEqual(data.object["hasConflict"], .bool(true))
    let variants = try XCTUnwrap(data.object["variants"]?.array)
    XCTAssertEqual(variants.count, 2)
    XCTAssertEqual(Set(variants.compactMap { $0.object["variantRef"]?.string }), [
      AIReadingTools.ref("v", a.id), AIReadingTools.ref("v", b.id),
    ])
    XCTAssertTrue(variants.allSatisfy { $0.object["deleted"] == nil })

    var selected = args
    selected["variantRef"] = .string(AIReadingTools.ref("v", a.id))
    let living = try await invoke(tools, "list_marks", selected)
    let chosen = living.object["data"]?.object["items"]?.array?.first?.object
    XCTAssertEqual(chosen?["noteText"], .string("甲"))
    XCTAssertNil(chosen?["deleted"])
    XCTAssertNotNil(chosen?["positionRef"], "A mark returns a position the model can read around")

    selected["variantRef"] = .string(AIReadingTools.ref("v", deletedVariant.id))
    let stale = try await invoke(tools, "list_marks", selected)
    XCTAssertEqual(stale.object["error"]?.object["code"], .string("stale_reference"))
    XCTAssertEqual(stale.object["error"]?.object["field"], .string("variantRef"))
    XCTAssertNil(stale.object["data"])

    let missing = try await invoke(tools, "list_marks", [
      "bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "removed")),
    ])
    XCTAssertEqual(missing.object["error"]?.object["code"], .string("not_found"))
    XCTAssertEqual(missing.object["error"]?.object["field"], .string("markRef"))
    XCTAssertNil(missing.object["data"])
  }

  // S137: 工具续页范围拼接不截断 Unicode，重建工具实例后仍续接；正文/笔记各一页边界，不跑 2500 行。
  func testReadLineBudgetContinuesAcrossToolInstances() async throws {
    let (root, reader, book, _, _) = try await fixture(paragraphs: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let tools = AIReadingTools(reader: reader, lineLimit: 2)
    let first = try await invoke(tools, "read_text", ["bookRef": ref])
    let prefix = try XCTUnwrap(first.object["data"]?.object["text"]?.string)
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(
      AIReadingTools(reader: reader, lineLimit: 2), "read_text",
      ["bookRef": ref, "cursor": .string(cursor)])
    let suffix = try XCTUnwrap(next.object["data"]?.object["text"]?.string)
    XCTAssertEqual(
      next.object["data"]?.object["range"]?.object["startUtf8"],
      first.object["data"]?.object["range"]?.object["endUtf8"])
    XCTAssertFalse((prefix + suffix).contains("�"), "a page boundary cannot split Unicode")
    XCTAssertFalse(suffix.isEmpty)
  }

  // S138: 工具准备共享工作但不写正式阅读状态/统计；只测 Swift lease 和写入边界。
  func testPreparationSharesLeaseAndDoesNotWriteReadingState() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let shelf = try await reader.shelves().first!
    let file = try await reader.allLibraryBooks(shelf.id).first!
    let definition = tools.definitions().first { $0.name == "get_book_info" }!
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
    XCTAssertEqual(current.book.fixtureSHA256, book.fixtureSHA256)
    XCTAssertEqual(current.book.positionUtf8, 0)
    let source = await reader.readingSourceIDs[one.id]
    XCTAssertNil(source)
    let stats = try await reader.statistics(first: 0, last: 30000)
    XCTAssertTrue(stats.books.isEmpty)
  }

  // S139: 改为一条工具输入契约：空引用拒绝、null 可省略，非法调用零业务副作用；不验证 SDK 生成 schema 字段全集。
  func testRecordedEmptyReferencesAreRejectedBySDKAndNullMeansAbsent() async throws {
    let (root, reader, book, _, tools) = try await fixture(paragraphs: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    try await reader.savePosition(bookID: book.id, offset: 3)
    let before = try await reader.book(book.id)
    do {
      _ = try await invoke(tools, "get_book_info", ["bookRef": ref, "fileRef": .string("")])
      XCTFail("empty recorded references must be rejected")
    } catch {}
    let value = try await invoke(tools, "get_book_info", ["bookRef": ref, "fileRef": .null])
    XCTAssertEqual(value.object["status"], .string("ok"))
    let progress = value.object["data"]?.object["progress"]?.object
    XCTAssertEqual(progress?["offsetUtf8"], .number(3))
    guard case let .number(percent)? = progress?["percent"] else {
      return XCTFail("Expected a numeric percentage")
    }
    XCTAssertEqual(percent, 300 / Double(book.byteCount), accuracy: 1e-12)
    let after = try await reader.book(book.id)
    XCTAssertEqual(
      after.positionUtf8, before.positionUtf8,
      "invalid inputs must not produce reading side effects")
  }

  // S140: 工具分页 cursor 绑定查询而非页大小，跨页无重复来源；两个页面且变更一次 query。
  func testSearchCursorAcceptsChangedPageSizeButRejectsChangedQuery() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.fixtureSHA256))
    let first = try await invoke(
      tools, "search_text", ["bookRefs": .array([ref]), "query": .string("甲"), "maxHits": .number(2)])
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(
      AIReadingTools(reader: reader), "search_text",
      [
        "bookRefs": .array([ref]), "query": .string("甲"), "mode": .string("regex"),
        "caseSensitive": .bool(true), "maxHits": .number(3), "cursor": .string(cursor),
      ])
    XCTAssertEqual(next.object["status"], .string("partial"))
    let firstHits = try XCTUnwrap(first.object["data"]?.object["hits"]?.array)
    let nextHits = try XCTUnwrap(next.object["data"]?.object["hits"]?.array)
    XCTAssertEqual(firstHits.count, 2)
    XCTAssertEqual(nextHits.count, 3)
    XCTAssertLessThan(
      try XCTUnwrap(firstHits.last?.object["range"]?.object["startUtf8"]?.int),
      try XCTUnwrap(nextHits.first?.object["range"]?.object["startUtf8"]?.int))
    let changed = try await invoke(
      tools, "search_text", ["bookRefs": .array([ref]), "query": .string("乙"), "cursor": .string(cursor)])
    XCTAssertEqual(changed.object["error"]?.object["code"], .string("stale_cursor"))
  }
}
