import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

@MainActor class ReaderSelectionFixture: XCTestCase {
  #if READER_OPEN_DIAGNOSTICS
  #endif

  func window(_ text: String) throws -> ReadingWindow {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("合成空行.txt")
    try Data(text.utf8).write(to: file)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "合成空行")
    let frame = try core.querySnapshot(json: "{}").readingFrame(bookId: book.id, offsetUtf8: 0)
    return ReadingWindow(frame: frame)
  }

}

actor SourceReadinessGate {
  let entered: XCTestExpectation
  var continuation: CheckedContinuation<Void, Never>?
  init(entered: XCTestExpectation) { self.entered = entered }
  func wait() async {
    await withCheckedContinuation {
      continuation = $0
      entered.fulfill()
    }
  }
  func release() {
    continuation?.resume()
    continuation = nil
  }
}

actor EncodingRestartProbe {
  let gate: SourceReadinessGate
  let holdAfterCreation: Bool
  private(set) var calls = 0
  private(set) var createdIDs: [String] = []
  init(gate: SourceReadinessGate, holdAfterCreation: Bool = false) {
    self.gate = gate
    self.holdAfterCreation = holdAfterCreation
  }
  func run(service: ReaderService, id: String, encoding: String?) async throws -> ReadingLease {
    calls += 1
    if !holdAfterCreation { await gate.wait() }
    let lease = try await service.restartImport(id, encoding: encoding)
    createdIDs.append(lease.id)
    if holdAfterCreation { await gate.wait() }
    return lease
  }
}

actor LibraryRefreshProbe {
  private(set) var passes = 0
  let gate: SourceReadinessGate
  init(gate: SourceReadinessGate) { self.gate = gate }
  func refresh() async {
    passes += 1
    if passes == 1 { await gate.wait() }
  }
}

actor LibraryInitializationProbe {
  private(set) var attempts = 0
  let gate: SourceReadinessGate
  init(gate: SourceReadinessGate) { self.gate = gate }
  func prepare(_ service: ReaderService) async throws {
    attempts += 1
    if attempts == 1 { throw CocoaError(.fileWriteOutOfSpace) }
    await gate.wait()
    try await service.prepareLibrary()
  }
}

class ReaderIntegrationFixture: XCTestCase {

