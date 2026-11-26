@testable import MoonreadData
import MoonreadCoreBindings
import GRDB
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ShelfRecoveryTests: RecentReadingRestorationFixture {
  func testReferenceRecordsUseExistingWinnerAndQuarantineOnlyUnknownDescriptions() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let id = UUID().uuidString.lowercased(), unreadable = UUID().uuidString.lowercased()
    let old = ShelfReferenceValue(name: "旧提示", locationDescription: "file-provider")
    let newer = ShelfReferenceValue(name: "远方书架", locationDescription: "icloud-drive")
    for (time, value) in [(Int64(1), old), (Int64(2), newer)] {
      try f.rows.seedValue("shelf-reference/" + id, value: UserSyncJSON.encode(value),
                           device: "fixture-\(time)", updated: time)
    }
    let bad = "{\"v\":2}"
    try f.rows.quarantineValue("shelf-reference/" + id, payload: bad)
    try f.rows.quarantineValue("shelf-reference/" + unreadable, payload: bad)
    let result = try await f.service.shelfRecoverySnapshot()
    XCTAssertEqual(result.references, [ShelfReference(id: id, value: newer)])
    let retained = try f.core.session.readUsers(f.core.lease) {
      try Data.fetchAll($0, sql: "SELECT raw_bytes FROM usr.quarantined_record ORDER BY logical_key")
    }
    XCTAssertEqual(retained, [Data(bad.utf8), Data(bad.utf8)])
    XCTAssertNil(UserSyncJSON.kind("shelf-reference/not-a-uuid"))
  }

  func testAuthorizationBindingsReuseLocalFolderAndDoNotRewriteOnRead() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let root = f.root.appendingPathComponent("external")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "第一章 星光\n原创绑定样本。".write(to: root.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
    let id = try await f.service.registerLibraryShelf(root)
    let first = try await f.service.shelfRecoverySnapshot()
    let before = try referenceTokens(f)
    _ = try await f.service.shelfRecoverySnapshot()
    let unchanged = try referenceTokens(f)
    XCTAssertEqual(before, unchanged, "Reload must not republish a fresh LWW fact")
    let reference = ShelfReference(id: UUID().uuidString, value: .init(name: "曾经的书架", locationDescription: "file-provider"))
    try f.rows.seedValue("shelf-reference/" + reference.id, value: UserSyncJSON.encode(reference.value))
    let model = LibraryModel(service: f.service)
    model.chooseFiles(.reauthorize(reference, scope: first.scope))
    model.cancelFilePicker()
    let cancelled = try f.core.session.readUsers(f.core.lease) { try ShelfReferenceBindings.read($0) }
    XCTAssertNil(cancelled.bindings[reference.id])
    let reused = try await f.service.registerRecoveredShelf(root, reference: reference, scope: first.scope)
    XCTAssertEqual(reused, id)
    let shelves = try await f.service.shelves()
    XCTAssertEqual(shelves.count, 2, "Existing directory is reused, never copied or registered twice")
    try await f.service.scanLibraryShelf(id)
    let connected = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(connected.references.isEmpty)
    XCTAssertTrue(connected.guidance.contains(id))
    try await f.service.acknowledgeShelfGuidance(id, scope: connected.scope)
    let acknowledged = try await f.service.shelfRecoverySnapshot()
    XCTAssertFalse(acknowledged.guidance.contains(id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("one.txt").path))

  }

  private func referenceTokens(_ f: Fixture) throws -> [String] {
    try f.core.session.readUsers(f.core.lease) {
      try String.fetchAll($0, sql: "SELECT token FROM usr.shelf_reference_candidate ORDER BY record_id")
    }
  }

  func testAutomaticIndexingUsesOnlySuccessfulScanPathsAndNeverDownloadsCloud() async throws {
    let f = try await fixture(["kept/old.txt": Data("第一章 旧书\n保留区域。".utf8)])
    defer { f.clean() }
    try await scan(f)
    let file = f.directory.appendingPathComponent("new.txt")
    try "第一話 新书\n成功区域的原创正文。".write(to: file, atomically: true, encoding: .utf8)
    let items = try AppDataService.libraryDirectoryItems(f.directory).filter { $0.relativePath == "new.txt" }
    try await f.service.applyLibraryScan("builtin", root: f.directory,
      scan: LibraryScanSnapshot(items: items, failedPaths: ["kept"], failures: ["Synthetic partial warning"]))
    let inventory = try await f.service.identityInventory("builtin", scannedOnly: true)
    XCTAssertEqual(Set(inventory.pending.map(\.relativePath)), ["kept/old.txt", "new.txt"])
    XCTAssertEqual(inventory.admittedPending.map(\.relativePath), ["new.txt"])
    let controller = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
    controller.start("builtin", includeCloud: false, userInitiated: false, scannedOnly: true, files: inventory.local)
    await controller.waitForCompletion()
    XCTAssertEqual(try f.core.pendingIdentityFiles(shelfId: "builtin").map(\.relativePath), ["kept/old.txt"])
    var full = try AppDataService.libraryDirectoryItems(f.directory)
    let cloudText = "第一話 云端\n这是下载后才出现的原创文本。"
    full.append(.init(relativePath: "remote.txt", directory: false, size: UInt64(cloudText.utf8.count), modified: 1000, needsDownload: true))
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: full, observe: false)
    let next = try await f.service.identityInventory("builtin", scannedOnly: true)
    controller.start("builtin", includeCloud: true, userInitiated: false, scannedOnly: true, files: next.pending)
    await controller.waitForCompletion()
    XCTAssertEqual(try f.core.pendingIdentityFiles(shelfId: "builtin").map(\.relativePath), ["remote.txt"])
    XCTAssertTrue(controller.failures.isEmpty, "Absent cloud bytes must not be read even if a passive caller requests them")
    let cloudFile = f.directory.appendingPathComponent("remote.txt")
    try cloudText.write(to: cloudFile, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: cloudFile.path)
    let downloaded = try AppDataService.libraryDirectoryItems(f.directory)
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: downloaded, observe: false)
    let available = try await f.service.identityInventory("builtin", scannedOnly: true)
    controller.start("builtin", includeCloud: false, userInitiated: false, scannedOnly: true, files: available.local)
    await controller.waitForCompletion()
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty, "A cloud file not selected earlier was not prematurely marked as admitted")
    full.append(.init(relativePath: "blocked.txt", directory: false, size: 1, modified: 1, needsDownload: false))
    let failing = AppDataService(core: f.core, libraryDirectory: f.directory, sourceDefaultsSuite: f.suite,
      libraryScan: { _, _ in throw CocoaError(.fileReadNoPermission) })
    await failing.restorationFixture(active: false)
    try await failing.applyLibraryScan("builtin", root: f.directory, items: full, observe: false)
    do { try await failing.scanLibraryShelf("builtin"); XCTFail("Expected fixture scan failure") }
    catch { }
    let blocked = try await failing.identityInventory("builtin", scannedOnly: true)
    XCTAssertTrue(blocked.admittedPending.isEmpty)
  }

  func testScanChangesQueueWhileReaderBusyAndDisabledSwitchOnlyUpdatesHint() async throws {
    let f = try await fixture(["first.txt": Data("第一話 星光\n原创首篇。".utf8)])
    defer { f.clean() }
    try await scan(f)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
    let controller = FullIndexController(defaults: defaults, service: f.service, registerTasks: false)
    try controller.restoreTasks(f.core.session)
    let model = LibraryModel(service: f.service, fullIndex: controller, prepareLibrary: {}, refreshLibrary: {}, defaults: defaults, cloudDiscoveryRequired: false)
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    await model.coordinatePendingIndexes(all: true)
    XCTAssertFalse(controller.running)
    let entered = expectation(description: "Foreground owns the reading gate")
    let release = RestorationGate(entered)
    let foreground = Task { try await f.service.withForegroundOpening { await release.wait() } }
    await fulfillment(of: [entered], timeout: 3)
    controller.automatic = true
    await model.coordinatePendingIndexes(all: true)
    XCTAssertTrue(controller.running)
    try "第一話 星光\n原创首篇的新版本，字节数已变化。".write(to: f.directory.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
    try "第二話 到家\n另一篇原创正文。".write(to: f.directory.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let revisions = await f.service.indexScanRevisions
    let revision = try XCTUnwrap(revisions["builtin"])
    await model.indexScanCommitted(.init(shelfID: "builtin", revision: revision, files: ["first.txt", "second.txt"]))
    let queued = try f.core.read { db in
      try Data.fetchOne(db, sql: "SELECT item FROM main.full_index_queue ORDER BY position LIMIT 1")
    }
    let item = try XCTUnwrap(queued)
    let request = try XCTUnwrap(JSONSerialization.jsonObject(with: item) as? [String: Any])
    XCTAssertEqual(request["shelf"] as? String, "builtin")
    await release.release(); try await foreground.value
    await controller.waitForCompletion()
    XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
    controller.automatic = false
    try "第三話 新的信\n仍是原创正文。".write(to: f.directory.appendingPathComponent("third.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let lastRevisions = await f.service.indexScanRevisions
    let lastRevision = try XCTUnwrap(lastRevisions["builtin"])
    await model.indexScanCommitted(.init(shelfID: "builtin", revision: lastRevision, files: ["first.txt", "second.txt", "third.txt"]))
    XCTAssertFalse(controller.running)
    XCTAssertEqual(model.shelfIndexes["builtin"]?.pending, 1)
    XCTAssertNil(model.indexPrompt)
    XCTAssertNil(model.sheet)
    let positions = try snapshot(f)
    XCTAssertTrue(positions.isEmpty, "Indexing never invents reading activity")
  }

  func testEmptyDiscoveryDoesNotConsumeRecoveryGuidance() async throws {
    let f = try await fixture()
    defer { f.clean() }
    let before = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(before.guidance.isEmpty)
    try await scan(f)
    let empty = try await f.service.identityInventory("builtin")
    XCTAssertTrue(empty.pending.isEmpty)
    _ = try await f.service.shelfRecoverySnapshot()
    let state = try f.core.session.readUsers(f.core.lease) { try ShelfReferenceBindings.read($0) }
    XCTAssertTrue(state.guided.isEmpty)
    try "第一話 云端归来\n用于空快照后到达的原创文本。".write(to: f.directory.appendingPathComponent("arrived.txt"), atomically: true, encoding: .utf8)
    try await scan(f)
    let arrived = try await f.service.shelfRecoverySnapshot()
    XCTAssertTrue(arrived.guidance.contains("builtin"))
    try await f.service.acknowledgeShelfGuidance("builtin", scope: arrived.scope)
    try await scan(f)
    let repeated = try await f.service.shelfRecoverySnapshot()
    XCTAssertFalse(repeated.guidance.contains("builtin"))
  }
}
