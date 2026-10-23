import AISDKProvider
import SwiftData
import XCTest

@testable import Moonread

final class AIReadingToolsTests: AIReadingToolsFixture {
  func testSearchContinuesAfterSkippedLongRegexLine() async throws {
    let text = String(repeating: "a", count: 1024 * 1024 + 8192) + "\n"
      + String(repeating: "b", count: 512 * 1024) + "\n后续命中🌙\n"
    let (root, _, book, _, tools) = try await fixture(text: text)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let result = try await invoke(tools, "rg", ["bookRefs": .array([ref]), "query": .string("后续命中")])
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

  // S134: 保留一个 read 工具边界：传正确 book/scope 给 ReaderService，映射 UTF-8 结果且不产生阅读写入；删十工具成功矩阵和底层算法重测。
  func testAllTenToolsAndCorrectedSearchUTF8AndNoReadingSideEffects() async throws {
    let (root, reader, book, _, tools) = try await fixture(paragraphs: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let before = try await reader.book(book.id)
    let result = try await invoke(tools, "read", ["bookRef": ref, "maxBytes": .number(32)])
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
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let tool = tools.definitions().first { $0.name == "read" }!
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
    try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: a)
    try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: b)
    let result = try await invoke(
      tools, "get_mark", ["bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "m"))])
    XCTAssertEqual(result.object["data"]?.object["hasConflict"], .bool(true))
  }

  // S137: 工具续页范围拼接不截断 Unicode，重建工具实例后仍续接；正文/笔记各一页边界，不跑 2500 行。
  func testReadLineBudgetContinuesAcrossToolInstances() async throws {
    let (root, reader, book, users, _) = try await fixture(paragraphs: 3)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let tools = AIReadingTools(reader: reader, lineLimit: 2)
    let first = try await invoke(tools, "read", ["bookRef": ref])
    let prefix = try XCTUnwrap(first.object["data"]?.object["text"]?.string)
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(
      AIReadingTools(reader: reader, lineLimit: 2), "read",
      ["bookRef": ref, "cursor": .string(cursor)])
    let suffix = try XCTUnwrap(next.object["data"]?.object["text"]?.string)
    XCTAssertEqual(
      next.object["data"]?.object["range"]?.object["startUtf8"],
      first.object["data"]?.object["range"]?.object["endUtf8"])
    XCTAssertFalse((prefix + suffix).contains("�"), "a page boundary cannot split Unicode")
    XCTAssertFalse(suffix.isEmpty)
    let note = "甲乙🙂第二段🌙"
    let candidate = AnnotationCandidate(
      id: "note-page", ancestors: [], content: .init(start: 0, end: 9, excerpt: "第一章", note: note),
      created: 1, bookmark: false)
    try await users.receiveFixture(key: book.contentSha256, mark: "paged", candidate: candidate)
    let firstNote = try await invoke(
      tools, "get_mark",
      [
        "bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "paged")),
        "maxBytes": .number(8),
      ])
    let noteCursor = try XCTUnwrap(firstNote.object["page"]?.object["nextCursor"]?.string)
    let rest = try await invoke(
      AIReadingTools(reader: reader), "get_mark",
      [
        "bookRef": ref, "markRef": .string(AIReadingTools.ref("mark", "paged")),
        "cursor": .string(noteCursor), "maxBytes": .number(32),
      ])
    XCTAssertEqual(
      (firstNote.object["data"]?.object["noteText"]?.string ?? "")
        + (rest.object["data"]?.object["noteText"]?.string ?? ""), note,
      "note pagination must preserve UTF-8 when the byte budget changes")
  }

  // S138: 工具准备共享工作但不写正式阅读状态/统计；只测 Swift lease 和写入边界。
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

  // S139: 改为一条工具输入契约：空引用拒绝、null 可省略，非法调用零业务副作用；不验证 SDK 生成 schema 字段全集。
  func testRecordedEmptyReferencesAreRejectedBySDKAndNullMeansAbsent() async throws {
    let (root, reader, book, _, tools) = try await fixture(paragraphs: 1)
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let before = try await reader.book(book.id)
    do {
      _ = try await invoke(tools, "get_book", ["bookRef": ref, "fileRef": .string("")])
      XCTFail("empty recorded references must be rejected")
    } catch {}
    let value = try await invoke(tools, "get_book", ["bookRef": ref, "fileRef": .null])
    XCTAssertEqual(value.object["status"], .string("ok"))
    let after = try await reader.book(book.id)
    XCTAssertEqual(
      after.positionUtf8, before.positionUtf8,
      "invalid inputs must not produce reading side effects")
  }

  // S140: 工具分页 cursor 绑定查询而非页大小，跨页无重复来源；两个页面且变更一次 query。
  func testSearchCursorAcceptsChangedPageSizeButRejectsChangedQuery() async throws {
    let (root, reader, book, _, tools) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let ref = JSONValue.string(AIReadingTools.bookRef(book.contentSha256))
    let first = try await invoke(
      tools, "rg", ["bookRefs": .array([ref]), "query": .string("甲"), "maxHits": .number(2)])
    let cursor = try XCTUnwrap(first.object["page"]?.object["nextCursor"]?.string)
    let next = try await invoke(
      AIReadingTools(reader: reader), "rg",
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
      tools, "rg", ["bookRefs": .array([ref]), "query": .string("乙"), "cursor": .string(cursor)])
    XCTAssertEqual(changed.object["error"]?.object["code"], .string("stale_cursor"))
  }
}
