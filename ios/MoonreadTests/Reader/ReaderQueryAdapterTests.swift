import CryptoKit
import GRDB
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class ReaderQueryAdapterRecentReadingRestorationTests: RecentReadingRestorationFixture {
  // S276: 未开书但已知 SHA 的记录仍按内容键传给详情/隐藏操作；只测 Swift 输入边界，排序计算在 Rust。
  func testIndexedOnlyRecentHideAndDetailsUseContentSHA() async throws {
    let text = "第一話 星港\n只用于验证索引身份的原创正文。\n"
    let f = try await fixture(["indexed.txt": Data(text.utf8)])
    defer { f.clean() }
    try await scan(f)
    let file = try XCTUnwrap(f.core.pendingIdentityFiles(shelfId: "builtin").first)
    let identity = try SourceIdentityProbe().identify(
      filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: file.decoding)
    XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
    try await position(f, key: identity.contentSha256, hint: nil, offset: identity.utf8Bytes / 2)
    try await restorationPosition(f, key: identity.contentSha256, hint: nil, offset: identity.utf8Bytes / 2)
    let base = try await f.service.details(sha: identity.contentSha256).metadata
    var edited = base
    edited.author = "原创作者"
    edited.tags = ["星港"]
    try await f.service.saveMetadata(base: base, edited: edited)
    let recent = try await f.service.recentLibrary()
    XCTAssertEqual(recent.map(\.readingKey), [identity.contentSha256])
    let entry = try XCTUnwrap(recent.first)
    XCTAssertNil(entry.bookId)
    let model = BookInformationModel(service: f.service)
    await model.load(
      StatisticsRoute(
        target: .file(fileId: entry.id), title: entry.title))
    XCTAssertNil(model.error)
    XCTAssertEqual(model.entry?.positionUtf8, identity.utf8Bytes / 2)
    XCTAssertEqual(model.details?.metadata.tags, ["星港"])
    XCTAssertEqual(model.details?.metadata.author, "原创作者")
    try await f.service.hideRecent(try XCTUnwrap(entry.readingKey))
    let hidden = try await f.service.recentLibrary()
    XCTAssertTrue(hidden.isEmpty)
    XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId)
  }
}

final class FolderQueryAdapterTests: XCTestCase {
  private static let location = LibraryLocation(shelfID: "builtin")

  private func withFolder(_ exercise: (ReaderIndex) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FolderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixtureBundle = Bundle(for: Self.self)
    let resources: Bundle = fixtureBundle.url(forResource: "schema", withExtension: "sql") == nil ? .main : fixtureBundle
    let session = try DataSession(layout: .init(applicationSupport: root), bundle: resources)
    let lease = try session.activate(.unknown).0
    defer { try? session.close() }
    try session.prepareIndex(root.appending(path: "reader.sqlite3"), token: lease)
    try session.prepareUsers(lease) { nil }
    let index = ReaderIndex(session: session, lease: lease)
    try session.writeIndex(lease) { db in
      try db.execute(sql: "INSERT INTO main.library_shelves VALUES('builtin','Fixture',X'','local',1,NULL)")
    }
    try exercise(index)
  }

  private static func addFile(_ db: Database, id: String, path: String, parent: String = "", key: String? = nil) throws {
    // A key gives the file a small, valid completed body but no automatic
    // chapter. The domain writer supplies a manual heading where needed.
    let text = "Chapter\nBody\n"
    let bodyID = key.map { _ in "body-" + id }
    if let key, let bodyID {
      try db.execute(sql: """
        INSERT INTO main.books(id,title,content_sha256,encoding,byte_count,chunk_count,projection_end)
        VALUES(?, ?, ?, 'utf-8', ?, 1, ?)
        """, arguments: [bodyID,id,key,text.utf8.count,text.utf8.count])
      try db.execute(sql: "INSERT INTO main.chunks VALUES(?,0,0,?,?,0,11)",
                     arguments: [bodyID,text.utf8.count,text])
    }
    try db.execute(sql: """
      INSERT INTO main.library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id)
      VALUES(?,'builtin',?,?,?,?,?,0,0,?)
      """, arguments: [id,path,parent,id,key == nil,key == nil ? 0 : text.utf8.count,bodyID])
  }

  private static func chapterZero(_ db: Database, key: String, title: String) throws {
    let value = ChapterValue(content_key: key, offset: 0, title: title, level: 0, excluded: false)
    try UserValueRows.put(db, key: .init("chapter/\(key)/0"), value: UserSyncJSON.encode(value), device: "fixture", now: 1)
  }

  private static func metadata(_ db: Database, book: String, field: String, value: String, now: Int64 = 1) throws {
    try UserValueRows.put(db, key: .init("metadata/\(book)/\(field)"), value: value, device: "fixture", now: now)
  }