  @MainActor func singleBookFixture() throws -> (
    URL, ReaderService, ReaderCore, UserDataStore, UserDataStore, ImportText, ImportText, String
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let schema = UserDataStore.schema
    let formal = UserDataStore(
      modelContainer: try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
    let pending = UserDataStore(
      modelContainer: try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
    let suite = "SingleBook.\(UUID().uuidString)"
    let service = ReaderService(
      core: core, libraryDirectory: root, sourceDefaultsSuite: suite,
      userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
    let a = root.appendingPathComponent("a.txt")
    let b = root.appendingPathComponent("b.txt")
    try "第一章 合成甲\n春风吹过合成的书页。\n第二章 合成\n继续正文。\n".write(to: a, atomically: true, encoding: .utf8)
    try "第一章 合成乙\n仅用于回归的第二本书。\n".write(to: b, atomically: true, encoding: .utf8)
    let first = try core.importBook(filePath: a.path, title: "甲")
    let second = try core.importBook(filePath: b.path, title: "乙")
    try core.saveLibraryShelf(
      id: "builtin", name: "我的书架",
      bookmark: a.deletingLastPathComponent().bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      location: "local", builtin: true)
    try core.scanLibraryShelf(
      shelfId: "builtin",
      items: [
        .init(
          relativePath: "a.txt", directory: false, size: first.byteCount, modified: 0,
          needsDownload: false),
        .init(
          relativePath: "b.txt", directory: false, size: second.byteCount, modified: 0,
          needsDownload: false),
      ])
    for file in try core.sourceFiles(shelfId: "builtin") {
      try core.linkLibraryFile(
        fileId: file.id, bookId: file.relativePath == "a.txt" ? first.id : second.id)
    }
    return (root, service, core, formal, pending, first, second, suite)
  }

  @MainActor func introductionFixture(
    scan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil
  ) throws -> (URL, ReaderService, ReaderCore, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = root.appendingPathComponent("library")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let schema = UserDataStore.schema
    let store = UserDataStore(
      modelContainer: try ModelContainer(
        for: schema,
        configurations: [
          ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ]))
    let suite = "Introduction-" + UUID().uuidString
    let service = ReaderService(
      core: core, libraryDirectory: directory, sourceDefaultsSuite: suite,
      userStoreFactory: { _, _ in store }, libraryScan: scan)
    try core.saveLibraryShelf(
      id: "builtin", name: "我的书架",
      bookmark: directory.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
      location: "local", builtin: true)
    return (root, service, core, suite)
  }

  func importJobIDs(_ root: URL) throws -> [String] {
    var db: OpaquePointer?
    XCTAssertEqual(
      sqlite3_open_v2(
        root.appendingPathComponent("db/reader.sqlite3").path, &db, SQLITE_OPEN_READONLY, nil),
      SQLITE_OK)
    defer { sqlite3_close(db) }
    var query: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "SELECT book_id FROM import_jobs ORDER BY book_id", -1, &query, nil),
      SQLITE_OK)
    defer { sqlite3_finalize(query) }
    let statement = try XCTUnwrap(query)
    var result: [String] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      result.append(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))))
      status = sqlite3_step(statement)
    }
    XCTAssertEqual(status, SQLITE_DONE)
    return result
  }

  /// The reader chooses a list before showing it: the first frame has the target title and
  /// never rows of the other mark kind; a new book no longer falls back to chapters.

  /// 学习…, the speech group and 共享… share one section using the supplied objects; other shapes stay as supplied.

  static func pausedSourceFixture() async throws -> (
    URL, ReaderService, ReaderCore, SourceFile, String, UserDefaults, String
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let local = root.appendingPathComponent("local")
    try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
    let source = local.appendingPathComponent("book.txt")
    try "第一章 月光\n这是暂停语义的原创合成正文。\n".write(to: source, atomically: true, encoding: .utf8)
    let suite = "PauseIntent-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let service = ReaderService(core: core, libraryDirectory: local, sourceDefaultsSuite: suite)
    try await service.prepareLibrary()
    try await service.scanLibraryShelf("builtin")
    let entry = try XCTUnwrap(
      core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin").first)
    let control = try core.createImport(title: "暂停语义样本")
    let id = control.bookId()
    try core.streamImport(
      control: control, filePath: source.path,
      expectedRawSha256: CloudDocumentHandoff.bytesHash(source), encodingOverride: "UTF-8")
    control.pause()
    try core.failImport(control: control, error: .Paused)
    try core.linkLibraryFile(fileId: entry.id, bookId: id)
    let sourceKey = "Moonread.sourceDraft.library." + entry.id
    let bookmark = try local.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let descriptor = ImportSource(
      rootBookmark: bookmark, relativePath: "book.txt", encoding: "UTF-8", sourceKey: sourceKey,
      fileID: entry.id)
    defaults.set(
      try JSONEncoder().encode(descriptor), forKey: "Moonread.importSource.library." + id)
    defaults.set(id, forKey: sourceKey)
    return (root, service, core, entry.source, id, defaults, suite)
  }

  @MainActor func waitForLibraryState(
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    await awaitState(condition)
    XCTAssertTrue(condition(), "Library state did not settle", file: file, line: line)
  }

  @MainActor func syntheticPages(
    _ window: ReadingWindow, preserving: [TextPage] = [], keeping: UInt64? = nil
  ) -> [TextPage] {
    TextPage.paginate(
      window, size: .zero, attributes: [:], preserving: preserving, keeping: keeping
    ) { projection, backward in
      let text = projection.text as NSString
      var ranges: [NSRange] = []
      var cursor = 0
      while cursor < text.length {
        let proposed = NSRange(location: cursor, length: min(37, text.length - cursor))
        let range = text.rangeOfComposedCharacterSequences(for: proposed)
        ranges.append(range)
        cursor = NSMaxRange(range)
      }
      return ranges
    }
  }

  func readingChunks() -> [TextChunk] {
    var offset: UInt64 = 0
    return (0..<5).map { index in
      let text = String(repeating: "月亮落在窗边，故事仍在继续。🌙 👨‍👩‍👧‍👦 e\u{301}，读者轻轻翻开下一页。\n", count: 2 + index)
      let end = offset + UInt64(text.utf8.count)
      defer { offset = end }
      return TextChunk(index: UInt32(index), startUtf8: offset, endUtf8: end, text: text)
    }
  }

  @MainActor
  func assertCoverage(
    _ pages: [TextPage], window: ReadingWindow, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(pages.first?.start, window.start, file: file, line: line)
    XCTAssertEqual(pages.last?.end, window.end, file: file, line: line)
    XCTAssertEqual(
      pages.map { $0.text.string }.joined(), ReadingText(window).text, file: file, line: line)
    for (page, next) in zip(pages, pages.dropFirst()) {
      XCTAssertEqual(page.end, next.start, file: file, line: line)
      XCTAssertEqual(
        UInt64(page.text.string.utf8.count), page.end - page.start, file: file, line: line)
    }
  }
}

