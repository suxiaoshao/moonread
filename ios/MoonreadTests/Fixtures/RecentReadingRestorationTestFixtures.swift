import GRDB
import CryptoKit
import SwiftData
import XCTest

@testable import Moonread

actor RestorationGate {
  let entered: XCTestExpectation?
  var continuation: CheckedContinuation<Void, Never>?
  var released = false
  private var arrived = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  init(_ entered: XCTestExpectation? = nil) { self.entered = entered }
  func waitForEntry() async {
    if arrived { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func wait() async {
    if !released {
      await withCheckedContinuation {
        continuation = $0
        arrived = true
        entered?.fulfill()
        let waiters = entryWaiters; entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}
actor RestorationReads {
  var ids: [String] = []
  func record(_ id: String) { ids.append(id) }
}
extension AppDataService {
  func restorationFixture(
    active: Bool, beforeRead: (@Sendable (String) async -> Void)? = nil,
    beforeCommit: (@Sendable () async -> Void)? = nil
  ) {
    recentRestorationActive = active
    recentRestorationBeforeRead = beforeRead
    recentRestorationBeforeCommit = beforeCommit
  }
  func restorationFixtureWasCancelled() -> Bool { recentRestorationWork?.isCancelled == true }
  func stopRestorationFixtureFollowUp() { recentRestorationRequested = false }
}

@MainActor class RecentReadingRestorationFixture: XCTestCase {
  struct Fixture {
    let root: URL, directory: URL
    let core: ReaderIndex, service: AppDataService
    let rows: UserRowsFixture
    let suite: String
    func clean() {
      UserDefaults.standard.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }
  func fixture(_ files: [String: Data] = [:]) async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (path, data) in files {
      let url = directory.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
    let core = try makeReaderIndexFixture(at: root.appendingPathComponent("cache"))
    let rows = UserRowsFixture(index: core)
    let suite = "RecentRestore-" + UUID().uuidString
    let service = AppDataService(
      core: core, libraryDirectory: directory, sourceDefaultsSuite: suite)
    await service.restorationFixture(active: false)
    try core.saveLibraryShelf(
      id: "builtin", name: "Synthetic library",
      bookmark: directory.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      location: "local", builtin: true)
    return Fixture(
      root: root, directory: directory, core: core, service: service, rows: rows, suite: suite)
  }
  func scan(_ f: Fixture) async throws {
    let files = try AppDataService.libraryDirectoryItems(f.directory)
    try await f.service.applyLibraryScan("builtin", root: f.directory, items: files, observe: false)
  }
  func hint(_ path: String, size: UInt64?, decoding: String = "auto") -> PositionSourceHint {
    .init(
      source_kind: .managedLocal, relative_path: path,
      file_name: (path as NSString).lastPathComponent, byte_size: size, decoding: decoding)
  }
  func position(
    _ f: Fixture, key: String, hint: PositionSourceHint?, time: Int64 = 123456, offset: UInt64 = 12,
    token: String = "original"
  ) async throws {
    try f.rows.seedPosition(key, offset: offset, hint: hint, time: time, token: token)
  }
  func snapshot(_ f: Fixture) throws -> [String] {
    try f.core.session.readUsers(f.core.lease) { db in
      try String.fetchAll(db, sql: """
        SELECT book_key||'/'||token||'/'||offset FROM usr.position_candidate ORDER BY partition,book_key,record_id
        """)
    }
  }
  func restore(_ f: Fixture, retry: Bool = false) async {
    await f.service.restorationFixture(active: true)
    await f.service.scheduleRecentRestoration(retry: retry)
    await f.service.waitForRecentRestoration()
  }
  func sha(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

}