  func testFixedDirectoryFollowsPublishedCoverSelection() throws {
    try withFolder { index in
      let direct = String(repeating: "a", count: 64)
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "folder", path: "nested")
        try Self.addFile(db, id: "deeper", path: "nested/deeper", parent: "nested")
        try Self.addFile(db, id: "direct", path: "a.txt", key: direct)
        try Self.metadata(db, book: direct, field: "author", value: "\"Direct author\"")
        _ = try ReadingPositionRows.recordPosition(db, book: direct, offset: 3, hint: nil,
          file: nil, device: "fixture", now: 10, token: "direct")
        try Self.chapterZero(db, key: direct, title: "Synthetic correction")
        for (n, digit) in Array("bcdef").enumerated() {
          let ordinal = n + 1
          let key = String(repeating: String(digit), count: 64)
          let path = "nested/deeper/\(ordinal).txt"
          try Self.addFile(db, id: "child-\(ordinal)", path: path, parent: "nested/deeper", key: key)
          let author = ordinal == 2 ? "Unselected" : path
          try Self.metadata(db, book: key, field: "author", value: UserSyncJSON.encode(author))
          // These clocks define the frozen published order: 20,5,4,3; 2 loses.
          _ = try ReadingPositionRows.recordPosition(db, book: key, offset: 3, hint: nil,
            file: nil, device: "fixture", now: ordinal == 1 ? 20 : Int64(ordinal), token: "child-\(ordinal)")
        }
      }
      let entries = try index.folderEntries(Self.location, sort: .reading)
      XCTAssertEqual(entries.map(\.id), ["folder", "direct"])
      XCTAssertEqual(entries.map(\.lastRead), [20, 10])
      let folder = try XCTUnwrap(entries.first?.folderRow)
      XCTAssertEqual(folder.childBookCount, 5)
      XCTAssertEqual(folder.coverPreviews.map(\.fileId), ["child-1", "child-5", "child-4", "child-3"])
      XCTAssertEqual(folder.coverPreviews.compactMap(\.author), [1, 5, 4, 3].map { "nested/deeper/\($0).txt" })
      XCTAssertEqual(entries.last?.displayMetadata?.author, "Direct author")
      XCTAssertNil(entries.last?.metadata)
      XCTAssertEqual(entries.last?.positionUtf8, 3)
      XCTAssertEqual(entries.last?.chapterTitle, "Synthetic correction")
    }
  }

  func testFixedDirectoryKeepsWholeMetadataWinnerAcrossStores() throws {
    try withFolder { index in
      let masked = String(repeating: "a", count: 64), isolated = String(repeating: "b", count: 64)
      let digest = String(repeating: "c", count: 64)
      let cover = BookCoverAsset(id: "formal-cover", sha256: digest, extension: "jpg", width: 10, height: 12)
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: "INSERT INTO usr.cover_asset VALUES('asset',?,X'1234',?,'available')", arguments: [cover.id,digest])
        for (id,key) in [("masked",masked),("isolated",isolated)] {
          try Self.addFile(db, id: id, path: id + ".txt", key: key)
          try Self.metadata(db, book: key, field: "author", value: "\"Formal\"")
          try db.execute(sql: """
            INSERT INTO usr.cover_candidate VALUES(0,?,1,?,?,'fixture',6,'cover',0,'asset',?,'jpg',10,12)
            """, arguments: ["cover-"+id,key,"metadata/"+key+"/cover",digest])
        }
        try db.execute(sql: """
          INSERT INTO usr.metadata_text_candidate VALUES(1,'pending-synopsis',1,?,?,'synopsis','fixture',7,'pending','Pending synopsis only')
          """, arguments: [masked,"metadata/"+masked+"/synopsis"])
        try db.execute(sql: """
          INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
              raw_format,raw_bytes,digest,reason,completeness)
          VALUES(1,'fixture','pending','metadata_text_candidate','future',?,?,'fixture',X'00','opaque','future','complete')
          """, arguments: [isolated,"metadata/"+isolated+"/synopsis"])
        for key in [masked,isolated] { try CurrentUserRows.settleMetadata(db, book: key) }
      }
      let before = try index.folderEntries(Self.location, sort: .reading)
      XCTAssertEqual(before.first { $0.id == "masked" }?.displayMetadata?.author, "")
      XCTAssertNil(before.first { $0.id == "masked" }?.displayMetadata?.cover)
      XCTAssertEqual(before.first { $0.id == "isolated" }?.displayMetadata?.cover, cover,
                     "An isolated field does not create a pending object")
      XCTAssertTrue(before.allSatisfy { $0.metadata == nil })
      try index.session.writeUsers(index.lease) { db in
        try Self.metadata(db, book: isolated, field: "synopsis", value: "\"Unrelated synopsis\"", now: 8)
      }
      XCTAssertEqual(try index.folderEntries(Self.location, sort: .reading), before)
      try index.session.writeUsers(index.lease) { db in
        try Self.metadata(db, book: isolated, field: "author", value: "\"New author\"", now: 9)
      }
      let refreshed = try index.folderEntries(Self.location, sort: .reading)
      XCTAssertEqual(refreshed.first { $0.id == "isolated" }?.displayMetadata?.author, "New author")
    }
  }

  func testFixedDirectoryUsesManualChapterZeroOnlyWithEffectivePosition() throws {
    try withFolder { index in
      let key = String(repeating: "a", count: 64)
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "direct", path: "a.txt", key: key)
        try ReadingPositionRows.recordOpened(db, book: key, openedAt: 450, file: nil, device: "fixture", now: 450, token: "opened")
        try Self.chapterZero(db, key: key, title: "Manual zero")
      }
      func card() throws -> LibraryEntry {
        try XCTUnwrap(index.folderEntries(Self.location, sort: .reading).first)
      }
      let unread = try card()
      XCTAssertEqual(unread.lastRead, 0, "Opened does not rank a directory")
      XCTAssertNil(unread.chapterTitle, "Absent position does not match a manual chapter at 0")
      try index.session.writeUsers(index.lease) { db in
        _ = try ReadingPositionRows.recordPosition(db, book: key, offset: 0, hint: nil,
          file: nil, device: "fixture", now: 451, token: "at-zero")
      }
      let atZero = try card()
      XCTAssertEqual(atZero.positionUtf8, 0)
      XCTAssertEqual(atZero.lastRead, 451)
      XCTAssertEqual(atZero.chapterTitle, "Manual zero", "An explicit zero position is valid")
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: """
          INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
              raw_format,raw_bytes,digest,reason,completeness)
          VALUES(0,'fixture','formal','position_candidate','future',?,?,'fixture',X'00','opaque','future','complete')
          """, arguments: [key,"position/"+key])
        try ReadingPositionRows.settleCurrent(db, book: key)
      }
      XCTAssertNil(try card().chapterTitle, "An isolated position also supplies no chapter anchor")
    }
  }
}

final class ReaderQueryAdapterReaderIntegrationTests: ReaderIntegrationFixture {
  @MainActor func testDirectoryCompletesWithPendingImportInFolderCover() async throws {
    let (root, service, core, _, _, _, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    try core.scanLibraryShelf(shelfId: "builtin", items: [
      .init(relativePath: "folder", directory: true, size: 0, modified: 0, needsDownload: false),
      .init(relativePath: "folder/fixture.txt", directory: false, size: 10, modified: 0, needsDownload: false)
    ])
    let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { !$0.directory })
    let job = try core.createImport(title: "Synthetic")
    let key = ReadingKey.pending(bookId: job.bookId())
    try core.linkLibraryFile(fileId: file.id, bookId: job.bookId())
    await service.queryFixture { scope, phase in
      if scope == "directory", phase == .retry { throw ReaderError.InvalidSettings }
    }
    let location = LibraryLocation(shelfID: "builtin")
    let entries = try await service.libraryEntries(location)
    XCTAssertEqual(entries.first?.folderRow?.childBookCount, 1)
    XCTAssertEqual(entries.first?.folderRow?.coverPreviews.map(\.readingKey), [key])
    let nested = try await service.libraryEntries(.init(shelfID: "builtin", path: "folder"))
    XCTAssertEqual(nested.first?.readingIdentity, key)
    XCTAssertEqual(try core.importStatus(bookId: job.bookId()).text.readingKey, key)
  }

  @MainActor func testCatalogueCardsFilterOptionsAndSearchMatchTheWideBaseline() async throws {
    let (root, service, core, formal, _, first, second, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let a = first.fixtureSHA256, b = second.fixtureSHA256
    try await formal.put("metadata/\(a)/author", value: "\"Synthetic Writer\"", device: "fixture")
    try await formal.put("metadata/\(a)/tag-1", value: "\"Group 2\"", device: "fixture")
    try await formal.put("metadata/\(a)/tag-2", value: "\"Group 10\"", device: "fixture")
    try await formal.put("metadata/\(b)/synopsis", value: "\"Unique synopsis token\"", device: "fixture")
    try await service.savePosition(bookID: first.id, offset: 12)
    let originals = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
    try core.scanLibraryShelf(shelfId: "builtin", items: originals.map {
      .init(relativePath: $0.relativePath, directory: false, size: $0.size, modified: $0.modified, needsDownload: $0.needsDownload)
    } + [
      .init(relativePath: "sub", directory: true, size: 0, modified: 1, needsDownload: false),
      .init(relativePath: "sub/a2.txt", directory: false, size: first.byteCount, modified: 1, needsDownload: false)
    ])
    let copy = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "sub/a2.txt" })
    try core.linkLibraryFile(fileId: copy.id, bookId: first.id)