@MainActor
final class ThemePreferenceWriterProbe {
  var snapshot = defaultThemeSnapshot()
  var requests: [ThemePreferences] = []
  var started: ((Int) -> Void)?
  var continuation: CheckedContinuation<ThemeSnapshot, Error>?

  func save(_ value: ThemePreferences) async throws -> ThemeSnapshot {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      requests.append(value)
      started?(requests.count)
    }
  }

  func succeed() {
    snapshot.preferences = requests.last!
    let pending = continuation
    continuation = nil
    pending?.resume(returning: snapshot)
  }

  func fail() {
    let pending = continuation
    continuation = nil
    pending?.resume(throwing: CocoaError(.fileWriteUnknown))
  }
}

/// Offline deletion tests inject only filesystem IO/scan; no provider/account is used.
final class TrashIOProbe: @unchecked Sendable {
  let lock = NSLock()
  var calls: [String] = []
  var failure: NSError?
  var scanCount = 0
  static func move(_ url: URL) throws {
    let trash = url.deletingLastPathComponent().appendingPathComponent(".Trash")
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: url, to: trash.appendingPathComponent(url.lastPathComponent))
  }
  func record(_ value: String) { lock.withLock { calls.append(value) } }
  func values() -> [String] { lock.withLock { calls } }
  func setFailure(_ error: NSError?) { lock.withLock { failure = error } }
  func scanFailure() -> NSError? {
    lock.withLock {
      scanCount += 1
      return failure
    }
  }
  func scans() -> Int { lock.withLock { scanCount } }
}

final class TrashScanProbe: @unchecked Sendable {
  struct Job: @unchecked Sendable {
    let entered: XCTestExpectation
    let permit: DispatchSemaphore
    let items: [ScannedLibraryItem]
  }
  let lock = NSLock()
  var jobs: [Job] = []
  func enqueue(_ job: Job) { lock.withLock { jobs.append(job) } }
  func scan(_ root: URL) throws -> [ScannedLibraryItem] {
    let job = lock.withLock { jobs.isEmpty ? nil : jobs.removeFirst() }
    if let job {
      job.entered.fulfill()
      guard job.permit.wait(timeout: .now() + 5) == .success else {
        throw CocoaError(.userCancelled)
      }
      return job.items
    }
    return try ReaderService.libraryDirectoryItems(root)
  }
}

@MainActor class LibraryTrashFixture: XCTestCase {
  func fixture(
    _ names: [String] = ["a.txt"], deletion: @escaping @Sendable (URL, Bool) throws -> Void,
    scan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil
  ) async throws -> (URL, ReaderCore, ReaderService, [LibraryEntry]) {
    try await makeLibraryFileFixture(names, deletion: deletion, scan: scan)
  }
  func wait(
    _ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line
  ) async {
    await awaitState(condition)
    XCTAssertTrue(condition(), file: file, line: line)
  }

}

@MainActor class ApplicationStateFixture: XCTestCase {
}

@MainActor
func makeLibraryFileFixture(
  _ names: [String] = ["a.txt"],
  deletion: @escaping @Sendable (URL, Bool) throws -> Void,
  scan: (@Sendable (URL, [CloudDocumentItem]) throws -> [ScannedLibraryItem])? = nil
) async throws -> (URL, ReaderCore, ReaderService, [LibraryEntry]) {

  let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
    "LibraryTrashFixture-" + UUID().uuidString)
  let root = temporary.appendingPathComponent("library")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  for name in names {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(("第一章\n" + String(repeating: "离线删除测试。\n", count: 2)).utf8).write(to: url)
  }
  let core = try ReaderCore(dataDirectory: temporary.appendingPathComponent("db").path)
  let service = ReaderService(
    core: core, libraryDirectory: root,
    sourceDefaultsSuite: "LibraryTrashFixture-" + UUID().uuidString,
    libraryDeletion: deletion, libraryScan: scan)
  try await service.prepareLibrary()
  try await service.scanLibraryShelf("builtin")
  return (
    temporary, core, service, try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
  )

}
