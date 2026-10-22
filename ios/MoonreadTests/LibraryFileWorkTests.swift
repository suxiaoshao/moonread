import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Moonread

final class LibraryFileWorkLibraryDropTests: LibraryDropFixture {
  // S257: 文件任务准入独占 owner，其他系统 URL 排队且不提前写入；外部 provider 与内部 payload 共用一条队列契约。
  func testAdmissionOwnsProviderPreparationAndSerializesSystemURLBatches() async throws {
    let f = try await fixture()
    defer { f.remove() }
    for name in ["drop", "first", "second"] {
      try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: name)
    }
    let model = f.model()
    try await model.reload()
    let gate = DropProviderGate(expectation(description: "provider requested"))
    let provider = gate.provider(name: "admitted.txt")
    XCTAssertTrue(
      model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin", path: "drop")))
    XCTAssertTrue(model.explicitFileWork)
    XCTAssertFalse(model.canAcceptFileWork)
    XCTAssertFalse(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin")))
    XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "blocked")]))
    XCTAssertFalse(model.receive([try f.write("rejected.txt")]))
    XCTAssertNotNil(model.error)
    model.error = nil
    await fulfillment(of: [gate.requested], timeout: 3)
    provider.suggestedName = "changed-after-admission.txt"
    model.path = [.folder(.init(shelfID: "builtin", path: "second"))]
    model.receiveSystemURLs(
      [try f.write("one.txt"), try f.write("two.txt")], at: .init(shelfID: "builtin", path: "first")
    )
    model.receiveSystemURLs(
      [try f.write("three.txt"), try f.write("four.txt")],
      at: .init(shelfID: "builtin", path: "second"))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("first/one.txt").path))
    gate.complete(try f.write("mangled.txt"))
    await model.waitForFileWork()
    XCTAssertTrue(model.canAcceptFileWork)
    XCTAssertNil(model.error)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: f.books.appendingPathComponent("drop/admitted.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: f.books.appendingPathComponent("drop/changed-after-admission.txt").path))
    for path in ["first/one.txt", "first/two.txt", "second/three.txt", "second/four.txt"] {
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: f.books.appendingPathComponent(path).path))
    }
    XCTAssertEqual(
      model.path,
      [
        .folder(.init(shelfID: "builtin", path: "second")),
        .folder(.init(shelfID: "builtin", path: "first")),
        .folder(.init(shelfID: "builtin", path: "second")),
      ])
    // Internal provider preparation has the same ownership and queued-URL contract.
    do {

      let f = try await fixture()
      defer { f.remove() }
      try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "child")
      try Data("Source".utf8).write(to: f.books.appendingPathComponent("child/source.txt"))
      try await f.service.scanLibraryShelf("builtin")
      let entries = try await f.service.libraryEntries(.init(shelfID: "builtin", path: "child"))
      let source = try XCTUnwrap(entries.first)
      let model = f.model()
      try await model.reload()
      let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
      let gate = DropPayloadGate(expectation(description: "private payload loading"))
      let provider = gate.provider()
      XCTAssertEqual(delegate.operation([provider]), .move)
      XCTAssertTrue(delegate.accept([provider]))
      XCTAssertTrue(model.busy)
      XCTAssertTrue(model.runningFileBatch)
      XCTAssertEqual(delegate.operation([provider]), .forbidden)
      XCTAssertFalse(delegate.accept([provider]))
      XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "other")]))
      await fulfillment(of: [gate.requested], timeout: 3)
      let queued = try f.write("queued.txt")
      model.receiveSystemURLs([queued])
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: f.books.appendingPathComponent("queued.txt").path))
      model.error = nil
      gate.complete(try JSONEncoder().encode(LibraryDragPayload(fileID: source.id)))
      await model.waitForFileWork()
      XCTAssertNil(model.error)
      XCTAssertTrue(model.canAcceptFileWork)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: f.books.appendingPathComponent("source.txt").path))
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: f.books.appendingPathComponent("queued.txt").path))

    }
  }

  // S261: 冲突决策暂停当前文件任务，关闭后只续行一次，跳过不停止后续任务；不操作系统弹窗。
  func testReplacementPauseKeepsOwnerAndResumesExactlyOnce() async throws {
    let f = try await fixture()
    defer { f.remove() }
    try Data("Existing".utf8).write(to: f.books.appendingPathComponent("book.txt"))
    let source = try f.write("book.txt")
    let model = f.model()
    try await model.reload()
    let baseline = stagingDirectories()
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([fileProvider(source, name: "book.txt")]), at: .init(shelfID: "builtin")))
    await model.waitForFileWork()
    let id = try XCTUnwrap(model.pendingDecision).id
    XCTAssertFalse(model.canAcceptFileWork)
    XCTAssertFalse(model.processingFiles)
    XCTAssertFalse(model.runBatch([.create(.init(shelfID: "builtin"), "blocked")]))
    XCTAssertFalse(stagingDirectories().subtracting(baseline).isEmpty)
    model.error = nil
    await model.resolveDecision(id, accepting: true)
    await model.resolveDecision(id, accepting: true)
    XCTAssertTrue(model.canAcceptFileWork)
    XCTAssertNil(model.error)
    XCTAssertEqual(
      try Data(contentsOf: f.books.appendingPathComponent("book.txt")), try Data(contentsOf: source)
    )
    XCTAssertEqual(stagingDirectories(), baseline)
    XCTAssertTrue(model.path.isEmpty)
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([fileProvider(source, name: "book.txt")]), at: .init(shelfID: "builtin")))
    await model.waitForFileWork()
    let skipped = try XCTUnwrap(model.pendingDecision).id
    XCTAssertFalse(model.canAcceptFileWork)
    await model.resolveDecision(skipped, accepting: false)
    XCTAssertTrue(model.canAcceptFileWork)
    XCTAssertEqual(stagingDirectories(), baseline)
    XCTAssertTrue(model.path.isEmpty)
    do {

      let host = LibraryDecisionAlert.Controller()
      var dismissed: (() -> Void)?
      var calls = 0
      host.dismissPresentation = { dismissed = $0 }
      host.finish(alert: nil) { calls += 1 }
      host.finish(alert: nil) { XCTFail("Duplicate continuation") }
      XCTAssertEqual(calls, 0)
      dismissed?()
      XCTAssertEqual(calls, 1)

    }
  }

  // S263: 导入失败原件暂存保留到重试/放弃，重试一项不清其他失败。
  func testFailedImportResourceOutlivesOwnerForRetryAndDismissal() async throws {
    let f = try await fixture()
    defer { f.remove() }
    let model = f.model()
    try await model.reload()
    let a = try f.write("a.txt")
    let b = try f.write("b.txt")
    let baseline = stagingDirectories()
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([fileProvider(a, name: "a.txt"), fileProvider(b, name: "b.txt")]),
        at: .init(shelfID: "builtin", path: "missing")))
    await model.waitForFileWork()
    XCTAssertEqual(model.importFailures.count, 2)
    let failure = try XCTUnwrap(model.importFailures.first)
    let other = try XCTUnwrap(model.importFailures.last)
    XCTAssertTrue(FileManager.default.fileExists(atPath: failure.url.path))
    model.runAfterSheetDismiss { XCTAssertTrue(model.retryImport(failure)) }
    model.sheetDidDismiss()
    await model.waitForFileWork()
    XCTAssertEqual(
      Set(model.importFailures.map(\.url)), [failure.url, other.url],
      "a failed retry must retain both resources")
    try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "missing")
    let retry = try XCTUnwrap(model.importFailures.first { $0.url == failure.url })
    model.runAfterSheetDismiss { XCTAssertTrue(model.retryImport(retry)) }
    model.sheetDidDismiss()
    await model.waitForFileWork()
    XCTAssertEqual(
      model.importFailures.map(\.url), [other.url],
      "successful retry cannot discard another failure")
    XCTAssertFalse(FileManager.default.fileExists(atPath: failure.url.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.url.path))
    model.sheet = nil
    model.sheetDidDismiss()
    XCTAssertTrue(model.importFailures.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: other.url.path))
    XCTAssertEqual(stagingDirectories(), baseline)
    model.sheetDidDismiss()
    XCTAssertTrue(model.importFailures.isEmpty)
  }
}