    let location = LibraryLocation(shelfID: "builtin")
    let old = try await service.catalogueQuery(location, recursive: true)
    let names = try await service.allLibraryBooks(location.shelfID)
    XCTAssertEqual(names.map(\.id), try old.allLibraryBooks(shelfId: location.shelfID).map(\.id))
    XCTAssertEqual(names.count, 3, "Copies stay separate physical files")
    XCTAssertTrue(names.allSatisfy { $0.metadata == nil })
    let groups = try await service.libraryTagGroups(location.shelfID)
    let oldGroups = try old.allLibraryTagGroups(shelfId: location.shelfID)
    XCTAssertEqual(groups.bookCount, oldGroups.bookCount)
    XCTAssertEqual(groups.groups.map(\.tag), oldGroups.groups.map(\.tag))
    XCTAssertEqual(groups.groups.map { $0.entries.map(\.id) }, oldGroups.groups.map { $0.entries.map(\.id) })
    XCTAssertTrue(groups.groups.prefix(2).allSatisfy { $0.entries.count == 2 && $0.entries.allSatisfy { $0.metadata == nil } })
    let options = try await service.metadataOptions(shelfID: location.shelfID)
    XCTAssertEqual(options, try old.bookFilterOptions(shelfId: location.shelfID))
    let configuration = BookSearchConfiguration(root: .init(kind: .group(.all, [
      .init(kind: .rule(.status([.reading]))),
      .init(kind: .rule(.tag(.all, [.text("Group 10")]))),
      .init(kind: .rule(.author(["Synthetic Writer"])))
    ])), sorts: [.init(field: .author)])
    let scope = CatalogueScope.shelf(shelfId: location.shelfID, parentPath: "", recursive: true)
    for spec: LibraryQueryRules.SearchSpec in [
      .init(profile: .library, query: "synthetic", configuration: configuration),
      .init(profile: .library, query: "sub"),
      .init(profile: .library, author: ""),
    ] {
      let expected = LibraryQueryRules.searchOutcome(
        try old.librarySearchCandidates(scope: scope, booksOnly: spec.configuration.booksOnly), spec: spec)
      let narrow = try await service.libraryCatalogueSearch(scope, spec: spec)
      XCTAssertEqual(narrow.entries.map(\.id), expected.entries.map(\.id))
      XCTAssertEqual(narrow.unknownCount, expected.unknownCount)
      XCTAssertTrue(narrow.entries.allSatisfy { $0.metadata == nil })
      if spec.query == "sub" {
        XCTAssertEqual(narrow.entries.first?.folderRow?.coverPreviews.first?.author, "Synthetic Writer")
      }
    }
    let aiSpec = LibraryQueryRules.SearchSpec(profile: .ai, query: "synopsis token")
    let ai = try await service.searchCatalogue(nil, spec: aiSpec)
    XCTAssertEqual(ai.map(\.readingKey), [b])
    try await formal.receiveSyncFixture("value", key: "metadata/\(b)/synopsis", payload: "{\"v\":2}")
    do {
      _ = try await service.searchCatalogue(nil, spec: aiSpec)
      XCTFail("AI synopsis search keeps the formal compatibility barrier")
    } catch is UserSyncCompatibilityError {}
  }

  @MainActor func testMetadataEditNotificationRoutesOnlyRelevantVisibleInputs() async throws {
    let (root, service, _, _, _, first, second, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let keys: Set<String> = [first.fixtureSHA256]
    let otherKeys: Set<String> = [second.fixtureSHA256]
    let notices = expectation(description: "Existing book metadata signal carries two concrete field changes")
    notices.expectedFulfillmentCount = 2
    let changes = QueryAttemptCounter()
    let token = NotificationCenter.default.addObserver(forName: .bookMetadataChanged, object: nil, queue: nil) { note in
      guard (note.userInfo?["keys"] as? [String]) == [first.fixtureSHA256] else { return }
      let refresh = note.affectsLibraryMetadata(.card, keys: keys)
      let sameDomainWrongBook = note.affectsLibraryMetadata(.card, keys: otherKeys)
      XCTAssertFalse(sameDomainWrongBook)
      if refresh { Task { _ = await changes.next(); notices.fulfill() } }
      else { notices.fulfill() }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    let base = try await service.details(sha: first.fixtureSHA256).metadata
    var synopsis = base; synopsis.synopsis = "Not displayed on the card"
    try await service.saveMetadata(base: base, edited: synopsis)
    var author = synopsis; author.author = "Visible author"
    try await service.saveMetadata(base: synopsis, edited: author)
    await fulfillment(of: [notices], timeout: 2)
    let count = await changes.count
    XCTAssertEqual(count, 1)
    let cards = try await service.libraryEntries(.init(shelfID: "builtin"))
    XCTAssertEqual(cards.first { $0.readingKey == first.fixtureSHA256 }?.displayMetadata?.author, "Visible author")
    XCTAssertTrue(Notification(name: .bookMetadataChanged).affectsLibraryMetadata(.card, keys: keys))
  }

  @MainActor func testBatchedProjectionOnlyReadsScopedCandidatesAndKeepsCompatibility() async throws {
    let store = try makeInMemoryUserStore()
    let keys = (1...140).map { String(format: "%064x", $0) }
    let first = keys[0], last = keys[139], blocked = keys[128]
    let outside = String(repeating: "f", count: 64)
    func envelope(_ key: String, offset: UInt64, updated: Int64) throws -> String {
      try UserSyncJSON.encode(StoredValue(updated: updated, token: "fixture-\(updated)",
        value: UserSyncJSON.encode(PositionValue(content_key: key, offset: offset))))
    }
    try await store.receiveSyncFixture("value", key: "position/" + last, payload: envelope(last, offset: 1, updated: 1))
    try await store.receiveSyncFixture("position", key: last, payload: envelope(last, offset: 2, updated: 2))
    try await store.receiveSyncFixture("value", key: "position/" + blocked, payload: envelope(blocked, offset: 3, updated: 1))
    try await store.receiveSyncFixture("position", key: blocked, payload: "{}")
    try await store.receiveSyncFixture("position", key: outside, payload: envelope(outside, offset: 9, updated: 9))
    try await store.put("metadata/\(first)/tag-fixture", value: "\"Synthetic\"", device: "fixture")
    try await store.put("metadata/\(outside)/author", value: "\"Outside\"", device: "fixture")
    try await store.put("opened/\(last)", value: "12345", device: "fixture")
    let input = try requireStoreProjection(try await store.projection(generation: 0, enabled: true, includeFacts: false, keys: keys))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.json.utf8)) as? [String: Any])
    let positions = try XCTUnwrap(json["positions"] as? [[String: Any]])
    XCTAssertEqual(positions.map { $0["content_key"] as? String }, [last])
    XCTAssertEqual(positions.first?["offset"] as? Int, 2)
    XCTAssertEqual(json["unsupportedPositions"] as? [String], [blocked])
    let metadata = try XCTUnwrap(json["metadata"] as? [[String: Any]])
    XCTAssertEqual(metadata.map { $0["sha"] as? String }, [first])
    XCTAssertEqual(metadata.first?["tags"] as? [String], ["Synthetic"])
    XCTAssertFalse(input.json.contains(outside))
    let onlyOpened = try requireStoreProjection(try await store.projection(generation: 0, enabled: true, includeFacts: false, keys: keys, fields: [.opened]))
    XCTAssertTrue(onlyOpened.json.contains("12345"))
    XCTAssertFalse(onlyOpened.json.contains(first))
    XCTAssertFalse(onlyOpened.json.contains(blocked))
  }

  @MainActor func testObsoleteSharedFactPreparationDoesNotSurfaceItsFailure() async throws {
    let schema = UserDataStore.schema
    let formal = UserDataStore(modelContainer: try ModelContainer(for: schema, configurations: [
      ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    ]))
    let stale = try await formal.fixtureFailedFactPreparation(invalidate: true)
    XCTAssertNil(stale, "An error from obsolete shared work must become an attempt retry")
    do {
      _ = try await formal.fixtureFailedFactPreparation(invalidate: false)
      XCTFail("A failure from current inputs must surface")
    } catch let error as CocoaError {
      XCTAssertEqual(error.code, .fileReadNoPermission)
    }
  }

  @MainActor func testPreparedStatisticsDatesMatchFullProjectionAndInvalidateByInput() async throws {
    let (root, service, _, formal, pending, book, other, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    func fact(_ id: String, key: String, day: Int, preview: Bool = false) throws -> (String, String, String) {
      let value: [String: Any] = ["content_key": key, "title": "Synthetic", "device": "fixture", "slice": ["id": id, "session_id": id, "visit_id": id, "book_id": book.id, "started_ms": day * 86400000, "ended_ms": day * 86400000 + 1000, "local_day": day, "utc_offset_seconds": 3600, "preview": preview, "exposures": [["start_utf8": 3,"end_utf8": 6,"duration_ms": 500],["start_utf8": 6,"end_utf8": 9,"duration_ms": 500]]]]
      return (id, key, String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
    let key = book.fixtureSHA256
    try await formal.saveFacts([fact("old", key: key, day: 19000), fact("new", key: key, day: 20000), fact("preview", key: other.fixtureSHA256, day: 20001, preview: true)], generation: 0, current: 0, enabled: true)
    try await pending.saveFacts([fact("pending", key: "pending:" + book.id, day: 20001)], generation: 0, current: 0, enabled: true)
    let early = try requireStoreProjection(try await formal.projection(generation: 0, enabled: true, includeFacts: true, statisticsRange: 19000...19000))
    let later = try requireStoreProjection(try await formal.projection(generation: 0, enabled: true, includeFacts: true, statisticsRange: 20000...20000))
    XCTAssertNotNil(early.facts)
    XCTAssertEqual(early.facts?.preparedId, later.facts?.preparedId, "Different dates reuse the decoded handle")
    XCTAssertNotEqual(early.facts?.indices, later.facts?.indices)
    XCTAssertFalse(early.json.contains("\"facts\""), "Facts must not enter non-fact JSON")
    let full = try await service.effectiveQuery(facts: .all, fields: .metadata)
    for bounds in [19000...20001, 20000...20001, 20000...20000] {
      let first = Int64(bounds.lowerBound), last = Int64(bounds.upperBound)
      let read = try await service.statisticsRead(first: first, last: last)
      XCTAssertEqual(read.value, try full.statisticsOverview(firstDay: first, lastDay: last, contentKey: nil))
      let activities = try await service.activitiesRead(first: first, last: last)
      XCTAssertEqual(activities.value, try full.readingActivities(firstDay: first, lastDay: last, contentKey: nil))
      XCTAssertEqual(read.version, activities.version)
      XCTAssertNil(read.compatibilityNotice)
    }
    let before = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    try await formal.put("metadata/" + other.fixtureSHA256 + "/author", value: "\"Other\"", device: "fixture")
    let unchanged = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertEqual(before.version, unchanged.version)
    try await formal.saveFacts([fact("later", key: key, day: 20000)], generation: 0, current: 0, enabled: true)
    let changed = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertNotEqual(before.version, changed.version)
    XCTAssertEqual(changed.value.totalDurationMs, before.value.totalDurationMs + 1000)
    try await formal.clear(book: key, session: "new")
    let cleared = try await service.statisticsRead(first: 20000, last: 20001, book: key)
    XCTAssertEqual(cleared.value.totalDurationMs, before.value.totalDurationMs)
    let scopedFull = try await service.effectiveQuery(records: .only([.formal(sha256: key)]), facts: .only([.formal(sha256: key)]), fields: .metadata)
    XCTAssertEqual(cleared.value, try scopedFull.statisticsOverview(firstDay: 20000, lastDay: 20001, contentKey: .formal(sha256: key)))
    let model = StatisticsModel(service: service)
    let window = StatisticsWindow(period: .month, date: StatisticsDates.date(20000))
    let target = StatisticsRoute(target: .record(key: .formal(sha256: key)), title: "Synthetic")
    await model.load(window, target: target)
    let state = model.state(window, target: target)
    XCTAssertNil(state.error)
    XCTAssertTrue(state.content?.detailsLoaded == true)
    XCTAssertEqual(state.cumulative?.durationMs, 2000)
    XCTAssertEqual(state.overview?.totalDurationMs, 1000)
    XCTAssertEqual(state.spans.count, 1)
    try await service.savePosition(bookID: book.id, offset: 3)
    let withoutRecords = try await service.effectiveQuery(records: .only([]), facts: .all)
    let withRecords = try await service.effectiveQuery(facts: .all)
    let withoutFacts = try await service.effectiveQuery()
    let emptyFacts = try await service.effectiveQuery(facts: .only([]))
    XCTAssertEqual(try withoutFacts.bookInfo(bookId: book.id).positionUtf8, 3)
    XCTAssertEqual(try withoutRecords.bookInfo(bookId: book.id).positionUtf8, 0)
    XCTAssertEqual(try withoutRecords.statisticsOverview(firstDay: 19000, lastDay: 20001, contentKey: nil).totalDurationMs,
                   try withRecords.statisticsOverview(firstDay: 19000, lastDay: 20001, contentKey: nil).totalDurationMs)
    for query in [withoutFacts, emptyFacts] {
      XCTAssertEqual(try query.statisticsOverview(firstDay: 19000, lastDay: 20001, contentKey: nil).totalDurationMs, 0)
    }

  }

  @MainActor func testActiveQueriesRebuildCompleteInputsUntilStableAndKeepRealFailures() async throws {
    let (root, service, core, formal, _, book, other, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let attempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      guard scope.hasPrefix("book-"), phase == .built else { return }
      let n = await attempts.next()
      if n <= 3 {
        try await formal.put("metadata/" + book.fixtureSHA256 + "/author", value: "\"Revision \(n)\"", device: "fixture")
      } else {
        // Import progress and unrelated books must not make this readable prefix starve.
        await service.readingChanged(book.id)
        try await formal.put("metadata/" + other.fixtureSHA256 + "/author", value: "\"Unrelated\"", device: "fixture")
      }
    }
    let query = try await service.bookQuery(book.id)
    XCTAssertEqual(try query.bookDetails(target: .cached(bookId: book.id)).requireIdentified().metadata.author, "Revision 3")
    let rounds = await attempts.count
    XCTAssertEqual(rounds, 4)
    await service.queryFixture { _, phase in
      if phase == .built { throw CocoaError(.fileReadNoPermission) }
    }
    do { _ = try await service.bookQuery(book.id); XCTFail("Real failure must escape, not retry") }
    catch let error as CocoaError { XCTAssertEqual(error.code, .fileReadNoPermission) }
    // Recent's details must revalidate the INDEX even if only a different book changed.
    try await service.recordBookOpened(book.id, at: 100)
    try await formal.put("metadata/" + other.fixtureSHA256 + "/author", value: "\"New recent\"", device: "fixture")
    let recentAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "recent", phase == .built, await recentAttempts.next() == 1 {
        try await service.recordBookOpened(other.id, at: 200)
      }
    }
    let recent = try await service.recentLibrary(1)
    XCTAssertEqual(recent.first?.readingKey, other.fixtureSHA256)
    XCTAssertEqual(recent.first?.displayMetadata?.author, "New recent")
    // A new directory member changes the semantic scope, not just its old value versions.
    let catalogueAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "catalogue", phase == .built, await catalogueAttempts.next() == 1 {
        let extra = root.appendingPathComponent("extra.txt")
        try "第一章 新的合成章节\n用于目录输入范围变化。".write(to: extra, atomically: true, encoding: .utf8)
        let added = try core.importBook(filePath: extra.path, title: "Extra fixture")
        try core.scanLibraryShelf(shelfId: "builtin", items: [
          .init(relativePath: "a.txt", directory: false, size: book.byteCount, modified: 0, needsDownload: false),
          .init(relativePath: "b.txt", directory: false, size: other.byteCount, modified: 0, needsDownload: false),
          .init(relativePath: "extra.txt", directory: false, size: added.byteCount, modified: 0, needsDownload: false)])
        let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "extra.txt" })
        try core.linkLibraryFile(fileId: file.id, bookId: added.id)
        try await formal.put("metadata/" + added.fixtureSHA256 + "/author", value: "\"Directory update\"", device: "fixture")
      }
    }
    let entries = try await service.catalogueQuery(.init(shelfID: "builtin"), recursive: true).allLibraryBooks(shelfId: "builtin")
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries.first { $0.name == "extra.txt" }?.metadata?.author, "Directory update")
    let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })
    let fileAttempts = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "file-" + file.id, phase == .built, await fileAttempts.next() == 1 {
        try core.linkLibraryFile(fileId: file.id, bookId: other.id)
      }
    }
    let relinked = try await service.libraryEntry(file.id)
    XCTAssertEqual(relinked.readingKey, other.fixtureSHA256)
    XCTAssertEqual(relinked.metadata?.author, "New recent")
    let preferences = QueryAttemptCounter()
    await service.queryFixture { _, phase in
      if phase == .built, await preferences.next() == 1 {
        UserDefaults(suiteName: suite)!.set([other.fixtureSHA256], forKey: "Moonread.hiddenRecent")
      }
    }
    let hidden = try await service.bookQuery(other.id)
    XCTAssertTrue(try hidden.recentLibraryEntries(limit: 2).isEmpty)
    let preferenceRounds = await preferences.count
    XCTAssertEqual(preferenceRounds, 2, "The same input signature validates cache hits and completed builds")
    await service.queryFixture(nil)
  }

  @MainActor func testRecentReadsCommittedFileIdentityOnNextRequest() async throws {
    let (root, service, core, _, _, first, second, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    try await service.recordBookOpened(first.id, at: 200)
    try await service.recordBookOpened(second.id, at: 100)
    let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { $0.relativePath == "a.txt" })

    let before = try await service.recentLibrary(1)
    XCTAssertEqual(before.map(\.readingIdentity), [.formal(sha256: first.fixtureSHA256)])
    try core.linkLibraryFile(fileId: file.id, bookId: second.id)
    let after = try await service.recentLibrary(1)
    XCTAssertEqual(after.map(\.readingIdentity), [.formal(sha256: second.fixtureSHA256)])
  }

  @MainActor func testInformationSourceUsesDirectoryOrderAndHonorsExplicitFile() async throws {
    let (root, service, core, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let key = ReadingKey.formal(sha256: book.fixtureSHA256)
    let initial = try core.querySnapshot(json: "{}").allLibraryBooks(shelfId: "builtin")
    try core.scanLibraryShelf(shelfId: "builtin", items: initial.map {
      .init(relativePath: $0.relativePath, directory: false, size: $0.size, modified: $0.modified, needsDownload: $0.needsDownload)
    } + [.init(relativePath: "z-copy.txt", directory: false, size: book.byteCount, modified: 100, needsDownload: true)])
    let files = try core.sourceFiles(shelfId: "builtin")
    let first = try XCTUnwrap(files.first { $0.relativePath == "a.txt" })
    let copy = try XCTUnwrap(files.first { $0.relativePath == "z-copy.txt" })
    try core.linkLibraryFile(fileId: copy.id, bookId: book.id)
    try await formal.put("metadata/\(book.fixtureSHA256)/synopsis", value: "\"Full details remain available\"", device: "fixture")
    let route = StatisticsRoute(target: .record(key: key), title: "Synthetic")
    let model = BookInformationModel(service: service)
    await model.load(route)
    XCTAssertEqual(model.entry?.id, copy.id, "Unread copies follow modification time")
    XCTAssertEqual(model.entry?.needsDownload, true)

    try await service.savePosition(bookID: book.id, offset: 12)
    UserDefaults(suiteName: suite)?.set(copy.id, forKey: "Moonread.preferredFile." + book.fixtureSHA256)
    let old = try await service.libraryEntries(nil).first { $0.readingIdentity == key }
    await model.load(route)
    XCTAssertEqual(old?.id, first.id)
    XCTAssertEqual(model.entry?.id, old?.id, "Details uses natural name after the shared reading time, not the preferred copy")
    XCTAssertEqual(model.entry?.positionUtf8, old?.positionUtf8)
    XCTAssertEqual(model.entry?.byteCount, old?.byteCount)
    XCTAssertNil(model.entry?.metadata)
    XCTAssertNil(model.entry?.chapterTitle)
    XCTAssertEqual(model.details?.metadata.synopsis, "Full details remain available")
    XCTAssertNotNil(model.details?.currentChapter)
    XCTAssertFalse(model.chapters.isEmpty)
    XCTAssertNil(model.error)

    await model.load(.init(target: .file(fileId: copy.id), title: "Explicit"))
    XCTAssertEqual(model.entry?.id, copy.id)
    await model.load(.init(target: route.target, title: route.title, origin: .reader()))
    XCTAssertNil(model.entry)
    XCTAssertNotNil(model.details)

    try await formal.receiveSyncFixture("value", key: "metadata/\(book.fixtureSHA256)/synopsis", payload: "{\"v\":2}")
    await model.load(route)
    XCTAssertNil(model.details)
    XCTAssertNotNil(model.error, "The actual details read still enforces the formal metadata barrier")
  }

  @MainActor func testCancelledQueryDoesNotPublishCacheOrRestartAndSharedInitializationSurvives() async throws {
    let (root, service, _, formal, pending, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    for cancelAt in [AppDataService.UserQueryTestPhase.built, .retry] {
      let gate = RestorationGate(), attempts = QueryAttemptCounter()
      await service.queryFixture { _, phase in
        if phase == .built {
          _ = await attempts.next()
          if cancelAt == .retry { try await formal.put("metadata/" + book.fixtureSHA256 + "/author", value: "\"Changed\"", device: "fixture") }
        }
        if phase == cancelAt { await gate.wait() }
      }
      let work = Task { try await service.bookQuery(book.id) }
      await gate.waitForEntry(); work.cancel(); await gate.release()
      do { _ = try await work.value; XCTFail("Actual task cancellation must escape") } catch is CancellationError { }
      let count = await attempts.count, cacheCount = await service.queryFixtureCacheCount()
      XCTAssertEqual(count, 1); XCTAssertEqual(cacheCount, 0)
    }
    await service.queryFixture(nil)
    let gate = RestorationGate(), starts = QueryAttemptCounter()
    let shared = AppDataService(core: try ReaderCore(dataDirectory: root.appendingPathComponent("shared-db").path),
      sourceDefaultsSuite: suite, userStoreFactory: { name, _ in
        if name == "pending-users.store" { return pending }
        _ = await starts.next(); await gate.wait(); return formal
      })
    let first = Task { try await shared.effectiveQuery() }
    await gate.waitForEntry()
    let second = Task { try await shared.effectiveQuery() }
    first.cancel(); await gate.release()
    do { _ = try await first.value; XCTFail("Cancelled waiter") } catch is CancellationError { }
    _ = try await second.value
    let count = await starts.count
    XCTAssertEqual(count, 1, "A cancelled waiter cannot cancel shared initialization")
    // Configuration changes while initialization waits cannot pair an old store with a new epoch.
    let configGate = RestorationGate()
    let replacement = AppDataService(core: try ReaderCore(dataDirectory: root.appendingPathComponent("config-db").path),
      sourceDefaultsSuite: suite, userStoreFactory: { name, cloud in
        if name == "pending-users.store" { return pending }
        if !cloud { await configGate.wait(); return formal }
        return pending
      })
    try await formal.put("metadata/" + book.fixtureSHA256 + "/author", value: "\"Old account\"", device: "fixture")
    let waiting = Task { try await replacement.effectiveQuery(fields: .metadata) }
    await configGate.waitForEntry()
    try await replacement.configureUserCloud(.cloud(.init(recordName: "fixture"), .currentOwner))
    await configGate.release()
    let result = try await waiting.value
    let current = try await replacement.effectiveQuery(fields: .metadata)
    XCTAssertTrue(result === current)
  }

  @MainActor func testReaderMonitorAndDirectoryOwnersHandleInvalidationAndExit() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    for resume in [true, false] {
      let attempts = QueryAttemptCounter()
      await service.queryFixture { scope, phase in
        if scope.hasPrefix("book-"), phase == .built, await attempts.next() <= 3 {
          try await formal.put("metadata/" + book.fixtureSHA256 + "/author", value: "\"\(UUID().uuidString)\"", device: "fixture")
        }
      }
      let session = ReaderSession(service: service, readContinuation: { id, _ in
        if resume { _ = try await service.bookQuery(id) }
        return .init(localOffset: nil, candidate: nil)
      })
      await session.open(.book(book.id))
      await awaitState { session.window != nil && !session.incomplete }
      XCTAssertNil(session.error); XCTAssertNotNil(session.window?.projectionAnchor)
      await session.leave().value
      let count = await attempts.count
      XCTAssertGreaterThanOrEqual(count, 4)
    }
    for leave in [true, false] {
      let gate = RestorationGate()
      await service.queryFixture { _, phase in if phase == .built { await gate.wait() } }
      let tools = ReaderToolsModel(service: service)
      let work = Task { await tools.prepare(bookID: book.id, currentChapter: 0, library: true) }
      await gate.waitForEntry()
      if leave { tools.leave() } else { work.cancel() }
      await gate.release(); await work.value
      XCTAssertTrue(tools.chapters.isEmpty); XCTAssertFalse(tools.loadingChapters); XCTAssertNil(tools.error)
      XCTAssertNil(tools.notesLoadError)
    }
    await service.queryFixture(nil)
  }

  @MainActor func testSystemStatisticsCancellationIsNotUnavailableAndRealFailureStillIs() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let gate = RestorationGate()
    await service.queryFixture { _, phase in if phase == .built { await gate.wait() } }
    let work = Task { try await service.systemWidgetStatistics() }
    await gate.waitForEntry(); work.cancel(); await gate.release()
    do { _ = try await work.value; XCTFail("Cancellation cannot replace previous widget statistics") } catch is CancellationError { }
    await service.queryFixture { _, phase in if phase == .built { throw CocoaError(.fileReadNoPermission) } }
    let failed = try await service.systemWidgetStatistics()
    XCTAssertEqual(failed.status, "unavailable")
    let rounds = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope == "system-catalogue", phase == .built, await rounds.next() <= 3 {
        try await formal.put("metadata/" + book.fixtureSHA256 + "/author", value: "\"\(UUID().uuidString)\"", device: "fixture")
      }
    }
    let file = SystemReadingSnapshotFile(directory: root.appendingPathComponent("system-snapshot"))
    await service.startSystemReadingCatalog(file: file)
    await service.waitForSystemReadingCatalog()
    let before = try file.read()
    XCTAssertEqual(before.books.count, 2)
    let builds = await rounds.count
    XCTAssertEqual(builds, 4)
    let cancelling = RestorationGate()
    await service.queryFixture { scope, phase in
      if scope == "system-widget-statistics", phase == .built { await cancelling.wait() }
    }
    await service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
    await cancelling.waitForEntry()
    await service.cancelSystemQueryFixture()
    await cancelling.release(); await service.waitForSystemReadingCatalog()
    XCTAssertEqual(try file.read().generation, before.generation, "Cancelled refresh must preserve the previous published snapshot")
    await service.queryFixture { scope, phase in
      if scope == "system-widget-statistics", phase == .built { throw CocoaError(.fileReadNoPermission) }
    }
    await service.scheduleSystemReadingCatalog(immediate: true, statisticsChanged: true)
    await service.waitForSystemReadingCatalog()
    XCTAssertEqual(try file.read().statistics?.status, "unavailable")
    await service.queryFixture(nil)
  }

  // S319: 单书查询输入按版本失效且旧 snapshot 不变；仅比较 Swift 送出的 facts，不重复 Rust 最终排序/统计。
  @MainActor func testSingleBookProjectionMatchesBatchAndInvalidatesWithoutMutatingOldSnapshot()
    async throws
  {
    let (root, service, projectedCore, formal, pending, book, other, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    try await service.savePosition(bookID: book.id, offset: 20)
    try await service.savePosition(bookID: other.id, offset: 0)
    try await formal.put(
      "metadata/\(book.fixtureSHA256)/author", value: "\"合成作者\"", device: "fixture")
    try await formal.put(
      "metadata/\(other.fixtureSHA256)/author", value: "\"其他作者\"", device: "fixture")
    try await service.correctChapter(book.id, offset: 0, title: "覆盖章名", level: 1)
    let scoped = try await service.bookQuery(book.id)
    let batch = try await service.effectiveQuery()
    XCTAssertEqual(
      try scoped.readingSnapshot(bookId: book.id), try batch.readingSnapshot(bookId: book.id))
    XCTAssertEqual(
      try scoped.readingFrame(bookId: book.id, offsetUtf8: 20),
      try batch.readingFrame(bookId: book.id, offsetUtf8: 20))
    XCTAssertEqual(
      try scoped.bookDetails(target: .cached(bookId: book.id)).requireIdentified(),
      try batch.bookDetails(target: .cached(bookId: book.id)).requireIdentified())
    let same = try await service.bookQuery(book.id)
    XCTAssertEqual(
      try scoped.readingSnapshot(bookId: book.id), try same.readingSnapshot(bookId: book.id),
      "Unchanged facts have equal query results; framework notifications may evict a cached object")
    let beforeOther = formal.version(keys: [book.fixtureSHA256, "pending:" + book.id], positionsOnly: false, includeFacts: false, statisticsKeys: nil)
    try await service.savePosition(bookID: other.id, offset: 12)
    let afterOther = formal.version(keys: [book.fixtureSHA256, "pending:" + book.id], positionsOnly: false, includeFacts: false, statisticsKeys: nil)
    XCTAssertEqual(beforeOther, afterOther, "Only related input versions may change")
    let unrelated = try await service.bookQuery(book.id)
    XCTAssertTrue(same === unrelated, "An unrelated book position must reuse this query")
    func fact(_ key: String) throws -> (String, String, String) {
      let id = UUID().uuidString
      let payload: [String: Any] = ["content_key": key, "title": "Synthetic", "device": "fixture", "slice": [
        "id": id, "session_id": "fixture", "visit_id": "fixture", "book_id": book.id,
        "started_ms": 1000, "ended_ms": 2000, "local_day": 20000, "utc_offset_seconds": 0,
        "preview": false, "exposures": [["start_utf8": 0, "end_utf8": 9, "duration_ms": 1000]]]]
      return (id, key, String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self))
    }
    try await formal.saveFacts([fact(book.fixtureSHA256), fact(other.fixtureSHA256)], generation: 0, current: 0, enabled: true)
    try await pending.saveFacts([fact("pending:" + book.id)], generation: 0, current: 0, enabled: true)
    let noFactsChanged = try await service.bookQuery(book.id)
    XCTAssertTrue(unrelated === noFactsChanged, "Reading facts cannot invalidate a query that does not depend on them")
    let statsOnly = try requireStoreProjection(try await formal.projection(generation: 0, enabled: true, includeFacts: true,
      keys: [book.fixtureSHA256], statisticsKeys: [book.fixtureSHA256, "pending:" + book.id]))
    XCTAssertFalse(statsOnly.json.contains(other.fixtureSHA256))
    let pendingInput = try requireStoreProjection(try await pending.projection(generation: 0, enabled: true, includeFacts: true,
      keys: [book.fixtureSHA256, "pending:" + book.id], statisticsKeys: [book.fixtureSHA256, "pending:" + book.id]))
    let formalFacts = try projectedCore.querySnapshotWithFacts(nonFactJson: "{}", formal: statsOnly.facts, pending: nil, geometry: .full)
    let pendingFacts = try projectedCore.querySnapshotWithFacts(nonFactJson: "{}", formal: nil, pending: pendingInput.facts, geometry: .full)
    XCTAssertEqual(try formalFacts.readingActivities(firstDay: 20000, lastDay: 20000, contentKey: nil).count, 1)
    XCTAssertEqual(try pendingFacts.readingActivities(firstDay: 20000, lastDay: 20000, contentKey: nil).count, 1,
      "Both identities retain their own facts")
    let outline = try await service.bookQuery(book.id, facts: true).chapterOutline(bookId: book.id)
    let full = try await service.effectiveQuery(facts: .all)
    XCTAssertEqual(outline, try full.chapterOutline(bookId: book.id))
    let widget = try await service.effectiveQuery(facts: .all, fields: [])
    XCTAssertEqual(try widget.statisticsWidgetSummary(today: 20000, weekStart: 19994),
      try full.statisticsWidgetSummary(today: 20000, weekStart: 19994))
    let withFacts = try await service.bookQuery(book.id, facts: true)
    try await formal.saveFacts([fact(other.fixtureSHA256)], generation: 0, current: 0, enabled: true)
    let unrelatedFacts = try await service.bookQuery(book.id, facts: true)
    XCTAssertTrue(withFacts === unrelatedFacts)
    let old = try scoped.readingSnapshot(bookId: book.id).book.positionUtf8
    try await service.savePosition(bookID: book.id, offset: 44)
    let newer = try await service.bookQuery(book.id)
    XCTAssertFalse(scoped === newer)
    XCTAssertEqual(try scoped.readingSnapshot(bookId: book.id).book.positionUtf8, old)
    XCTAssertNotEqual(try newer.readingSnapshot(bookId: book.id).book.positionUtf8, old)
    try await service.hideRecent(book.id)
    let hidden = try await service.bookQuery(book.id)
    XCTAssertTrue(try hidden.recentLibraryEntries(limit: 3).isEmpty)
    NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
    let remote = try await service.bookQuery(book.id)
    XCTAssertFalse(remote === hidden)
    try await service.setStatisticsEnabled(false)
    let generation = try await service.bookQuery(book.id)
    XCTAssertFalse(generation === remote)
    UserDefaults(suiteName: suite)!.set(
      "fixture-preferred", forKey: "Moonread.preferredFile." + book.fixtureSHA256)
    let preferred = try await service.bookQuery(book.id)
    XCTAssertFalse(preferred === generation)
    XCTAssertEqual(try preferred.readingSnapshot(bookId: book.id).book.positionUtf8, 44)
    let input = try requireStoreProjection(try await formal.projection(
      generation: 0, enabled: true, includeFacts: false, keys: [book.fixtureSHA256]))
    XCTAssertFalse(
      input.json.contains(other.fixtureSHA256), "Single-book inputs must not fetch/project another book")
  }

  @MainActor func testOpeningIsPersistedSeparatelyWithoutMovingReadingPosition() async throws {
    let (root, service, _, formal, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let before = try await service.snapshot(book.id)
    try await service.recordBookOpened(book.id, at: 12345)
    let opened = try await formal.value("opened/" + book.fixtureSHA256)
    XCTAssertEqual(opened, "12345")
    let after = try await service.snapshot(book.id)
    XCTAssertEqual(before.book.positionUtf8, after.book.positionUtf8)
    XCTAssertEqual(before.hasStarted, after.hasStarted)
    let position = try await formal.value("position/" + book.fixtureSHA256)
    XCTAssertNil(position)
    let restored = try requireStoreProjection(try await formal.projection(generation: 0, enabled: true, includeFacts: false, positionsOnly: true))
    XCTAssertTrue(restored.json.contains("12345"))
  }

  // S320: 启动恢复尚未结束时 pending 别名的位置仍进入正确开书查询；裁决算法只 S457。
  @MainActor func testPendingAliasPositionIsReadableBeforeStartupRecoveryAndPromotion() async throws
  {
    let (root, service, core, _, pending, book, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let control = try core.createImport(title: "待准备")
    let id = control.bookId()
    let position = String(
      decoding: try JSONEncoder().encode(PositionValue(content_key: "pending:" + id, offset: 20)),
      as: UTF8.self)
    try await pending.put("position/pending:" + id, value: position, device: "fixture")
    try await service.recordBookOpened(id, at: 34567)
    let identities = QueryAttemptCounter()
    await service.queryFixture { scope, phase in
      if scope.hasPrefix("book-"), phase == .built, await identities.next() == 1 {
        try core.reuseImport(control: control, existingId: book.id)
      }
    }
    let canonical = try await service.bookQuery(book.id)
    await service.queryFixture(nil)
    let rounds = await identities.count
    XCTAssertEqual(rounds, 2, "The query must resolve the newly associated pending alias")
    XCTAssertEqual(try canonical.readingSnapshot(bookId: book.id).book.positionUtf8, 20,
      "A scoped canonical query still includes the original pending alias")
    let update = try await service.openingFrame(id, offset: nil)
    XCTAssertTrue(update.0.hasStarted)
    XCTAssertEqual(update.0.book.positionUtf8, 20)
    XCTAssertNotNil(update.1)
    let recovered = await service.recoveredImports
    XCTAssertFalse(recovered, "Reading never runs startup recovery")
    let before = try await pending.value("position/pending:" + id)
    XCTAssertNotNil(before, "Reading must not compact or transfer records")
    try await service.promoteUserData(id)
    let after = try await service.snapshot(book.id)
    XCTAssertEqual(after.book.positionUtf8, 20)
    XCTAssertTrue(after.hasStarted)
    let formalOpened = try await service.userStore().value("opened/" + book.fixtureSHA256)
    let pendingOpened = try await pending.value("opened/pending:" + id)
    XCTAssertEqual(formalOpened, "34567")
    XCTAssertNil(pendingOpened)
  }

  @MainActor func testChapterStructureDoesNotPrepareLegacyProjection() async throws {
    let (root, service, _, _, _, book, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    await service.queryFixture { _, _ in throw ReaderError.InvalidSettings }
    let model = ReaderToolsModel(service: service)
    await model.prepare(bookID: book.id, currentChapter: 0, library: true)
    XCTAssertNil(model.error)
    XCTAssertFalse(model.chapterSnapshot.isEmpty)
    XCTAssertFalse(model.chapterCoverageReady)
    XCTAssertNil(model.noteSnapshot)
    model.leave()
    await service.queryFixture(nil)
  }

  // S359: 目录刷新使当前目录 snapshot 更新，展开/筛选不混用旧版本；目录只读固定结构。
  @MainActor
  func testCompleteOutlineSearchFoldingAndRefreshKeepOneSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("outline.txt")
    let first = "第一卷 夜\n" + (1...100).map { "第\($0)章 月\n正文。\n" }.joined()
    let second = "第二卷 晨\n" + (101...200).map { "第\($0)章 月\n正文。\n" }.joined()
    let source = first + second
    try source.write(to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Outline")
    let query = try core.querySnapshot(json: "{}")
    let outline = try query.chapterOutline(bookId: book.id)
    let volume = try XCTUnwrap(outline.items.first { $0.level == 0 })
    let firstChapter = try XCTUnwrap(outline.items.first { $0.parentUtf8 == volume.startUtf8 })
    for offset in [volume.startUtf8, firstChapter.startUtf8 - 1] {
      let selected = try XCTUnwrap(query.chapterAt(bookId: book.id, offsetUtf8: offset))
      XCTAssertEqual(selected.startUtf8, volume.startUtf8)
      XCTAssertEqual(selected.level, 0, "A current outline item can be a volume, including the gap before its first chapter")
    }
    let current = try XCTUnwrap(outline.items.first { $0.title == "第150章 月" })
    let service = AppDataService(core: core)
    let model = ReaderToolsModel(service: service)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true)
    XCTAssertEqual(model.chapters.count, 202)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)
    XCTAssertNil(model.noteSnapshot, "Opening the chapter list does not prefetch notes")
    let beforePosition = try await service.chapterStructure(book.id)
    try await service.savePosition(bookID: book.id, offset: current.startUtf8)
    let afterPosition = try await service.chapterStructure(book.id)
    XCTAssertEqual(beforePosition, afterPosition, "Position changes do not change chapter structure")
    model.toggleVolume(0)
    model.toggleVolume(UInt64(first.utf8.count))
    XCTAssertEqual(model.chapters.count, 2)
    XCTAssertEqual(model.chapterSnapshot.count, 202, "Editing keeps the complete outline even when both volumes are folded")
    XCTAssertTrue(model.chapterSnapshot.contains { $0.startUtf8 == current.startUtf8 })
    XCTAssertEqual(model.collapsedVolumes, [0, UInt64(first.utf8.count)])
    model.filterChapters("150")
    XCTAssertEqual(model.chapters.map(\.startUtf8), [current.startUtf8])
    XCTAssertEqual(model.chapters[0].wordCount, 3)
    model.filterChapters("")
    XCTAssertEqual(model.chapters.count, 102)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)
    let revision = model.chapterJumpRevision
    try await service.correctChapter(
      book.id, offset: current.startUtf8, title: "第150章 新标题", level: 1)
    await model.refreshChapters()
    XCTAssertEqual(
      model.chapterJumpRevision, revision, "A refreshed snapshot must not reposition the directory")
    XCTAssertEqual(model.chapters.first { $0.startUtf8 == current.startUtf8 }?.title, "第150章 新标题")
    model.filterChapters("zz-no-match")
    XCTAssertTrue(model.chapters.isEmpty)
    model.showChapter(current.startUtf8)
    XCTAssertEqual(model.chapterTarget, current.startUtf8)

    let savedJump = model.chapterJumpRevision
    model.select(.bookmarks)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    _ = try await service.toggleBookmark(book.id, at: current.startUtf8)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    XCTAssertTrue(model.notes.contains { $0.startUtf8 == current.startUtf8 })
    XCTAssertEqual(model.chapterJumpRevision, savedJump, "reopening marks does not move the directory")

    model.select(.notes)
    await model.prepare(bookID: book.id, currentChapter: current.startUtf8, library: true, preservingPosition: true)
    let mark = try await service.annotate(book.id, start: 0, end: 3)
    await model.refreshVisibleMarks()
    XCTAssertTrue(model.notes.contains { $0.id == mark.id })
    let edit = try await service.prepareAnnotation(book.id, start: 0, end: 3)
    _ = try await service.saveNote(edit, text: "更新后的笔记")
    await model.refreshVisibleMarks()
    XCTAssertEqual(model.notes.first { $0.id == mark.id }?.note, "更新后的笔记")
    XCTAssertEqual(model.chapterJumpRevision, savedJump)
  }
}

