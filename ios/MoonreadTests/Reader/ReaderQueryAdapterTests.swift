import MoonreadCoreBindings
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
    let base = try await f.service.details(sha: identity.contentSha256).metadata
    var edited = base
    edited.author = "原创作者"
    edited.tags = ["星港"]
    try await f.service.saveMetadata(base: base, edited: edited)
    let recent = try await f.service.recentLibrary()
    XCTAssertEqual(recent.map(\.readingKey), [identity.contentSha256])
    let entry = try XCTUnwrap(recent.first)
    XCTAssertNil(entry.bookId)
    let fraction = Double(identity.utf8Bytes / 2) / Double(identity.utf8Bytes)
    XCTAssertEqual(entry.libraryProgress, fraction.formatted(.percent.precision(.fractionLength(1))))
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

  func testReadingProgressAtZeroAndEnd() {
    XCTAssertEqual(ReadingProgress.fraction(0, of: 0), 0)
    XCTAssertEqual(ReadingProgress.fraction(0, of: 9), 0)
    XCTAssertEqual(ReadingProgress.percentage(9, of: 9), 100)
  }

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
    old.cancel() // SwiftUI cancels the old .task(id:) before requesting new parameters.
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
        try Self.metadata(db, book: b, field: "tag-1", value: "\"Group 2\"")
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
      let authorHits = try index.searchCatalogue(.all, spec: .init(profile: .library, query: "writer"))
      XCTAssertEqual(authorHits.entries.map(\.id), ["a", "a-copy"])
      let author = "Synthetic Writer"
      XCTAssertEqual(authorHits.matches, [
        "a": .author(author, author.range(of: "Writer")), "a-copy": .author(author, author.range(of: "Writer")),
      ])
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
      XCTAssertEqual(options.tags.map(\.name), ["Group 10", "Group 2"])
      XCTAssertEqual(options.tags.map(\.bookCount), [1, 2])

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

  @MainActor func testUntaggedBookCountMatchesTheUnscopedFilter() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "UntaggedTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let index = try prepareFolder(at: root)
    defer { try? index.session.close() }
    let tagged = String(repeating: "a", count: 64)
    let untagged = String(repeating: "b", count: 64)
    try index.session.writeUsers(index.lease) { db in
      try Self.addFile(db, id: "tagged", path: "tagged.txt", key: tagged)
      try Self.addFile(db, id: "untagged", path: "untagged.txt", key: untagged)
      try Self.addFile(db, id: "copy", path: "copy.txt")
      try Self.addFile(db, id: "unknown", path: "unknown.txt")
      try db.execute(sql: """
        UPDATE main.library_files SET directory=0,book_id='body-untagged' WHERE id='copy';
        UPDATE main.library_files SET directory=0 WHERE id='unknown'
        """)
      try Self.metadata(db, book: tagged, field: "tag-example", value: UserSyncJSON.encode("Example"))
    }
    let service = AppDataService(core: index)
    let rule = BookSearchNode(kind: .rule(.untagged))
    let configuration = BookSearchConfiguration(root: .init(kind: .group(.all, [rule])))
    let outcome = try await service.searchLibrary(query: "", configuration: configuration)
    let count = try await service.untaggedBookCount()
    XCTAssertEqual(Set(outcome.entries.map(\.id)), ["untagged", "copy"])
    XCTAssertEqual(outcome.unknownCount, 1)
    XCTAssertEqual(count, outcome.entries.count)
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
      XCTAssertEqual(try XCTUnwrap(first.percentage), 3.0 / 13 * 100, accuracy: 0.0001)
      XCTAssertFalse(first.reconnectRequired, "At least one copy is connected")
      XCTAssertTrue(first.needsDownload, "The representative copy keeps its own state")
      let sources = try index.session.readUsers(index.lease) { try SystemReadingRead.sources($0, scope: scope, sha: sha) }
      XCTAssertEqual(sources.map { $0.entry.id }, ["z","a"])
      XCTAssertEqual(sources.map(\.reconnect), [true,false])
    }
  }

  func testManualChapterAndCoverageShareStoredScalarCoordinates() throws {
    try withFolder { index in
      let sha = String(repeating: "a", count: 64)
      let texts = ["1234567\n", "甲 \n \u{00a0}e", "\u{0301}🦉\u{3000}\n尾"]
      let titleOffset = UInt64(texts[0].utf8.count + "甲 \n".utf8.count)
      let textLength = UInt64(texts.joined().utf8.count)
      let tailOffset = textLength - UInt64("尾".utf8.count)
      try index.session.writeUsers(index.lease) { db in
        try Self.addFile(db, id: "scalars", path: "scalars.txt", key: sha)
        try db.execute(sql: "DELETE FROM main.chunks WHERE book_id='body-scalars'")
        try db.execute(sql: """
          UPDATE main.books SET byte_count=?,chunk_count=?,projection_end=? WHERE id='body-scalars'
          """, arguments: [textLength, texts.count, textLength])
        let counts = [0, 7, 9, 12]
        var start = 0
        for (i, text) in texts.enumerated() {
          let end = start + text.utf8.count
          try db.execute(sql: "INSERT INTO main.chunks VALUES('body-scalars',?,?,?,?,?,?)",
                         arguments: [i, start, end, text, counts[i], counts[i + 1]])
          start = end
        }
      }
      try index.session.readUsers(index.lease) { db in
        let body = try ReaderIndex.body(db, id: "body-scalars", scope: index.lease.scope.key)
        let counts = try ReaderIndex.chapterCorrectionCounts(db, body: body, offset: titleOffset)
        XCTAssertEqual(counts.start, 8)
        XCTAssertEqual(counts.body, 11)
        let chapter = SourceSpan(startUtf8: counts.body, endUtf8: 12)
        let partial = try ChapterCoverageRead.chunks(db, body: body,
            ranges: [.init(startUtf8: titleOffset, endUtf8: tailOffset + 1)])
        XCTAssertEqual(try chapterCoverageCounts(chunks: partial, chapters: [chapter]), [0])
        let complete = try ChapterCoverageRead.chunks(db, body: body,
            ranges: [.init(startUtf8: titleOffset, endUtf8: textLength)])
        XCTAssertEqual(try chapterCoverageCounts(chunks: complete, chapters: [chapter]), [1])
      }
      let location = try index.readerLocation("body-scalars",
        percentage: Double(tailOffset + 1) / Double(textLength) * 100)
      XCTAssertEqual(location.offsetUtf8, tailOffset, "Jump aligns to the start of a UTF-8 scalar")
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
  @MainActor func testSearchUsesEffectiveChapterHeadings() async throws {
    let (root, service, core, suite) = try introductionFixture()
    defer {
      try? core.session.close()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let firstHeading = "Chapter 1\n"
    let firstSection = firstHeading + "marker one\n"
    let secondSection = "Chapter 2\nmarker two\n"
    let source = root.appendingPathComponent("search-fixture.txt")
    try (firstSection + secondSection + "Manual section\nmarker three\n").write(to: source, atomically: true, encoding: .utf8)
    let book = try importBookFixture(core, filePath: source.path, title: "Search fixture")
    try await service.correctChapter(book.id, offset: 0, title: "Renamed", level: 1)
    try await service.correctChapter(book.id, offset: UInt64(firstSection.utf8.count), title: "Chapter 2", level: 1, excluded: true)
    try await service.correctChapter(book.id, offset: UInt64((firstSection + secondSection).utf8.count), title: "Manual", level: 1)

    let job = try await service.search(book.id, query: "marker", regex: false, caseSensitive: true,
      range: .init(startUtf8: UInt64(firstHeading.utf8.count), endUtf8: book.byteCount))
    var hits: [SearchHit] = []
    while true {
      let batch = try job.nextBatch()
      hits.append(contentsOf: batch.hits)
      if batch.done { break }
    }
    XCTAssertEqual(hits.map(\.chapter), ["Renamed", "Renamed", "Manual"])
  }

  @MainActor func testDirectoryCompletesWithPendingImportInFolderCover() async throws {
    let (root, service, core, _, _, _, suite) = try singleBookFixture()
    defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    try core.scanLibraryShelf(shelfId: "builtin", items: [
      .init(relativePath: "folder", directory: true, size: 0, modified: 0, needsDownload: false),
      .init(relativePath: "folder/fixture.txt", directory: false, size: 10, modified: 0, needsDownload: false)
    ])
    let file = try XCTUnwrap(core.sourceFiles(shelfId: "builtin").first { !$0.directory })
    let job = try core.createImport(title: "Synthetic")
    let key = ReadingKey.pending(bookId: job.bookId())
    try core.linkLibraryFile(fileId: file.id, bookId: job.bookId())
    let location = LibraryLocation(shelfID: "builtin")
    let entries = try await service.libraryEntries(location)
    XCTAssertEqual(entries.first?.folderRow?.childBookCount, 1)
    XCTAssertEqual(entries.first?.folderRow?.coverPreviews.map(\.readingKey), [key])
    let nested = try await service.libraryEntries(.init(shelfID: "builtin", path: "folder"))
    XCTAssertEqual(nested.first?.readingIdentity, key)
    XCTAssertEqual(try core.importStatus(bookId: job.bookId()).text.readingKey, key)
  }

  @MainActor func testMetadataEditNotificationRoutesOnlyRelevantVisibleInputs() async throws {
    let (root, service, _, _, first, second, suite) = try singleBookFixture()
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

  @MainActor func testOpeningIsPersistedSeparatelyWithoutMovingReadingPosition() async throws {
    let (root, service, core, _, book, _, suite) = try singleBookFixture()
    defer {
      try? core.session.close()
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let before = try await service.snapshot(book.id)
    try await service.recordBookOpened(book.id, at: 12345)
    let opened = try core.session.readUsers(core.lease) {
      try Int64.fetchOne($0, sql: "SELECT opened_ms FROM usr.opened_candidate WHERE book_key=?", arguments: [book.fixtureSHA256])
    }
    XCTAssertEqual(opened, 12345)
    let after = try await service.snapshot(book.id)
    XCTAssertEqual(before.book.positionUtf8, after.book.positionUtf8)
    XCTAssertEqual(before.hasStarted, after.hasStarted)
    XCTAssertNil(try UserRowsFixture(index: core).positionToken(book.fixtureSHA256))
  }
}

actor QueryAttemptCounter {
  var count = 0
  func next() -> Int { count += 1; return count }
}
