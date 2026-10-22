import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class LibraryDeletionTests: LibraryTrashFixture {
  // S428: 垃圾箱失败映射到需确认的降级意图，永久删除错误不能被当作成功；假 IO。
  func testAllTrashFailuresMapToUnsupportedAndPermanentErrorsArePreserved() async throws {
    let probe = TrashIOProbe()
    let (temporary, _, service, entries) = try await fixture(deletion: { _, _ in
      throw probe.scanFailure() ?? NSError(domain: NSCocoaErrorDomain, code: 512)
    })
    defer { try? FileManager.default.removeItem(at: temporary) }
    let cases = [
      NSError(domain: NSCocoaErrorDomain, code: 3328),
      NSError(domain: NSCocoaErrorDomain, code: 513),
      NSError(domain: "Provider", code: 3328),
      NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
    ]
    for error in cases {
      probe.setFailure(error)
      do {
        try await service.deleteLibraryItem(entries[0])
        XCTFail("Expected injected IO failure")
      } catch LibraryFileError.trashUnsupported {} catch {
        XCTFail("Every trash failure must require the batch decision: \(error)")
      }
      do {
        try await service.deleteLibraryItem(entries[0], permanently: true)
        XCTFail("Permanent failure")
      } catch let actual as NSError {
        XCTAssertEqual(actual.domain, error.domain)
        XCTAssertEqual(actual.code, error.code)
      }
    }
  }

  // S429: 永久删除只在明确批准范围内发生，跳过保留文件并继续后续项，旧决定不能重放；两个批次代表。
  func testBatchAsksOnceTriesTrashForEveryItemAndResetsAfterCompletion() async throws {
    let probe = TrashIOProbe()
    let (temporary, _, service, entries) = try await fixture(
      ["a.txt", "b.txt", "c.txt"],
      deletion: { url, permanent in
        probe.record((permanent ? "permanent:" : "trash:") + url.lastPathComponent)
        if !permanent && url.lastPathComponent == "a.txt" {
          throw NSError(domain: "Provider", code: 91)
        }
        if !permanent && url.lastPathComponent == "c.txt" { throw CocoaError(.featureUnsupported) }
        // No real deletion needed for the model's injected batch decision contract.
      })
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sorted = entries.sorted { $0.name < $1.name }
    let model = LibraryModel(service: service, fileMutationReload: {})
    var successes: [String] = []
    model.runBatch(sorted.map { .delete($0) }) { successes.append($0.filename) }
    await wait { model.pendingDecision != nil }
    XCTAssertFalse(model.processingFiles)
    let decision = try XCTUnwrap(model.pendingDecision)
    guard case .trashUnsupported = decision else {
      return XCTFail("A non-3328 failure must pause for the batch decision")
    }
    XCTAssertEqual(probe.values(), ["trash:a.txt"])
    await model.resolveDecision(decision.id, accepting: true)
    await wait { !model.runningFileBatch }
    XCTAssertEqual(
      probe.values(),
      ["trash:a.txt", "permanent:a.txt", "trash:b.txt", "trash:c.txt", "permanent:c.txt"])
    XCTAssertEqual(successes, ["a.txt", "b.txt", "c.txt"])
    // An old dismissal cannot advance the already resolved queue.
    await model.resolveDecision(decision.id, accepting: true)
    XCTAssertEqual(probe.values().count, 5)
    model.runBatch([.delete(sorted[0])])
    await wait { model.pendingDecision != nil }
    XCTAssertNotEqual(model.pendingDecision?.id, decision.id)
    await model.resolveDecision(try XCTUnwrap(model.pendingDecision).id, accepting: false)
    await wait { !model.runningFileBatch }
    XCTAssertEqual(probe.values().last, "trash:a.txt")
  }

  // S432: 文件删除已成功但 reload 失败时不得重试删除或伪报原文件仍存在。
  func testFilesystemSuccessSurvivesScan3328AndModelReloadFailureWithoutRetry() async throws {
    let probe = TrashIOProbe()
    let (temporary, _, service, entries) = try await fixture(
      deletion: { url, permanent in
        probe.record(permanent ? "permanent" : "trash")
        try FileManager.default.removeItem(at: url)  // Only this test's fresh temporary fixture.
        probe.setFailure(NSError(domain: NSCocoaErrorDomain, code: 3328))
      },
      scan: { root, _ in
        if let error = probe.scanFailure() { throw error }
        return try ReaderService.libraryDirectoryItems(root)
      })
    defer { try? FileManager.default.removeItem(at: temporary) }
    let model = LibraryModel(
      service: service,
      fileMutationReload: {
        throw NSError(
          domain: "Index", code: 7, userInfo: [NSLocalizedDescriptionKey: "reload failed"])
      })
    var successes = 0
    model.runBatch([.delete(entries[0])]) { _ in successes += 1 }
    await wait { !model.runningFileBatch }
    XCTAssertEqual(successes, 1)
    XCTAssertEqual(probe.values(), ["trash"])
    XCTAssertNil(model.pendingDecision)
    XCTAssertEqual(model.error, "reload failed")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: temporary.appendingPathComponent("library/a.txt").path)
    )
    // A service-level refresh failure stays separate from operation failure too.
    XCTAssertTrue(probe.scans() >= 2)
  }

  // S434: 删除只取消同书架被删目录的后代开书，不影响同名前缀兄弟或其他书架；边界样例保留。
  func testDeletionCancelsSameShelfDescendantButNotSiblingPrefixOrOtherShelf() async throws {
    let (temporary, _, service, entries) = try await fixture(
      ["foo/child.txt", "foobar/child.txt"], deletion: { _, _ in })
    defer { try? FileManager.default.removeItem(at: temporary) }
    let folder = try XCTUnwrap(entries.first { $0.name == "foo" })
    let childEntries = try await service.libraryEntries(folder.location)
    let child = try XCTUnwrap(childEntries.first)
    let siblingEntries = try await service.libraryEntries(
      LibraryLocation(shelfID: "builtin", path: "foobar"))
    let sibling = try XCTUnwrap(siblingEntries.first)
    let otherRoot = temporary.appendingPathComponent("other")
    try FileManager.default.createDirectory(
      at: otherRoot.appendingPathComponent("foo"), withIntermediateDirectories: true)
    try Data("other shelf".utf8).write(to: otherRoot.appendingPathComponent("foo/child.txt"))
    let otherID = try await service.registerLibraryShelf(otherRoot)
    try await service.scanLibraryShelf(otherID)
    let otherEntries = try await service.libraryEntries(
      LibraryLocation(shelfID: otherID, path: "foo"))
    let other = try XCTUnwrap(otherEntries.first)
    XCTAssertEqual(other.relativePath, child.relativePath)
    for source in [child, sibling, other] {
      let entered = expectation(description: "open preparation entered")
      let gate = SourceReadinessGate(entered: entered)
      let model = LibraryModel(
        service: service, fileMutationReload: {}, prepareSource: { _, _ in await gate.wait() })
      model.open(source)
      await fulfillment(of: [entered], timeout: 2)
      XCTAssertTrue(model.runBatch([.delete(folder)]))
      await model.waitForFileWork()
      XCTAssertNil(model.error)
      XCTAssertEqual(model.openingFileID, source.id == child.id ? nil : source.id)
      model.cancelOpening()
      await gate.release()
    }
  }

  // S437: 删除前/删除中开始的旧扫描不能重新发布已删除文件，显式 IO gate。
  func testScansBeforeAndDuringSuspendedDeletionCannotPublishStaleItems() async throws {
    let scan = TrashScanProbe()
    let deleting = expectation(description: "deletion IO suspended")
    let deletePermit = DispatchSemaphore(value: 0)
    let (temporary, core, service, entries) = try await fixture(
      deletion: { url, _ in
        deleting.fulfill()
        guard deletePermit.wait(timeout: .now() + 5) == .success else {
          throw CocoaError(.userCancelled)
        }
        try FileManager.default.removeItem(at: url)
      }, scan: { root, _ in try scan.scan(root) })
    let beforePermit = DispatchSemaphore(value: 0)
    let duringPermit = DispatchSemaphore(value: 0)
    defer {
      deletePermit.signal()
      beforePermit.signal()
      duringPermit.signal()
      try? FileManager.default.removeItem(at: temporary)
    }
    let stale: [ScannedLibraryItem] = [
      .init(relativePath: "a.txt", directory: false, size: 10, modified: 0, needsDownload: false),
      .init(
        relativePath: "ghost.txt", directory: false, size: 10, modified: 0, needsDownload: false),
    ]
    let beforeEntered = expectation(description: "pre-delete scan captured old items")
    scan.enqueue(.init(entered: beforeEntered, permit: beforePermit, items: stale))
    let before = Task { try await service.scanLibraryShelf("builtin") }
    await fulfillment(of: [beforeEntered], timeout: 2)
    let deletion = Task { try await service.deleteLibraryItem(entries[0]) }
    await fulfillment(of: [deleting], timeout: 2)
    beforePermit.signal()
    try await before.value
    XCTAssertEqual(
      try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["a.txt"],
      "Deletion invalidates pre-delete scans before suspending IO")
    let duringEntered = expectation(description: "scan captured items while deletion waited")
    scan.enqueue(.init(entered: duringEntered, permit: duringPermit, items: stale))
    let during = Task { try await service.scanLibraryShelf("builtin") }
    await fulfillment(of: [duringEntered], timeout: 2)
    deletePermit.signal()
    let result = try await deletion.value
    XCTAssertNil(result.refreshError)
    duringPermit.signal()
    try await during.value
    XCTAssertTrue(
      try core.sourceFiles(shelfId: "builtin").isEmpty,
      "The post-success scan invalidates scans begun during deletion")
  }
}