final class LibraryFileWorkReaderIntegrationTests: ReaderIntegrationFixture {
  // S365: 文件协调挂起期间仍能完成不相关的 reader 用户操作；显式 gate 验证可完成事件，删 actor/worker 名与耗时断言。
  @MainActor func testCloudPublicationIOWaitDoesNotOccupyReaderActor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let local = root.appendingPathComponent("local")
    let cloud = root.appendingPathComponent("cloud")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    try Data("handoff actor probe".utf8).write(to: local.appendingPathComponent("book.txt"))
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = ReaderService(core: core, libraryDirectory: local)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    var initial: [String: CloudHandoffReceipt] = [:]
    try CloudDocumentHandoff.transfer(
      local: local, cloud: cloud, receipts: &initial, removeOriginals: false,
      persist: { _ in }, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
    let copied = initial
    let permit = DispatchSemaphore(value: 0)
    let waiting = expectation(description: "I/O is waiting while coordination remains held")
    let publication = Task {
      var receipts = copied
      try await service.publishCloudHandoff(
        local: local, cloud: cloud, receipts: &receipts,
        persist: { _ in
          waiting.fulfill()
          permit.wait()
        })
    }
    await fulfillment(of: [waiting], timeout: 5)
    let readerEntered = expectation(description: "An unrelated reader job enters the same actor")
    Task {
      _ = await service.readingChangeRevision("probe")
      readerEntered.fulfill()
    }
    await fulfillment(of: [readerEntered], timeout: 1)
    permit.signal()
    try await publication.value
    XCTAssertEqual(try core.libraryShelves().first?.location, "icloud")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: local.appendingPathComponent("book.txt").path),
      "Publication alone never removes originals")
    do {

      let permit = DispatchSemaphore(value: 0)
      let probe = TrashIOProbe()
      let deleting = expectation(description: "delete queue suspended")
      let (temporary, core, service, entries) = try await makeLibraryFileFixture(deletion: { _, _ in
        probe.record("worker")
        deleting.fulfill()
        guard permit.wait(timeout: .now() + 5) == .success else { throw CocoaError(.userCancelled) }
      })
      defer {
        permit.signal()
        try? FileManager.default.removeItem(at: temporary)
      }
      let local = temporary.appendingPathComponent("library")
      let cloud = temporary.appendingPathComponent("cloud")
      var receipts: [String: CloudHandoffReceipt] = [:]
      try CloudDocumentHandoff.transfer(
        local: local, cloud: cloud, receipts: &receipts, removeOriginals: false,
        persist: { _ in }, makeUbiquitous: { try FileManager.default.moveItem(at: $0, to: $1) })
      let delete = Task { try await service.deleteLibraryItem(entries[0]) }
      await fulfillment(of: [deleting], timeout: 2)
      let committed = expectation(
        description: "coordinated cloud worker commits through actor while deletion waits")
      let copied = receipts
      let publication = Task {
        var pending = copied
        try await service.publishCloudHandoff(
          local: local, cloud: cloud, receipts: &pending, persist: { _ in committed.fulfill() })
      }
      await fulfillment(of: [committed], timeout: 2)
      XCTAssertEqual(try core.libraryShelves().first?.location, "icloud")
      _ = await service.readingChangeRevision("independent-reader-job")
      permit.signal()
      try await publication.value
      let outcome = try await delete.value
      XCTAssertNil(outcome.refreshError)

    }
  }

  // S390: 旧结果面板关闭不能清新批次失败；当前明确放弃才释放所属失败资源。
  @MainActor func testOlderSheetDismissalDoesNotClearNewImportResults() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
      libraryDirectory: directory.appendingPathComponent("books"))
    try await service.prepareLibrary()
    let model = LibraryModel(service: service)
    let missing = directory.appendingPathComponent("missing.txt")
    model.runAfterSheetDismiss { model.receive([missing]) }
    model.sheetDidDismiss()
    await model.waitForFileWork()
    XCTAssertEqual(model.sheet?.id, "import-results")
    model.sheetDidDismiss()
    XCTAssertEqual(
      model.importFailures.map(\.url), [missing],
      "A late callback must not clear the new results sheet")
    model.sheet = nil
    model.sheetDidDismiss()
    XCTAssertTrue(model.importFailures.isEmpty)
  }

  // S394: 导出暂存只清本次拥有的文件，部分失败不删外部原件。
  func testExportStagingFollowsOwnershipAndCleansPartialFailure() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = directory.appendingPathComponent("books")
    let service = ReaderService(
      core: try ReaderCore(dataDirectory: directory.appendingPathComponent("db").path),
      libraryDirectory: root)
    try await service.prepareLibrary()
    try await service.refreshLibrary()
    let entry = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))[0]
    let original = root.appendingPathComponent(entry.name)
    let originalBytes = try Data(contentsOf: original)
    var presentation: LibraryExport? = try await service.exportLibraryFiles([entry])
    let stagedDirectory = try XCTUnwrap(presentation?.directory)
    let stagedURL = try XCTUnwrap(presentation?.urls.first)
    XCTAssertEqual(try Data(contentsOf: stagedURL), originalBytes)
    var activity = presentation
    presentation = nil
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: stagedURL.path),
      "A still-running system activity owns its input")
    withExtendedLifetime(activity) {}
    activity = nil
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
    XCTAssertEqual(try Data(contentsOf: original), originalBytes)

    var failedDirectory: URL?
    XCTAssertThrowsError(
      try LibraryExport { staging in
        failedDirectory = staging
        try originalBytes.write(to: staging.appendingPathComponent("copied.txt"))
        throw CocoaError(.fileWriteOutOfSpace)
      })
    XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(failedDirectory).path))
  }

  // S408: 同名导入在明确同意替换前保留目标原字节；拒绝不会删原书。
  func testLibraryImportConflictPreservesOriginalUntilReplacement() async throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
    let root = temporary.appendingPathComponent("books")
    let service = ReaderService(core: core, libraryDirectory: root)
    try await service.prepareLibrary()
    let source = temporary.appendingPathComponent("同名.txt")
    try "旧原文".write(to: source, atomically: true, encoding: .utf8)
    _ = try await service.receiveLibraryFile(
      source, at: LibraryLocation(shelfID: "builtin"), replace: false)
    try "新原文".write(to: source, atomically: true, encoding: .utf8)
    do {
      _ = try await service.receiveLibraryFile(
        source, at: LibraryLocation(shelfID: "builtin"), replace: false)
      XCTFail("Same-name import requires a choice")
    } catch LibraryFileError.conflict {}
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("同名.txt"), encoding: .utf8), "旧原文")
    _ = try await service.receiveLibraryFile(
      source, at: LibraryLocation(shelfID: "builtin"), replace: true)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("同名.txt"), encoding: .utf8), "新原文")
    XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "新原文")
  }
}
