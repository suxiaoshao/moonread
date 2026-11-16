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

final class LibraryFixedQueryAdapterTests: XCTestCase {
  private static let location = LibraryLocation(shelfID: "builtin")

  private func prepareFolder(at root: URL) throws -> ReaderIndex {
    let fixtureBundle = Bundle(for: Self.self)
    let resources: Bundle = fixtureBundle.url(forResource: "schema", withExtension: "sql") == nil ? .main : fixtureBundle
    let session = try DataSession(layout: .init(applicationSupport: root), bundle: resources)
    let lease = try session.activate(.unknown).0
    try session.prepareIndex(root.appending(path: "reader.sqlite3"), token: lease)
    try session.prepareUsers(lease) { nil }
    let index = ReaderIndex(session: session, lease: lease)
    try session.writeIndex(lease) { db in
      try db.execute(sql: "INSERT INTO main.library_shelves VALUES('builtin','Fixture',X'','local',1,NULL)")
    }
    return index
  }

  private func withFolder(_ exercise: (ReaderIndex) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FolderTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    try exercise(index)
  }

  private static func addFile(_ db: Database, id: String, path: String, parent: String = "", key: String? = nil,
                              name: String? = nil) throws {
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
      """, arguments: [id,path,parent,name ?? id,key == nil,key == nil ? 0 : text.utf8.count,bodyID])
  }

  private static func chapterZero(_ db: Database, key: String, title: String, level: UInt32 = 0) throws {
    let value = ChapterValue(content_key: key, offset: 0, title: title, level: level, excluded: false)
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
  func testFixedCatalogueKeepsPhysicalCopiesAndPublishedTagGroups() throws {
    try withFolder { index in
      let tagged = String(repeating: "a", count: 64), masked = String(repeating: "b", count: 64)
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "file-2", path: "Novel 2.txt", key: tagged, name: "Novel 2.txt")
        try Self.addFile(db, id: "file-3", path: "Novel 3.txt", key: masked, name: "Novel 3.txt")
        try Self.addFile(db, id: "sub", path: "sub")
        try db.execute(sql: """
          INSERT INTO main.library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id)
          VALUES('file-10','builtin','sub/Novel 10.txt','sub','Novel 10.txt',0,13,0,0,'body-file-2'),
                ('unindexed','builtin','Unknown.txt','','Unknown.txt',0,10,0,0,NULL)
          """)
        try Self.metadata(db, book: tagged, field: "tag-1", value: "\"Group 10\"")
        try Self.metadata(db, book: tagged, field: "tag-2", value: "\"Group 2\"")
        try Self.metadata(db, book: masked, field: "tag-1", value: "\"Masked group\"")
        try Self.metadata(db, book: masked, field: "author", value: "\"Formal author\"")
        try db.execute(sql: """
          INSERT INTO usr.metadata_text_candidate
          VALUES(1,'pending-catalogue-synopsis',1,?,?,'synopsis','fixture',7,'pending','Pending synopsis only')
          """, arguments: [masked,"metadata/"+masked+"/synopsis"])
        try CurrentUserRows.settleMetadata(db, book: masked)
      }
      let named = try index.catalogue(Self.location.shelfID, grouping: .name)
      XCTAssertEqual(named.entries.map(\.id), ["file-2","file-3","file-10","unindexed"])
      XCTAssertNil(named.entries.first?.displayMetadata, "Only tag fields exist; name grouping has no tag read")
      XCTAssertNil(named.groups)
      let traces = try index.session.readUsers(index.lease) { db -> [String] in
        var statements: [String] = []
        db.trace { statements.append($0.description) }
        defer { db.trace() }
        _ = try CatalogueRead.fetch(db, scope: index.lease.scope, shelfID: Self.location.shelfID, grouping: .name)
        return statements
      }
      XCTAssertTrue(traces.contains { $0.contains("library_files") })
      XCTAssertFalse(traces.contains { $0.contains("tag_candidate") || $0.contains("tag_current") })
      let grouped = try index.catalogue(Self.location.shelfID, grouping: .tags)
      let groups = try XCTUnwrap(grouped.groups).shelfTagGroups
      XCTAssertEqual(try groups.map(CatalogueRead.sectionKind), [.tag,.tag,.untagged,.unindexed])
      XCTAssertEqual(groups.map(\.tag), ["Group 2","Group 10","",""])
      XCTAssertEqual(groups.map(\.fileIDs), [["file-2","file-10"],["file-2","file-10"],["file-3"],["unindexed"]])
      XCTAssertEqual(grouped.entries.map(\.id), named.entries.map(\.id))
      XCTAssertEqual(grouped.entries.count, 4, "Physical files are counted once, even in two tag sections")
      XCTAssertEqual(grouped.entries.first?.displayMetadata?.author, "", "Readable tag-only metadata has published defaults")
      XCTAssertEqual(grouped.entries.first { $0.id == "file-3" }?.displayMetadata?.author, "",
                     "Pending synopsis suppresses both the formal author and formal tag")
      XCTAssertTrue(grouped.entries.allSatisfy { $0.metadata == nil })
    }
  }

  @MainActor func testCatalogueKeepsPublishedGroupingUntilReplacementAndRejectsLateRows() async throws {
    let (names, nameUpdates) = AsyncThrowingStream.makeStream(of: CatalogueSnapshot.self)
    let (tags, tagUpdates) = AsyncThrowingStream.makeStream(of: CatalogueSnapshot.self)
    let entered = expectation(description: "replacement is requested")
    let replacementGate = RestorationGate(entered)
    let store = CatalogueStore(updates: { _, grouping in
      if grouping == .name { return names }
      await replacementGate.wait()
      return tags
    })
    let initial = expectation(description: "initial grouping is visible")
    withObservationTracking { _ = store.snapshot } onChange: { initial.fulfill() }
    let old = Task { await store.observe(shelfID: "first", grouping: .name) { XCTFail(String(describing: $0)) } }
    defer { nameUpdates.finish(); tagUpdates.finish(); old.cancel() }
    let named = try CatalogueSnapshot(.init(entries: [], groups: nil), shelfID: "first")
    nameUpdates.yield(named)
    await fulfillment(of: [initial], timeout: 2)
    XCTAssertEqual(store.snapshot?.shelfID, "first")
    let replacement = Task { await store.observe(shelfID: "second", grouping: .tags) { XCTFail(String(describing: $0)) } }
    defer { replacement.cancel() }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertEqual(store.snapshot?.grouping, .name)
    XCTAssertEqual(store.snapshot?.shelfID, "first", "A pending parameter change keeps its last valid snapshot")

    let installed = expectation(description: "new grouping is visible")
    withObservationTracking { _ = store.snapshot } onChange: { installed.fulfill() }
    let tagged = try CatalogueSnapshot(.init(entries: [], groups: .init(shelfTagGroups: [])), shelfID: "second")
    tagUpdates.yield(tagged)
    await replacementGate.release()
    await fulfillment(of: [installed], timeout: 2)
    nameUpdates.yield(named)
    nameUpdates.finish()
    await old.value
    XCTAssertEqual(store.snapshot?.grouping, .tags)
    XCTAssertEqual(store.snapshot?.shelfID, "second", "A superseded read cannot publish over the new shelf")
  }

  func testFixedBookInformationKeepsPublishedSourceOrderAndPartialIdentity() throws {
    try withFolder { index in
      let sha = String(repeating: "a", count: 64), indexed = String(repeating: "b", count: 64)
      let raw = String(repeating: "c", count: 64)
      let target = BookTarget.record(key: .formal(sha256: sha))
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "direct", path: "a.txt", key: sha, name: "a.txt")
        try db.execute(sql: """
          INSERT INTO main.library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id)
          VALUES('copy','builtin','z-copy.txt','','z-copy.txt',0,13,100,1,'body-direct'),
                ('relinked','builtin','indexed.txt','','indexed.txt',0,13,200,0,'body-direct'),
                ('loose','builtin','loose.txt','','loose.txt',0,12,0,0,NULL)
          """)
        try db.execute(sql: "INSERT INTO main.source_identities VALUES(?,'auto',?,'utf-8',42,40)",arguments:[raw,indexed])
        try db.execute(sql: "INSERT INTO main.library_identities VALUES('relinked',?,'auto',13,200)",arguments:[raw])
        try Self.metadata(db, book: sha, field: "synopsis", value: "\"Full details\"")
        try Self.metadata(db, book: indexed, field: "author", value: "\"Index author\"")
        try Self.chapterZero(db, key: sha, title: "Manual heading", level: 1)
      }
      let unread = try index.bookInformation(target, includeRecordSource: true).resolved()
      XCTAssertEqual(unread.0?.id, "copy", "Unread copies sort by modified time; a mismatched cached body is excluded")
      XCTAssertEqual(unread.0?.needsDownload, true)
      XCTAssertEqual(try unread.1.requireIdentified().metadata.status, .unread)
      try index.session.writeUsers(index.lease) { db in
        _ = try ReadingPositionRows.recordPosition(db, book: sha, offset: 3, hint: nil,
          file: "copy", device: "fixture", now: 20, token: "read")
      }
      let read = try index.bookInformation(target, includeRecordSource: true).resolved()
      XCTAssertEqual(read.0?.id, "direct", "Copies share reading time; natural order wins over preference")
      XCTAssertEqual(read.0?.positionUtf8, 3)
      XCTAssertEqual(read.0?.byteCount, 13)
      XCTAssertNil(read.0?.metadata)
      XCTAssertNil(read.0?.chapterTitle)
      let details = try read.1.requireIdentified()
      XCTAssertEqual(details.metadata.synopsis, "Full details")
      XCTAssertEqual(details.metadata.status, .reading)
      XCTAssertEqual(details.body?.wordCount, 11)
      XCTAssertEqual(details.body?.chapterCount, 1)
      XCTAssertEqual(details.body?.currentChapter, "Manual heading")
      let explicit = try index.bookInformation(target, fileID: "copy", includeRecordSource: true).resolved()
      XCTAssertEqual(explicit.0?.id, "copy")
      XCTAssertEqual(explicit.0?.preferred, true)
      XCTAssertNil(try index.bookInformation(target).resolved().0, "Reader-origin detail does not choose a copy")
      let relinked = try index.bookInformation(.file(fileId: "relinked"), fileID: "relinked").resolved()
      let indexedDetails = try relinked.1.requireIdentified()
      XCTAssertNil(indexedDetails.body)
      XCTAssertEqual(indexedDetails.metadata.sha, indexed)
      XCTAssertEqual(indexedDetails.metadata.author, "Index author")
      XCTAssertEqual(relinked.0?.byteCount, 42)
      let loose = try index.bookInformation(.file(fileId: "loose"), fileID: "loose").resolved()
      XCTAssertEqual(loose.0?.id, "loose")
      guard case .unidentified(let id) = loose.1 else { return XCTFail("A real unindexed file retains its action envelope") }
      XCTAssertEqual(id, "loose")
      assertMissingDetails(try index.bookInformation(.file(fileId: "vanished")).resolved().1)
      XCTAssertThrowsError(try index.bookInformation(target, fileID: "vanished").resolved()) { error in
        guard case ReaderError.NotFound = error else { return XCTFail("Missing explicit source: \(error)") }
      }
    }
  }

  private func assertMissingDetails(_ result: BookDetailsResult) {
    guard case .missing = result else { return XCTFail("Expected missing identity") }
  }

  func testFixedBookInformationKeepsChosenMetadataAndFormalBarrier() throws {
    try withFolder { index in
      let sha = String(repeating: "a", count: 64)
      let target = BookTarget.cached(bookId: "body-direct")
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "direct", path: "a.txt", key: sha)
        try Self.metadata(db, book: sha, field: "author", value: "\"Formal author\"")
        try Self.metadata(db, book: sha, field: "tag-1", value: "\"Formal tag\"")
        try db.execute(sql: """
          INSERT INTO usr.metadata_text_candidate
          VALUES(1,'detail-pending-synopsis',1,?,?,'synopsis','fixture',7,'pending','Pending synopsis')
          """, arguments: [sha,"metadata/"+sha+"/synopsis"])
        try CurrentUserRows.settleMetadata(db, book: sha)
      }
      let shown = try index.bookInformation(target).resolved().1.requireIdentified()
      XCTAssertEqual(shown.metadata.synopsis, "Pending synopsis")
      XCTAssertEqual(shown.metadata.author, "")
      XCTAssertTrue(shown.metadata.tags.isEmpty)
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: """
          INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
              raw_format,raw_bytes,digest,reason,completeness)
          VALUES(0,'fixture','formal','metadata_text_candidate','future',?,?,'fixture',X'00','opaque','future','complete')
          """, arguments: [sha,"metadata/"+sha+"/author"])
        try CurrentUserRows.settleMetadata(db, book: sha)
      }
      let barrier = try index.bookInformation(target)
      guard case .incompatibleMetadata = barrier else { return XCTFail("Formal isolation also blocks a readable pending object") }
      XCTAssertThrowsError(try barrier.resolved()) { XCTAssertTrue($0 is UserSyncCompatibilityError) }
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE record_id='future'")
        try CurrentUserRows.settleMetadata(db, book: sha)
      }
      XCTAssertEqual(try index.bookInformation(target).resolved().1.requireIdentified().metadata.synopsis, "Pending synopsis")
    }
  }

  @MainActor func testBookInformationObservationSurvivesFormalIsolation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "InformationTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    let sha = String(repeating: "a", count: 64)
    try index.session.writeUsers(index.lease) { db in
      try Self.addFile(db, id: "direct", path: "a.txt", key: sha)
      try Self.metadata(db, book: sha, field: "author", value: "\"Formal author\"")
    }
    let service = AppDataService(core: index)
    let updates = try await service.bookInformationUpdates(.file(fileId: "direct"), fileID: "direct", includeRecordSource: true)
    let initial = expectation(description: "detail snapshot")
    let blocked = expectation(description: "formal isolation result")
    let restored = expectation(description: "repaired snapshot from the same observation")
    let observing = Task {
      do {
        var iterator = updates.makeAsyncIterator()
        let firstValue = try await iterator.next()
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(try first.resolved().1.requireIdentified().metadata.author, "Formal author")
        initial.fulfill()
        let isolatedValue = try await iterator.next()
        let isolated = try XCTUnwrap(isolatedValue)
        guard case .incompatibleMetadata = isolated else { return XCTFail("Formal isolation must hide prior editable data") }
        blocked.fulfill()
        let recoveredValue = try await iterator.next()
        let recovered = try XCTUnwrap(recoveredValue)
        XCTAssertEqual(try recovered.resolved().1.requireIdentified().metadata.author, "Restored author")
        restored.fulfill()
      } catch { XCTFail(String(describing: error)) }
    }
    defer { observing.cancel() }
    await fulfillment(of: [initial], timeout: 2)
    try index.session.writeUsers(index.lease) { db in
      try db.execute(sql: """
        INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
            raw_format,raw_bytes,digest,reason,completeness)
        VALUES(0,'fixture','formal','metadata_text_candidate','future',?,?,'fixture',X'00','opaque','future','complete')
        """, arguments: [sha,"metadata/"+sha+"/author"])
      try CurrentUserRows.settleMetadata(db, book: sha)
    }
    await fulfillment(of: [blocked], timeout: 2)
    try index.session.writeUsers(index.lease) { db in
      try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE record_id='future'")
      try Self.metadata(db, book: sha, field: "author", value: "\"Restored author\"", now: 2)
    }
    await fulfillment(of: [restored], timeout: 2)
  }


  func testFixedSearchPreservesCopyRankingUnknownsAndAIBarrier() throws {
    try withFolder { index in
      let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "root", path: "fixture", name: "Fixture")
        try Self.addFile(db, id: "nested", path: "fixture/sub", parent: "fixture", name: "Fixture Sub")
        try Self.addFile(db, id: "a", path: "fiction.txt", key: a, name: "Fixture 2.txt")
        try Self.addFile(db, id: "b", path: "fixture/sub/b.txt", parent: "fixture/sub", key: b, name: "远航.txt")
        try Self.addFile(db, id: "a-copy", path: "fixture/sub/a.txt", parent: "fixture/sub", name: "Fixture 10.txt")
        try Self.addFile(db, id: "unidentified", path: "unidentified.txt", name: "Fixture 1.txt")
        try db.execute(sql: """
          UPDATE main.library_files SET directory=0,book_id='body-a' WHERE id='a-copy';
          UPDATE main.library_files SET directory=0 WHERE id='unidentified'
          """)
        try Self.metadata(db, book: a, field: "author", value: "\"Synthetic Writer\"")
        try Self.metadata(db, book: a, field: "tag-1", value: "\"Group 2\"")
        try Self.metadata(db, book: a, field: "tag-2", value: "\"Group 10\"")
        try Self.metadata(db, book: b, field: "synopsis", value: "\"Unique synopsis token\"")
        _ = try ReadingPositionRows.recordPosition(db, book: a, offset: 3, hint: nil,
          file: nil, device: "fixture", now: 10, token: "read")
        // A restored legacy position can have a nonzero offset and a zero clock.
        try ReadingPositionRows.mergeBackup(db, book: b, incoming: .init(
          value: .init(content_key: b, offset: 4, source_hint: nil), updated: 0, token: "legacy", device: "fixture"))
      }
      let filtered = BookSearchConfiguration(root: .init(kind: .group(.all, [
        .init(kind: .rule(.status([.reading]))),
        .init(kind: .rule(.tag(.all, [.text("Group 10")]))),
        .init(kind: .rule(.author(["Synthetic Writer"])))
      ])), sorts: [.init(field: .author)])
      let results = try index.searchCatalogue(.all, spec: .init(profile: .library, query: "fixture", configuration: filtered))
      XCTAssertEqual(results.entries.map(\.id), ["a", "a-copy"])
      XCTAssertEqual(results.unknownCount, 1)
      XCTAssertTrue(results.entries.allSatisfy { $0.metadata == nil && $0.displayMetadata?.author == "Synthetic Writer" })
      let folders = try index.searchCatalogue(.all, spec: .init(profile: .library, query: "fixture")).entries.filter(\.directory)
      XCTAssertEqual(folders.map(\.id), ["root", "nested"])
      XCTAssertEqual(folders.compactMap { $0.folderRow?.childBookCount }, [2, 2])
      XCTAssertEqual(folders.map { $0.folderRow?.coverPreviews.count }, [2, 2])
      XCTAssertEqual(try index.searchCatalogue(.all, spec: .init(profile: .library, query: "yuanhang")).entries.map(\.id), ["b"])
      let unread = try index.searchCatalogue(.all, spec: .init(profile: .library, query: "yuanhang", status: "unread"))
      XCTAssertEqual(unread.entries.map(\.id), ["b"])
      XCTAssertTrue(try index.searchCatalogue(.all, spec: .init(profile: .library, query: "yuanhang", status: "reading")).entries.isEmpty)
      XCTAssertTrue(try index.searchCatalogue(.all, spec: .init(profile: .library, query: "synopsis token")).entries.isEmpty)
      let ai = LibraryQueryRules.SearchSpec(profile: .ai, query: "synopsis token")
      let hits = try index.searchCatalogue(.all, spec: ai).entries
      XCTAssertEqual(hits.map(\.id), ["b"])
      XCTAssertEqual(hits.first?.metadata?.synopsis, "Unique synopsis token")
      XCTAssertEqual(hits.first?.positionUtf8, 4, "The position itself remains usable")
      XCTAssertEqual(hits.first?.metadata?.status, .unread)
      let root = try index.aiCatalogue(.shelf(shelfId: "builtin", parentPath: "", recursive: false),
        folder: .init(shelfID: "builtin"), sort: .name)
      XCTAssertEqual(root.map(\.id), ["root", "unidentified", "a"])
      XCTAssertEqual(root.last?.metadata?.author, "Synthetic Writer")
      let picker = try index.aiCatalogue(.shelf(shelfId: "builtin", parentPath: "", recursive: true), folder: nil, sort: .name)
      XCTAssertEqual(picker.map(\.id), ["unidentified", "a", "a-copy", "b"])
      let options = try index.session.readUsers(index.lease) { db in
        try LibrarySearchRead.options(db, scope: index.lease.scope, shelfID: "builtin").bookFilterOptions
      }
      XCTAssertEqual(options.authors, ["Synthetic Writer"])
      XCTAssertEqual(options.tags, ["Group 10", "Group 2"])

      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: """
          INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,
            raw_format,raw_bytes,digest,reason,completeness)
          VALUES(0,'fixture','formal','metadata_text_candidate','future',?,?,'fixture',X'00','opaque','future','complete')
          """, arguments: [b,"metadata/\(b)/synopsis"])
        try CurrentUserRows.settleMetadata(db, book: b)
      }
      XCTAssertThrowsError(try index.searchCatalogue(.all, spec: ai)) { XCTAssertTrue($0 is UserSyncCompatibilityError) }
      XCTAssertEqual(try index.searchCatalogue(.all, spec: .init(profile: .library, query: "yuanhang")).entries.map(\.id), ["b"])
      try index.session.readUsers(index.lease) { db in
        try LibrarySearchRead.requireAIReadable(db, scope: index.lease.scope,
          catalogue: .shelf(shelfId: "builtin", parentPath: "", recursive: false))
      }
    }
  }

  @MainActor func testSearchAndOptionsObserveAnAttachedMetadataCommit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SearchTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    // Observe through the production data session. No main table commit
    // accompanies the author edit, and no manual invalidation is sent.
    let book = String(repeating: "a", count: 64)
    try index.session.writeUsers(index.lease) { try Self.addFile($0, id: "a", path: "a.txt", key: book) }
    let spec = LibraryQueryRules.SearchSpec(profile: .library, query: "Fresh Writer")
    let searchReady = expectation(description: "Search observation registered")
    let optionsReady = expectation(description: "Initial filter options")
    let searchChanged = expectation(description: "Attached write refreshes search")
    let optionsChanged = expectation(description: "Attached write refreshes filter options")
    let invalidations = try index.searchInvalidations(spec)
    let options = try index.metadataOptionsUpdates(shelfID: "builtin")
    let searchTask = Task {
      var changes = invalidations.makeAsyncIterator()
      guard try await changes.next() != nil else { return }
      XCTAssertTrue(try index.searchCatalogue(.all, spec: spec).entries.isEmpty)
      searchReady.fulfill()
      guard try await changes.next() != nil else { return }
      XCTAssertEqual(try index.searchCatalogue(.all, spec: spec).entries.map(\.id), ["a"])
      searchChanged.fulfill()
    }
    let optionsTask = Task {
      var changes = options.makeAsyncIterator()
      guard let first = try await changes.next() else { return }
      XCTAssertTrue(first.authors.isEmpty)
      optionsReady.fulfill()
      guard let updated = try await changes.next() else { return }
      XCTAssertEqual(updated.authors, ["Fresh Writer"])
      optionsChanged.fulfill()
    }
    defer { searchTask.cancel(); optionsTask.cancel() }
    await fulfillment(of: [searchReady,optionsReady], timeout: 2)
    try index.session.writeUsers(index.lease) { try Self.metadata($0, book: book, field: "author", value: "\"Fresh Writer\"") }
    await fulfillment(of: [searchChanged,optionsChanged], timeout: 2)
  }


  func testSystemCatalogueAndPointSourcesShareThePreferredCopy() throws {
    try withFolder { index in
      let sha = String(repeating: "a", count: 64), scope = index.lease.scope
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "a", path: "a.txt", key: sha, name: "Fixture 2.txt")
        try Self.addFile(db, id: "z", path: "z.txt", name: "Fixture 10.txt")
        try Self.addFile(db, id: "unidentified", path: "unidentified.txt")
        try db.execute(sql: """
          INSERT INTO main.library_shelves VALUES('other','Other',X'','local',0,'not-connected');
          UPDATE main.library_files SET directory=0 WHERE id='unidentified';
          UPDATE main.library_files SET directory=0,book_id='body-a',shelf_id='other',needs_download=1 WHERE id='z';
          """)
        _ = try ReadingPositionRows.recordPosition(db, book: sha, offset: 3, hint: nil, file: "z",
          device: "fixture", now: 10, token: "position")
        try Self.metadata(db, book: sha, field: "author", value: "\"Author\"")
        try Self.metadata(db, book: sha, field: "tag-1", value: "\"Tag\"")
        try Self.chapterZero(db, key: sha, title: "Changed chapter")
      }
      let input = try index.session.readUsers(index.lease) { try SystemReadingRead.catalogue($0, scope: scope) }
      let cards = SystemReadingRead.project(input).systemBookCatalogue
      XCTAssertEqual(cards.count, 1)
      let first = try XCTUnwrap(cards.first)
      XCTAssertEqual(first.title, "Fixture 10")
      XCTAssertEqual(first.tags, ["Tag"])
      XCTAssertEqual(first.author, "Author")
      XCTAssertEqual(first.sourceShelfIDs, ["builtin","other"])
      XCTAssertEqual(first.sourceCount, "2")
      XCTAssertEqual(first.recentRank, 0)
      XCTAssertEqual(first.chapterTitle, "Changed chapter")
      XCTAssertNotNil(first.percentage)
      XCTAssertFalse(first.reconnectRequired, "At least one copy is connected")
      XCTAssertTrue(first.needsDownload, "The representative copy keeps its own state")
      let sources = try index.session.readUsers(index.lease) { try SystemReadingRead.sources($0, scope: scope, sha: sha) }
      XCTAssertEqual(sources.map { $0.entry.id }, ["z","a"])
      XCTAssertEqual(sources.map(\.reconnect), [true,false])
    }
  }

  func testSystemCommitStampsRespectTheTwoPublicationDomains() throws {
    try withFolder { index in
      let sha = String(repeating: "a", count: 64)
      try index.session.writeUsers(index.lease) { try Self.addFile($0, id: "x", path: "x.txt", key: sha) }
      let books = try SystemReadingRead.changes(index, statistics: false)
      let stats = try SystemReadingRead.changes(index, statistics: true)
      defer { withExtendedLifetime((books.events, stats.events)) {} }
      try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: "INSERT INTO usr.reading_day VALUES(?,1,?,1,1000,1100,1100)",
                       arguments: [sha,DataIdentity.unsigned(100)])
      }
      XCTAssertEqual(books.commits.value, 0)
      XCTAssertEqual(stats.commits.value, 1)
      try index.session.writeUsers(index.lease) { try Self.metadata($0, book: sha, field: "author", value: "\"Updated\"") }
      XCTAssertEqual(books.commits.value, 1)
      XCTAssertEqual(stats.commits.value, 1)
      XCTAssertThrowsError(try index.session.writeUsers(index.lease) { db in
        try db.execute(sql: "DELETE FROM usr.reading_day")
        throw ReaderError.InvalidSettings
      })
      XCTAssertEqual(stats.commits.value, 1, "Rollback is not publication input")
    }
  }

  @MainActor func testPublicationReadDoesNotHoldLifecycleLockForOpening() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SystemReader-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    let sha = String(repeating: "a", count: 64), scope = index.lease.scope
    try index.session.writeUsers(index.lease) { try Self.addFile($0, id: "x", path: "x.txt", key: sha) }
    let entered = expectation(description: "Publication holds its own read transaction")
    let opened = expectation(description: "Target lookup returns ahead of publisher")
    let release = DispatchSemaphore(value: 0)
    let publication = Task.detached {
      try await index.session.readUsersForPublication(index.lease) { db in
        _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.reading_current")
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else { throw ReaderError.InvalidSettings }
      }
    }
    await fulfillment(of: [entered], timeout: 2)
    let pointRead = Task.detached {
      let result = try index.session.readUsers(index.lease) { try SystemReadingRead.sources($0, scope: scope, sha: sha) }
      XCTAssertEqual(result.first?.entry.id, "x")
      opened.fulfill()
    }
    await fulfillment(of: [opened], timeout: 2)
    release.signal()
    try await pointRead.value
    try await publication.value
  }


  @MainActor func testSystemBatchGateDefersBooksWithoutBlockingStatisticsOrOpening() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "SystemBatch-\(UUID())")
    let suite = "SystemBatch.\(UUID())"
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    let service = AppDataService(core: index, libraryDirectory: root, sourceDefaultsSuite: suite)
    let sha = String(repeating: "a", count: 64)
    try index.session.writeUsers(index.lease) { try Self.addFile($0, id: "file", path: "file.txt", key: sha) }
    let output = SystemReadingSnapshotFile(directory: root.appending(path: "System"))
    await service.installSystemReadingFixture(output)
    let outer = await service.beginSystemReadingBatch()
    let nested = await service.beginSystemReadingBatch()
    await service.scheduleSystemReadingCatalog(immediate: true)
    await service.scheduleSystemWidgetStatistics(immediate: true)
    await service.waitForStatisticsFixture()
    let direct = try await service.resolveSystemReadingBook(.init(sha: sha))
    XCTAssertEqual(direct.id, "file")
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.path))
    let stats = try output.readStatistics()

    await service.endSystemReadingBatch(nested, committed: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.path))
    await service.endSystemReadingBatch(outer, committed: false)
    await service.waitForSystemReadingCatalog()
    let books = try output.read()
    XCTAssertEqual(books.books.map(\.id), [SystemReadingLink.bookIDPrefix + sha])
    XCTAssertEqual(try output.readStatistics(), stats)

    await service.resetSystemReadingCatalog()
    XCTAssertTrue(try output.read().books.isEmpty)
    XCTAssertNil(try output.readStatistics().statistics)
    XCTAssertNotEqual(try output.readStatistics().storeScope, stats.storeScope)
  }
}

private extension AppDataService {
  func installSystemReadingFixture(_ file: SystemReadingSnapshotFile) { systemCatalog = .init(file: file) }
  func waitForStatisticsFixture() async { await systemCatalog?[.statistics].task?.value }

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

  @MainActor func testLegacyPreparedFactsSeparateDatesAndRecordSelection() async throws {
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
