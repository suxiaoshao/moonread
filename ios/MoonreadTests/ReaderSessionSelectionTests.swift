import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderSessionReaderSelectionTests: ReaderSelectionFixture {
  // S308: 忙碌窗口请求不能被当作已消费而丢失，解除忙碌仍处理当前 viewport 请求。
  func testBusyWindowAdmissionDoesNotConsumeViewportRequest() {
    var admissions = ReadingFrontierAdmissions()
    var accepted = false
    var attempts = 0
    let keep = SourceSpan(startUtf8: 3, endUtf8: 30)
    func request() {
      admissions.request(.forward, cursor: 40, keeping: keep) {
        attempts += 1
        return accepted
      }
    }
    request()
    XCTAssertEqual(attempts, 1)
    accepted = true
    request()
    request()
    XCTAssertEqual(attempts, 2)
    admissions.reset()
    request()
    XCTAssertEqual(attempts, 3)
  }

  // S310: Rust 返回 End/严格扩展/无新锚点时保留已有可读窗口，不以空结果抹掉当前正文。
  func testStrictExtensionEndAndUnanchoredReadyKeepReadableWindow() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("边界合成.txt")
    try Data(("甲段。\n" + String(repeating: "合成正文。\n", count: 12000)).utf8).write(to: file)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let imported = try core.importBook(filePath: file.path, title: "合成")
    let service = AppDataService(core: core)
    let session = ReaderSession(
      service: service,
      activity: ReadingActivityRecorder { StatisticsPreferences(enabled: false, generation: 0) })
    await session.open(.book(imported.id))
    await awaitState { session.window != nil }
    let previous = try XCTUnwrap(session.window)
    let anchor = session.anchor
    let held = SourceSpan(
      startUtf8: previous.projectionAnchor ?? anchor,
      endUtf8: (previous.projectionAnchor ?? anchor) + 1)
    let deferred = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward, retaining: held)
    XCTAssertEqual(deferred.status, .deferred)
    session.acceptExtension(deferred, direction: .backward)
    XCTAssertEqual(session.window, previous)
    let ready = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward)
    XCTAssertEqual(ready.status, .ready)
    session.acceptExtension(ready, direction: .forward)
    XCTAssertEqual(
      session.window, previous,
      "Prefetch cannot silently relocate an anchor outside its finite payload")
    let end = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount, direction: .forward)
    XCTAssertEqual(end.status, .end)
    session.acceptExtension(end, direction: .forward)
    XCTAssertEqual(session.window?.chunks, previous.chunks)
    XCTAssertEqual(session.window?.paragraphs, previous.paragraphs)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertNil(session.window?.nextCursor)
    var waiting = end
    waiting.status = .awaiting
    waiting.snapshot.phase = .importing
    waiting.isEndOfBook = false
    session.acceptExtension(waiting, direction: .forward)
    XCTAssertEqual(session.window?.chunks, previous.chunks)
    XCTAssertEqual(session.window?.paragraphs, previous.paragraphs)
    XCTAssertEqual(session.anchor, anchor)
    XCTAssertTrue(session.window?.isPreparedTail == true)
    XCTAssertFalse(session.window?.isEndOfBook == true)
    // The same distant frontier becomes admissible after an actual reading
    // move; prefetch itself must not perform that move to escape Deferred.
    let distant = imported.byteCount - UInt64("合成正文。\n".utf8.count)
    session.moved(to: distant, settled: false)
    let moved = try await service.extensionFrame(
      imported.id, cursor: imported.byteCount - 1, direction: .backward,
      retaining: SourceSpan(startUtf8: distant, endUtf8: distant + 1))
    XCTAssertEqual(moved.status, .ready)
    session.acceptExtension(moved, direction: .backward)
    XCTAssertTrue(
      session.window?.chunks.contains { $0.startUtf8 <= distant && $0.endUtf8 > distant } == true)
    XCTAssertEqual(session.anchor, distant)
    await session.leave().value
  }
}
