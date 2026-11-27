import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class UserPersistenceReaderIntegrationTests: ReaderIntegrationFixture {
  // S393: 初始化失败可重试且并发调用共享同一结果，正规/pending 存储各一个最小输入。
  @MainActor func testLibraryInitializationRetriesAndConcurrentCallersWait() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = AppDataService(
      core: try makeReaderIndexFixture(at: directory.appendingPathComponent("db")),
      libraryDirectory: directory.appendingPathComponent("books"))
    let entered = expectation(description: "Retry is preparing")
    let gate = SourceReadinessGate(entered: entered)
    let probe = LibraryInitializationProbe(gate: gate)
    let model = LibraryModel(service: service, prepareLibrary: { try await probe.prepare(service) })
    let failed = await model.load()
    XCTAssertFalse(failed)
    XCTAssertNotNil(model.error)
    let first = Task { await model.load() }
    await fulfillment(of: [entered], timeout: 2)
    var secondFinished = false
    let second = Task {
      let ready = await model.load()
      secondFinished = true
      return ready
    }
    for _ in 0..<10 { await Task.yield() }
    XCTAssertFalse(
      secondFinished, "Open URL must await initialization, not proceed into an unregistered shelf")
    first.cancel()
    await gate.release()
    let firstResult = await first.value
    let secondResult = await second.value
    XCTAssertTrue(firstResult)
    XCTAssertTrue(secondResult, "Cancelling a view must not cancel shared model initialization")
    XCTAssertNil(model.error)
    XCTAssertTrue(model.shelves.contains { $0.builtin })
    let readyAgain = await model.load()
    let attempts = await probe.attempts
    XCTAssertTrue(readyAgain)
    XCTAssertEqual(attempts, 2)

  }
}

final class UserPersistenceUserDataTests: UserDataFixture {
  @MainActor func testCommittedCoverAndAnnotationSurviveDatabaseReopen() async throws {
    let (root, service, book, rows) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 12)).pngData {
      UIColor.blue.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 8, height: 12))
    }
    let draft = try await service.makeCover(image)
    let base = try await service.details(bookID: book.id).metadata
    var changed = base; changed.cover = draft
    try await service.saveMetadata(base: base, edited: changed)
    let committed = try await service.details(bookID: book.id).metadata
    let cover = try XCTUnwrap(committed.cover)
    let edit = try await service.prepareAnnotation(book.id, start: 0, end: 8)
    _ = try await service.saveNote(edit, text: "Saved note")
    let bytes = try await service.coverBytes(cover)
    try rows.index.session.close()

    let reopened = try makeReaderIndexFixture(at: root.appending(path: "db"))
    defer { try? reopened.session.close() }
    let reopenedRows = UserRowsFixture(index: reopened)
    let heads = try reopenedRows.annotationHeads(book.fixtureSHA256)
    XCTAssertEqual(heads.values.flatMap { $0 }.compactMap { $0.content?.note }, ["Saved note"])
    XCTAssertEqual(try reopenedRows.coverBytes(id: cover.id, sha: cover.sha256), bytes)
    XCTAssertNil(try reopenedRows.coverBytes(id: cover.id, sha: String(repeating: "0", count: 64)))
  }
}