final class ReaderQueryAdapterUserDataTests: UserDataFixture {
  // S478: 每次业务查询都显式传入当前 SwiftData facts/元数据/章节修正；保留一个组合快照，不重复 Rust 查询算法。
  func testBusinessQueriesAlwaysIncludeCorrectionsMetadataPositionsAndFacts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = "第一章 月\n\n甲乙丙丁\n第二章 星\n\n再次阅读\n"
    let file = root.appendingPathComponent("book.txt")
    try text.write(to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Book")
    let formal = try store()
    let pending = try store()
    let service = AppDataService(
      core: core, sourceDefaultsSuite: "Query-\(root.lastPathComponent)",
      userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
    let before = try await service.details(bookID: book.id).metadata
    var metadata = before
    metadata.author = "作者"
    try await service.saveMetadata(base: before, edited: metadata)
    let details = try await service.details(bookID: book.id)
    XCTAssertEqual(details.metadata.author, "作者")
    try await service.correctChapter(book.id, offset: 0, title: "重命名", level: 1)
    let directChapter = try await service.chapter(bookID: book.id, offset: 0)
    XCTAssertEqual(directChapter?.title, "重命名")
    let firstSearch = try await service.search(
      book.id, query: "甲", regex: false, caseSensitive: true)
    XCTAssertEqual(try firstSearch.nextBatch().hits.first?.chapter, "重命名")
    let added = UInt64(text.prefix { $0 != "甲" }.utf8.count)
    let second = UInt64(text.distance(from: text.startIndex, to: text.range(of: "第二章")!.lowerBound))
    let secondOffset = UInt64(text.prefix(Int(second)).utf8.count)
    try await service.correctChapter(book.id, offset: added, title: "新增", level: 1)
    try await service.correctChapter(
      book.id, offset: secondOffset, title: "第二章 星", level: 1, excluded: true)
    let adjacent = try await service.adjacentChapter(book.id, offset: 0, forward: true)
    XCTAssertEqual(adjacent?.startUtf8, added)
    let effectiveFrame = try await service.frame(book.id, offset: secondOffset)
    XCTAssertEqual(effectiveFrame.paragraphs.first { $0.startUtf8 == secondOffset }?.kind, .body)
    let correctedDetails = try await service.details(bookID: book.id)
    XCTAssertEqual(correctedDetails.chapterCount, 2)
    let excludedSearch = try await service.search(
      book.id, query: "阅读", regex: false, caseSensitive: true)
    XCTAssertEqual(try excludedSearch.nextBatch().hits.first?.chapter, "新增")
    let location = try await service.location(book.id, percentage: 100)
    XCTAssertEqual(location.chapter?.title, "新增")
    try await service.savePosition(bookID: book.id, offset: added)
    let frame = try await service.frame(book.id, offset: added)
    XCTAssertEqual(frame.snapshot.book.positionUtf8, added)
    XCTAssertEqual(
      try core.querySnapshot(json: "{}").bookInfo(bookId: book.id).positionUtf8, 0,
      "Business reads never mutate a shared projection")
    try await service.restoreChapterCorrections(book.id)
    let restored = try await service.search(book.id, query: "阅读", regex: false, caseSensitive: true)
    XCTAssertEqual(try restored.nextBatch().hits.first?.chapter, "第二章 星")
    let clock = ReadingClock(bookId: book.id)
    var moment = ReadingMoment(
      monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, automaticMoving: false, automaticMilliseconds: 0, preview: false, startUtf8: added, endUtf8: added + 3)
    _ = clock.update(moment: moment)
    moment.monotonicMs = 5000
    moment.unixMs = 5000
    moment.readable = false
    try await service.saveReading(
      clock.update(moment: moment), generation: await service.statisticsPreferences().generation)
    let overview = try await service.statistics(first: 0, last: 0, book: nil)
    XCTAssertEqual(overview.books.first?.durationMs, 5000)
  }
}

actor QueryAttemptCounter {
  var count = 0
  func next() -> Int { count += 1; return count }
}
extension AppDataService {
  func queryFixture(_ boundary: (@Sendable (String, UserQueryTestPhase) async throws -> Void)?) {
    queryTestBoundary = boundary; queryCache.removeAll()
  }
  func queryFixtureCacheCount() -> Int { queryCache.count }
  func cancelSystemQueryFixture() { systemCatalog?.task?.cancel() }
}


private extension UserDataStore {
  func fixtureFailedFactPreparation(invalidate: Bool) throws -> PreparedFacts? {
    let scope = [UUID().uuidString]
    let inputVersion = version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: scope, fields: [])
    if invalidate { invalidateProjection() }
    // Feed the completed failure into the same revalidation used for shared work.
    return try preparedFactsResult(.failure(CocoaError(.fileReadNoPermission)), keys: scope, version: inputVersion)
  }
}
