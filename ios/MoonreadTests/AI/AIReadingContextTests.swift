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
    let old = StatisticsRoute(target: .file(fileId: "old-file"), title: "Old")
    let current = StatisticsRoute(target: .file(fileId: "current-file"), title: "Current")
    let identity = ResolvedBookRecord(key: .formal(sha256: book.contentSha256), body: .associated(bookId: book.id), aliases: [])
    let model = BookInformationModel(
      readInformation: { route in
        if route.fileID == old.fileID {
          await gate.park()
          return (nil, .identified(identity: identity, details: oldDetails))
        }
        return (nil, .identified(identity: identity, details: details))
      }, readChapters: { _ in [] })
    var window = StatisticsWindow()
    XCTAssertNil(AIQuickTaskRequest.statistics(window: window, target: current, information: model))
    let overview = try XCTUnwrap(
      AIQuickTaskRequest.statistics(window: window, target: nil, information: model))
    XCTAssertNil(overview.attachments.first?.bookRef)
    let known = StatisticsRoute(target: .record(key: .formal(sha256: book.contentSha256)), title: current.title)
    XCTAssertEqual(model.contentSHA(for: known), book.contentSha256, "A formal target is ready before any load")
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
      StatisticsRoute(target: .file(fileId: "other"), title: current.title),
      StatisticsRoute(target: .cached(bookId: book.id), title: current.title),
      StatisticsRoute(target: current.target, title: current.title, origin: .reader(fileID: current.fileID)),
    ] {
      XCTAssertNil(
        model.contentSHA(for: route),
        "Every content identity component belongs to the current route")
    }
    let capturedFrom = request.attachments.first?.fromDate
    let capturedTo = request.attachments.first?.toDate
    window = .all
    XCTAssertEqual(request.attachments.first?.fromDate, capturedFrom)
    XCTAssertEqual(request.attachments.first?.toDate, capturedTo)
    await gate.release()
    await staleLoad.value
    XCTAssertTrue(model.matches(current))
    XCTAssertEqual(model.details?.metadata.author, details.metadata.author)
    XCTAssertNil(model.error)
    let chapterFailure = BookInformationModel(
      readInformation: { _ in (nil, .identified(identity: identity, details: details)) }, readChapters: { _ in throw ReaderError.NotFound })
    await chapterFailure.load(current)
    XCTAssertEqual(
      chapterFailure.contentSHA(for: current), book.contentSha256,
      "chapter failure must not erase a known content identity")
    XCTAssertNil(chapterFailure.contentSHA(for: old))
  }
}
