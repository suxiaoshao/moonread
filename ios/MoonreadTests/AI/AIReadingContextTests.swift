import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AIReadingContextTests: BookAIFixture {
  // S090: 书籍任务只绑定当前路由身份，不借用旧详情；章节加载失败不使已知身份串书。
  func testSingleBookStatisticsReadinessUsesRouteIdentityAndIgnoresStaleDetails() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let details = try await reader.details(sha: book.contentSha256)
    let gate = CoverCallGate()
    var oldDetails = details
    oldDetails.metadata.author = "Old"
    let old = StatisticsRoute(key: nil, bookID: "old", title: "Old", fileID: "old-file")
    let current = StatisticsRoute(
      key: nil, bookID: book.id, title: "Current", fileID: "current-file")
    let model = BookInformationModel(
      readInformation: { route in
        if route.fileID == old.fileID {
          await gate.park()
          return (nil, oldDetails)
        }
        return (nil, details)
      }, readChapters: { _ in [] })
    var window = StatisticsWindow()
    XCTAssertNil(AIQuickTaskRequest.statistics(window: window, target: current, information: model))
    let overview = try XCTUnwrap(
      AIQuickTaskRequest.statistics(window: window, target: nil, information: model))
    XCTAssertNil(overview.attachments.first?.bookRef)
    var known = current
    known.key = book.contentSha256
    XCTAssertEqual(
      model.contentSHA(for: known), book.contentSha256, "A valid route SHA is ready before any load"
    )
    var invalid = known
    invalid.key = String(repeating: "g", count: 64)
    XCTAssertNil(model.contentSHA(for: invalid))
    let staleLoad = Task { await model.load(old) }
    for _ in 0..<200 {
      if await gate.started { break }
      await Task.yield()
    }
    await model.load(current)
    let request = try XCTUnwrap(
      AIQuickTaskRequest.statistics(window: window, target: current, information: model))
    XCTAssertEqual(request.attachments.first?.bookRef, AIReadingTools.bookRef(book.contentSha256))
    XCTAssertNil(model.contentSHA(for: old))
    for route in [
      StatisticsRoute(key: nil, bookID: "other", title: "Current", fileID: current.fileID),
      StatisticsRoute(key: nil, bookID: current.bookID, title: "Current", fileID: "other"),
      StatisticsRoute(
        key: nil, bookID: current.bookID, title: "Current", fileID: current.fileID, fromReader: true
      ),
    ] {
      XCTAssertNil(
        model.contentSHA(for: route),
        "Every content identity component belongs to the current route")
    }
    let capturedFrom = request.attachments.first?.fromDate
    let capturedTo = request.attachments.first?.toDate
    window.period = .all
    XCTAssertEqual(request.attachments.first?.fromDate, capturedFrom)
    XCTAssertEqual(request.attachments.first?.toDate, capturedTo)
    await gate.release()
    await staleLoad.value
    XCTAssertTrue(model.matches(current))
    XCTAssertEqual(model.details?.metadata.author, details.metadata.author)
    XCTAssertNil(model.error)
    let chapterFailure = BookInformationModel(
      readInformation: { _ in (nil, details) }, readChapters: { _ in throw ReaderError.NotFound })
    await chapterFailure.load(current)
    XCTAssertEqual(
      chapterFailure.contentSHA(for: current), book.contentSha256,
      "chapter failure must not erase a known content identity")
    XCTAssertNil(chapterFailure.contentSHA(for: old))
  }
}
