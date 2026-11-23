import Foundation
import GRDB
import SwiftData
import Synchronization
import Testing
@testable import Moonread

struct DataV2MigrationTests {
    private func sandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DataV2Tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func scope(_ name: String, _ environment: DataScope.Environment = .production) throws -> DataScope {
        try .confirmed(container: "test.invalid", environment: environment, recordName: name)
    }

    @Test func rustImportStateIsConsumedAcrossUniFFI() throws {
        let state = try beginTextImport(encoding: "UTF-8", mode: .index, publishedChunkCount: 0)
        let alias = state
        let first = try advanceTextImport(previous: state, bytes: Data("Chapter 1\r".utf8), eof: false, replay: [])
        #expect(first.identity == nil)
        #expect(throws: ReaderError.InvalidSettings) {
            try advanceTextImport(previous: alias, bytes: Data(), eof: false, replay: [])
        }
        let next = try #require(first.next)
        let end = try advanceTextImport(previous: next, bytes: Data("\n\r\n正文。".utf8), eof: true, replay: [])
        #expect(end.next == nil)
        #expect(end.chunks.map { $0.chunk.text }.joined() == "Chapter 1\n\n正文。")
        #expect(end.chapters.map(\.title) == ["Chapter 1"])
        #expect(end.blankUpdates.first?.startUtf8 == 10 && end.blankUpdates.first?.endUtf8 == 11)
        #expect(end.identity?.utf8Bytes == UInt64("Chapter 1\n\n正文。".utf8.count))
        #expect(throws: ReaderError.InvalidSettings) {
            try advanceTextImport(previous: next, bytes: Data(), eof: true, replay: [])
        }
    }

    @Test func copiesReleasedIndexAndLeavesOriginalUntouched() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let oldURL = root.appending(path: "reader.sqlite3")
        let old = try DatabaseQueue(path: oldURL.path)
        try await old.write { db in
            try db.execute(sql: DataV2Schema.sql("schema"))
            try db.execute(sql: """
                INSERT INTO books(id,title,content_sha256,encoding,byte_count,chunk_count,projection_revision,projection_end)
                VALUES ('reading','Offline','published-sha','UTF-8',4,1,8,4),('task','Pending','pending:task','UTF-8',0,0,0,0);
                INSERT INTO chunks VALUES('reading',0,0,4,'a界',0,2);
                INSERT INTO reading_blanks VALUES('reading',0,1);
                INSERT INTO import_chapters VALUES('reading',0,'Start',1,0,2);
                INSERT INTO source_imports VALUES('raw','UTF-8','reading');
                INSERT INTO import_jobs(book_id,phase,generation,library_file_id) VALUES('task','paused',17,'file');
                INSERT INTO library_shelves VALUES('external','Fixture',X'01020300','local',0,NULL);
                INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id,decoding)
                VALUES ('file','external','folder/a.txt','folder','a.txt',0,4,44,1,'reading','UTF-8');
                """)
        }
        try old.close()

        let owner = try DataSession(layout: layout)
        let (lease, _) = try await owner.activate(.unknown)
        #expect(try owner.importedLegacyIndexFiles(lease).isEmpty)
        try await owner.importLegacyIndex(oldURL, token: lease)
        #expect(try owner.importedLegacyIndexFiles(lease).isEmpty)
        let result = try await owner.read(lease) { db in
            let text = try String.fetchOne(db, sql: "SELECT text FROM main.chunks WHERE book_id='reading'")
            let bookmark = try Data.fetchOne(db, sql: "SELECT bookmark FROM main.library_shelves")
            let job = try Row.fetchOne(db, sql: "SELECT purpose,generation,pending_owner FROM main.import_jobs")
            let work = try Int.fetchOne(db, sql: "SELECT count(*) FROM main.source_decoding_migration")
            return (text, bookmark, job?["purpose"] as String?, job?["generation"] as Int?, job?["pending_owner"] as String?, work)
        }
        #expect(result.0 == "a界")
        #expect(result.1 == Data([1,2,3,0]))
        #expect(result.2 == "reading" && result.3 == 17 && result.4 == "local")
        #expect(result.5 == 0)
        try owner.prepareIndex(oldURL, token: lease)
        let obsolete = try owner.importedLegacyIndexFiles(lease)
        #expect(obsolete.contains { $0.url.path == oldURL.standardizedFileURL.path })
        await #expect(throws: DataV2Error.migrationAlreadyComplete) { try await owner.importLegacyIndex(oldURL, token: lease) }
        try await owner.close()
        let check = try DatabaseQueue(path: oldURL.path)
        let oldVersion = try await check.read { try DataV2Schema.version($0, in: "main") }
        #expect(oldVersion == 20)
        try check.close()
    }

    @Test func upgradesReleasedPausedImportAndCleansDefaultsAfterInterruptedCommit() async throws {
        let root = try sandbox()
        let suite = "PausedImportMigration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let oldURL = root.appending(path: "reader.sqlite3")
        let old = try DatabaseQueue(path: oldURL.path)
        try await old.write { db in
            try db.execute(sql: DataV2Schema.sql("schema"))
            try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading'")
            try db.execute(sql: DataV2Schema.sql("full_index"))
            try db.execute(sql: DataV2Schema.sql("source_decoding_migration"))
            try db.execute(sql: """
                PRAGMA user_version=23;
                INSERT INTO books(id,title,content_sha256,encoding) VALUES('task','Fixture','pending:task','UTF-8');
                INSERT INTO import_jobs(book_id,phase,generation,library_file_id) VALUES('task','paused',17,'file');
                INSERT INTO library_shelves VALUES('external','Fixture',X'AB','local',0,NULL);
                INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,book_id,decoding)
                VALUES ('file','external','fixture.txt','','fixture.txt',0,4,44,0,'task','auto');
                """)
        }
        try old.close()

        let sourceKey = IndexImport.legacySourcePrefix + "task"
        let draftKey = IndexImport.legacyDraftPrefix + "file"
        let source = ImportSource(rootBookmark: Data([0xAB]), relativePath: "fixture.txt", fileID: "file")
        defaults.set(try JSONEncoder().encode(source), forKey: sourceKey)
        defaults.set("task", forKey: draftKey)

        let layout = DataLayout(applicationSupport: root)
        let first = try DataSession(layout: layout)
        let (firstLease, _) = try first.activate(.unknown)
        try first.prepareIndex(oldURL, token: firstLease, legacyDefaults: defaults.persistentDomain(forName: suite) ?? [:])
        try first.close() // The transaction committed, but the process did not clean Defaults.
        #expect(defaults.data(forKey: sourceKey) != nil)
        #expect(defaults.string(forKey: draftKey) == "task")

        let second = try DataSession(layout: layout)
        defer { try? second.close() }
        let (lease, _) = try second.activate(.unknown)
        try second.prepareIndex(oldURL, token: lease, legacyDefaults: defaults.persistentDomain(forName: suite) ?? [:])
        let index = ReaderIndex(session: second, lease: lease)
        AppDataService.removeLegacyLocalDefaults(defaults, domain: suite)
        #expect(try index.importStatus(bookId: "task").phase == .paused)
        #expect(try index.importSource("task") == source)
        #expect(try index.fileImportDraft("file") == "task")
        let counts = try index.read { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM main.import_jobs"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM main.import_origin"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM main.file_import_draft"))
        }
        #expect(counts.0 == 1 && counts.1 == 1 && counts.2 == 1)
        #expect(defaults.object(forKey: sourceKey) == nil && defaults.object(forKey: draftKey) == nil)
    }

    @Test func copiesKnownVersion23WorkAndRejectsFutureTarget() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let oldURL = root.appending(path: "reader.sqlite3")
        let old = try DatabaseQueue(path: oldURL.path)
        try await old.write { db in
            try db.execute(sql: DataV2Schema.sql("schema"))
            try db.execute(sql: "ALTER TABLE import_jobs ADD COLUMN purpose TEXT NOT NULL DEFAULT 'reading'")
            try db.execute(sql: DataV2Schema.sql("full_index"))
            try db.execute(sql: DataV2Schema.sql("source_decoding_migration"))
            try db.execute(sql: """
                PRAGMA user_version=23;
                INSERT INTO source_identities VALUES('raw','Big5','sha','Big5',99,77);
                INSERT INTO library_identities VALUES('future-file','raw','Big5',99,17);
                INSERT INTO source_decoding_migration VALUES('old-file','s','manual.txt',99,17,'Big5','raw'),
                  ('unresolved','s','offline.txt',99,17,'Big5',NULL);
                INSERT INTO library_shelves VALUES('s','Fixture',X'AB','local',0,NULL);
                INSERT INTO library_files(id,shelf_id,relative_path,parent_path,name,directory,size,modified,needs_download,decoding)
                VALUES ('already-consumed','s','other.txt','','other.txt',0,7,18,1,'Big5');
                """)
        }
        try old.close()
        let owner = try DataSession(layout: layout)
        let (lease, _) = try await owner.activate(.signedOut)
        try await owner.importLegacyIndex(oldURL, token: lease)
        let copied = try await owner.read(lease) { db in
            (try String.fetchAll(db, sql: "SELECT file_id FROM main.source_decoding_migration ORDER BY file_id"),
             try String.fetchOne(db, sql: "SELECT raw_sha256 FROM main.library_identities WHERE file_id='future-file'"))
        }
        #expect(copied.0 == ["old-file"] && copied.1 == "raw")
        try await owner.close()
        let futureVersion = DataV2Schema.userVersion + 1
        let future = try DatabaseQueue(path: layout.user(.local).path)
        try await future.write { try $0.execute(sql: "PRAGMA user_version=\(futureVersion)") }
        try future.close()
        await #expect(throws: DataV2Error.unsupportedSchema("usr", futureVersion)) { _ = try await owner.activate(.unknown) }
        let check = try DatabaseQueue(path: layout.user(.local).path)
        let version = try await check.read { try DataV2Schema.version($0, in: "main") }
        #expect(version == futureVersion)
        try check.close()
    }

    @Test(arguments: [7, 8])
    func upgradesUserStoreForUnfetchedHistoryDeletes(from oldVersion: Int) throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let first = try DataSession(layout: layout)
        _ = try first.activate(.signedOut)
        try first.close()
        let old = try DatabaseQueue(path: layout.user(.local).path)
        try old.write { db in
            if oldVersion < 8 {
                try db.execute(sql: "DROP TABLE local_saved_filter")
            } else {
                try db.execute(sql: "INSERT INTO local_saved_filter VALUES (1, 'filter', 'Existing filter', X'01')")
            }
            try db.execute(sql: """
                DROP TABLE cloud_history_delete_unfetched;
                INSERT INTO local_shelf_recovery VALUES ('fixture', 'binding', X'01');
                PRAGMA user_version=\(oldVersion);
                """)
        }
        try old.close()

        let upgraded = try DataSession(layout: layout)
        defer { try? upgraded.close() }
        let (lease, _) = try upgraded.activate(.signedOut)
        let (version, filters, deletes, recovery) = try upgraded.read(lease) { db in
            (try DataV2Schema.version(db, in: "usr"),
             try String.fetchAll(db, sql: "SELECT name FROM usr.local_saved_filter"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cloud_history_delete_unfetched"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.local_shelf_recovery WHERE key='fixture'"))
        }
        #expect(version == DataV2Schema.userVersion)
        #expect(filters == (oldVersion == 8 ? ["Existing filter"] : []))
        #expect(deletes == 0)
        #expect(recovery == 1)
    }

    private func container() throws -> ModelContainer {
        let schema = Schema([UserValue.self, UserPosition.self, AnnotationOperation.self, ReadingFact.self, StatisticsClear.self, UserCover.self])
        return try ModelContainer(for: schema, configurations: [.init(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }

    private func stored<T: Encodable>(_ value: T, token: String = "t", updated: Int64 = 17) throws -> String {
        try UserSyncJSON.encode(StoredValue(updated: updated, token: token, value: UserSyncJSON.encode(value)), envelope: true)
    }

    @Test func publishedStoreKeepsOfflineReadingAndProductionTransportThroughLayoutUpgrade() async throws {
        enum Interruption: Error { case beforePublish }
        let files = FileManager.default
        let suite = "published-layout-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let service = AppDataService(sourceDefaultsSuite: suite, readingCloudEnvironment: .production)
        let root = try await service.dataDirectoryURL()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? files.removeItem(at: root)
        }
        func account(_ name: String, _ environment: DataScope.Environment) throws -> CloudSyncCoordinator.Account {
            .init(identity: .init(recordName: name), scope: try .confirmed(container: CloudConfiguration.containerID,
                environment: environment, recordName: name))
        }
        let oldA = try account("fixture-A", .development), newA = try account("fixture-A", .production)
        let oldB = try account("fixture-B", .development), newB = try account("fixture-B", .production)
        let development = DataLayout(applicationSupport: root, environment: .development)
        let production = DataLayout(applicationSupport: root, environment: .production)
        let published = root.appending(path: "Data/v2/development")
        let source = try DataSession(layout: development, confirmedLegacyOwner: oldA.scope)
        let legacyIndex = root.appending(path: "reader.sqlite3")
        let a = try source.activate(.unknown).0
        try source.prepareIndex(legacyIndex, token: a)
        try source.prepareUsers(a) { nil }
        let book = String(repeating: "c", count: 64)
        let zone = ReadingHistoryTransport.zone
        let save = CloudTransportRows.Key(zone: zone, type: "ReadingFact", name: "save-fact")
        let delete = CloudTransportRows.Key(zone: zone, type: "ReadingFact", name: "delete-fact")
        let checkpoint = Data([1, 2, 3]), systemFields = Data([4, 5, 6])
        let stagedInput = Data([7, 8, 9])
        let task = UUID().uuidString
        let slice = ReadingSlice(id: "save-id", sessionId: "fixture", visitId: "fixture", bookId: "cache-id",
            startedMs: 8_640_001_000, endedMs: 8_640_004_000, localDay: 100, utcOffsetSeconds: 0, preview: false, exposures: [])
        let fact = FactImportColumns(payloadContentKey: book, title: "Fixture", device: "fixture", slice: slice, durationMs: 3_000)
        let record = try JSONSerialization.data(withJSONObject: ["id": task, "scope": oldA.scope.metadataImportKey,
                                                                  "sourceExtension": "moonread-metadata"])
        try source.writeDeviceTask { db in
            try db.execute(sql: """
                INSERT INTO main.books(id,title,content_sha256,encoding) VALUES ('job','Fixture','pending:job','UTF-8');
                INSERT INTO main.import_jobs(book_id,phase,generation,pending_owner) VALUES ('job','paused',5,?);
                INSERT INTO main.metadata_import_task VALUES (1,?,?);
                UPDATE main.library_device_state SET legacy_user_scope=?,legacy_cleanup_done=0;
                """, arguments: [oldA.scope.key, task, record, oldA.scope.key])
        }
        try stagedInput.write(to: development.root.appending(path: "fixture-attachment"))
        try source.writeUsers(a) { db in
            try UpgradeOrigins.finish(db)
            _ = try ReadingPositionRows.recordPosition(db, book: book, offset: 42, hint: nil, file: nil,
                device: "fixture", now: 1, token: "position-a", scope: a.scope)
            try ReadingFactSettlement.apply(db, values: [(fact, book, 0, .init(source: "fixture", id: slice.id))], scope: a.scope.key)
            try CloudTransportRows.initializeZone(db, zone: zone, exists: true)
            try CloudTransportRows.storeCheckpoint(db, zone: zone, bytes: checkpoint)
            try CloudTransportRows.recordPresent(db, delete, businessID: "delete-id", systemFields: systemFields)
            try CloudTransportRows.enqueueSave(db, save, businessID: "save-id", digest: "digest")
            try CloudTransportRows.enqueueDelete(db, delete, businessID: "delete-id")
        }
        let b = try source.activate(.confirmed(oldB.scope, syncRequested: false)).0
        try source.prepareIndex(legacyIndex, token: b)
        try source.prepareUsers(b) { nil }
        try source.writeUsers(b) { db in
            try UpgradeOrigins.finish(db)
            _ = try ReadingPositionRows.recordPosition(db, book: book, offset: 16, hint: nil, file: nil,
                device: "fixture", now: 2, token: "position-b", scope: b.scope)
        }
        _ = try source.activate(.confirmed(oldA.scope, syncRequested: false))
        try source.close()
        try files.createDirectory(at: published.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: development.root, to: published)
        defaults.set(oldA.scope.key, forKey: CloudSyncIntent.releasedDevelopmentApprovalKey)
        service.cloudSyncIntent.set(true)

        #expect(throws: Interruption.beforePublish) {
            _ = try ReadingDataLayoutUpgrade.prepare(production, developmentApproval: oldA.scope.key) {
                throw Interruption.beforePublish
            }
        }
        #expect(!files.fileExists(atPath: production.root.path))
        let offline = try await service.relationalUserIndex()
        func offset(_ index: ReaderIndex) throws -> UInt64? {
            try index.session.readUsers(index.lease) {
                try ReadingPositionRows.position($0, book: book, partition: 0)?.value.offset
            }
        }
        #expect(offline.lease.scope == oldA.scope)
        #expect(try offset(offline) == 42)
        #expect(try offline.session.destination(.unknown).maySync == false)
        try await service.approveReadingCloudDuringLegacyCleanup()
        #expect(service.cloudSyncIntent.approvedScopeKey == nil)
        #expect(await service.isReadingCloudApproved(newA))
        #expect(!(await service.isReadingCloudApproved(newB)))
        #expect(try Data(contentsOf: production.root.appending(path: "fixture-attachment")) == stagedInput)

        let other = try DataSession(layout: development)
        #expect(other.releasedLayout == .otherEnvironment)
        let otherLease = try other.activate(.unknown).0
        #expect(otherLease.scope == .local)
        try other.prepareIndex(legacyIndex, token: otherLease)
        try other.prepareUsers(otherLease) { nil }
        other.removeAdoptedReleasedStoreAfterStartup()
        #expect(files.fileExists(atPath: published.path))
        #expect(CloudSyncIntent(defaults: defaults, environment: .development).approvedScopeKey == nil)
        try other.close()
        let confirmed = DataIdentityStatus.confirmed(newA.scope, syncRequested: true, verifiedRecordName: newA.identity.recordName)
        await #expect(throws: ReaderError.CloudAccountChanged) {
            _ = try await service.selectReadingCloudScope(confirmed, approval: nil, lookup: { .confirmed(newB) })
        }
        let selected = try await service.selectReadingCloudScope(confirmed, approval: nil, lookup: { .confirmed(newA) })
        #expect(selected == .init(scope: newA.scope, maySync: true))
        #expect(service.cloudSyncIntent.approvedScopeKey == newA.scope.key)
        let connected = try await service.relationalUserIndex()
        #expect(try offset(connected) == 42)
        #expect(try await service.publishedUserSource() == newA.scope)
        let (jobOwner, taskScope) = try connected.session.readDeviceTask { db in
            (try String.fetchOne(db, sql: "SELECT pending_owner FROM main.import_jobs WHERE book_id='job' AND phase='paused'"),
             try String.fetchOne(db, sql: "SELECT json_extract(CAST(record AS TEXT),'$.scope') FROM main.metadata_import_task WHERE task_id=?", arguments: [task]))
        }
        #expect(jobOwner == newA.scope.key && taskScope == newA.scope.metadataImportKey)
        let transport = try connected.session.readUsers(connected.lease) { db in
            (try CloudTransportRows.checkpoint(db, zone: zone), try CloudTransportRows.zoneStage(db, zone: zone),
             try CloudTransportRows.systemFields(db, delete), try CloudTransportRows.pending(db, save)?.intent,
             try CloudTransportRows.pending(db, delete)?.intent)
        }
        let facts = try connected.session.readUsers(connected.lease) { db in
            (try String.fetchAll(db, sql: "SELECT fact_id FROM usr.reading_fact WHERE book_key=?", arguments: [book]),
             try Int.fetchOne(db, sql: "SELECT sum(duration_ms) FROM usr.reading_fact WHERE book_key=?", arguments: [book]))
        }
        #expect(facts.0 == [slice.id] && facts.1 == 3_000)
        #expect(transport.0 == checkpoint && transport.1 == .ready && transport.2 == systemFields)
        #expect(transport.3 == .save(digest: "digest") && transport.4 == .delete)
        _ = try await service.selectReadingCloudScope(.confirmed(newB.scope, syncRequested: false,
            verifiedRecordName: newB.identity.recordName), approval: nil, lookup: { .confirmed(newB) })
        let switched = try await service.relationalUserIndex()
        #expect(switched.lease.scope == newB.scope)
        #expect(try offset(switched) == 16)
        #expect(try switched.session.readUsers(switched.lease) { try CloudTransportRows.checkpoint($0, zone: zone) } == nil)
        _ = try await service.selectReadingCloudScope(confirmed, approval: nil, lookup: { .confirmed(newA) })
        let returned = try await service.relationalUserIndex()
        try returned.session.writeUsers(returned.lease) { db in
            _ = try ReadingPositionRows.recordPosition(db, book: book, offset: 56, hint: nil, file: nil,
                device: "fixture", now: 3, token: "position-updated", scope: returned.lease.scope)
        }
        try returned.session.close()

        let reopened = try DataSession(layout: production)
        defer { try? reopened.close() }
        let reopenedLease = try reopened.activate(.unknown).0
        try reopened.prepareIndex(legacyIndex, token: reopenedLease)
        reopened.removeAdoptedReleasedStoreAfterStartup()
        #expect(files.fileExists(atPath: published.path))
        try reopened.prepareUsers(reopenedLease) { nil }
        reopened.removeAdoptedReleasedStoreAfterStartup()
        #expect(!files.fileExists(atPath: published.path))
        #expect(try reopened.importedLegacyIndexFiles(reopenedLease).isEmpty)
        #expect(try ReadingDataLayoutUpgrade.prepare(production) == .mislabelledProduction(approvedScope: oldA.scope.key))
        #expect(reopenedLease.scope == newA.scope)
        #expect(try offset(ReaderIndex(session: reopened, lease: reopenedLease)) == 56)
    }

    @Test func explicitPublishedProductionAndDevelopmentStoresStaySeparate() throws {
        let root = try sandbox()
        let files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let released = root.appending(path: "Data/v2")
        for environment in [DataScope.Environment.production, .development] {
            let layout = DataLayout(applicationSupport: root, environment: environment)
            let session = try DataSession(layout: layout)
            _ = try session.activate(.unknown)
            try session.close()
            try Data(environment.rawValue.utf8).write(to: layout.root.appending(path: "fixture"))
            let target = environment == .production ? released : released.appending(path: "development")
            try files.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: layout.root, to: target)
        }
        for environment in [DataScope.Environment.production, .development] {
            let layout = DataLayout(applicationSupport: root, environment: environment)
            let session = try DataSession(layout: layout)
            defer { try? session.close() }
            #expect(session.releasedLayout == (environment == .production ? .original : .releasedDevelopment(approvedScope: nil)))
            #expect(try Data(contentsOf: layout.root.appending(path: "fixture")) == Data(environment.rawValue.utf8))
            #expect(!files.fileExists(atPath: layout.root.appending(path: "development").path))
            let lease = try session.activate(.unknown).0
            try session.prepareIndex(root.appending(path: "unused"), token: lease)
            try session.prepareUsers(lease) { nil }
            session.removeAdoptedReleasedStoreAfterStartup()
            let oldDevelopment = released.appending(path: "development")
            #expect(files.fileExists(atPath: oldDevelopment.path) == (environment == .production))
            #expect(try Data(contentsOf: released.appending(path: "fixture")) == Data("production".utf8))
        }
    }

    @Test(arguments: [false, true])
    func adoptsWALUserStoreWithoutOpeningReleasedFiles(hasPendingWAL: Bool) throws {
        let root = try sandbox()
        let files = FileManager.default
        defer { try? files.removeItem(at: root) }
        let old = root.appending(path: "Data/v2/development/local/user.sqlite")
        let wal = old.deletingLastPathComponent().appending(path: "user.sqlite-wal")
        let shm = old.deletingLastPathComponent().appending(path: "user.sqlite-shm")
        try files.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.journalMode = .wal
        let writer = try DatabaseQueue(path: old.path, configuration: configuration)
        defer { if hasPendingWAL { try? writer.close() } }
        try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_autocheckpoint=0") }
        try writer.write { try $0.execute(sql: "CREATE TABLE fixture(value INTEGER); INSERT INTO fixture VALUES(1)") }
        _ = try writer.writeWithoutTransaction { try $0.checkpoint(.truncate) }

        let main = try Data(contentsOf: old)
        let journalFormat = Array(main[18..<20])
        #expect(journalFormat == [2, 2])
        let pending: Data?
        if hasPendingWAL {
            // Leave this committed value in the WAL while the source is idle.
            try writer.write { try $0.execute(sql: "UPDATE fixture SET value=2") }
            try #require(Data(contentsOf: old) == main)
            let bytes = try Data(contentsOf: wal)
            try #require(bytes.count > 32)
            pending = bytes
        } else {
            try writer.close()
            // Some SQLite builds retain the sidecars after a successful
            // checkpoint. Model the released store with no sidecars.
            if files.fileExists(atPath: wal.path) {
                let checkpointed = try Data(contentsOf: wal)
                try #require(checkpointed.isEmpty)
                try files.removeItem(at: wal)
            }
            if files.fileExists(atPath: shm.path) { try files.removeItem(at: shm) }
            pending = nil
        }

        let layout = DataLayout(applicationSupport: root, environment: .development)
        #expect(try ReadingDataLayoutUpgrade.prepare(layout) == .releasedDevelopment(approvedScope: nil))
        let migrated = try DatabaseQueue(path: layout.user(.local).path)
        defer { try? migrated.close() }
        #expect(try migrated.read { try Int.fetchOne($0, sql: "SELECT value FROM fixture") } == (hasPendingWAL ? 2 : 1))
        #expect(try Data(contentsOf: old) == main)
        if let pending {
            #expect(try Data(contentsOf: wal) == pending)
        } else {
            #expect(!files.fileExists(atPath: wal.path) && !files.fileExists(atPath: shm.path))
        }
    }

    @Test func releasedOwnerImportsIndependentlyInEachCloudEnvironment() async throws {
        let suite = "reading-environments-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set("released-owner", forKey: "Moonread.userOwner")
        let development = AppDataService(sourceDefaultsSuite: suite, readingCloudEnvironment: .development)
        let production = AppDataService(sourceDefaultsSuite: suite, readingCloudEnvironment: .production)
        let directory = try await development.dataDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let book = String(repeating: "a", count: 64)
        let key = "metadata/\(book)/author"
        do {
            let schema = Schema([UserValue.self, UserPosition.self, AnnotationOperation.self, ReadingFact.self,
                                 StatisticsClear.self, UserCover.self])
            let configuration = ModelConfiguration("UserData", schema: schema, url: directory.appending(path: "user-data.store"),
                                                   cloudKitDatabase: .none)
            let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
            context.insert(UserValue(key: key, device: "fixture", payload: try stored("legacy")))
            try context.save()
        }
        func author(_ index: ReaderIndex) throws -> String? {
            try index.session.readUsers(index.lease) { db in
                try String.fetchOne(db, sql: "SELECT value_text FROM usr.metadata_text_candidate WHERE logical_key=?",
                                    arguments: [key])
            }
        }
        let dev = try await development.relationalUserIndex()
        let devScope = try DataScope.confirmed(container: CloudConfiguration.containerID, environment: .development,
                                               recordName: "released-owner")
        #expect(dev.lease.scope == devScope)
        #expect(try author(dev) == "legacy")
        #expect(await development.isReadingCloudApproved(devScope))
        try dev.session.writeUsers(dev.lease) { db in
            try UserValueRows.put(db, key: .init(key), value: UserSyncJSON.encode("only-development"),
                                  device: "fixture", now: 42, scope: dev.lease.scope)
        }
        #expect(try author(dev) == "only-development")
        development.cloudSyncIntent.approve(devScope)
        let prod = try await production.relationalUserIndex()
        let prodScope = try DataScope.confirmed(container: CloudConfiguration.containerID, environment: .production,
                                                recordName: "released-owner")
        #expect(prod.lease.scope == prodScope)
        #expect(dev.lease.scope != prod.lease.scope)
        #expect(dev.session.layout.index != prod.session.layout.index)
        #expect(await production.isReadingCloudApproved(prodScope))
        #expect(try author(prod) == "legacy")
        AppDataService.removeLegacyLocalDefaults(defaults, domain: suite)
        #expect(await production.isReadingCloudApproved(prodScope))
        _ = try await production.selectReadingCloudScope(.signedOut, approval: nil, lookup: { .signedOut })
        let local = try await production.relationalUserIndex()
        #expect(local.lease.scope == .local)
        #expect(try author(local) == nil)
        try prod.session.close()
        try dev.session.close()
    }

    @Test func swiftDataRoutesAllModelFamiliesAndPreservesIsolation() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let formal = try container(), pending = try container()
        let key = String(repeating: "a", count: 64), pendingKey = "pending:fixture"
        let context = ModelContext(formal), draft = ModelContext(pending)
        let bytes = Data([0, 1, 2, 12]), sha = DataIdentity.sha(bytes)
        let cover = """
        {"id":"image","sha256":"\(sha)","extension":"jpg","width":1,"height":2}
        """
        context.insert(UserCover(id: "image", bytes: bytes))
        context.insert(UserValue(key: "metadata/\(key)/cover", device: "D", payload: try UserSyncJSON.encode(.init(updated: 17, token: "t", value: cover) as StoredValue)))
        for (field, value) in [("author","author"),("synopsis","summary"),("status","Reading")] {
            context.insert(UserValue(key: "metadata/\(key)/\(field)", device: "D", payload: try stored(value)))
        }
        context.insert(UserValue(key: "metadata/\(key)/tag-old", device: "D", payload: try stored(nil as String?)))
        context.insert(UserValue(key: "chapter/\(key)/7", device: "D", payload: try stored(nil as String?)))
        context.insert(UserValue(key: "opened/\(key)", device: "D", payload: try stored(Int64(123))))
        context.insert(UserValue(key: "source-decoding/\(key)", device: "D", payload: try stored(SourceDecodingValue(decoding: "UTF-8"))))
        context.insert(UserValue(key: "palette/p1", device: "D", payload: try stored(nil as String?)))
        context.insert(UserValue(key: "shelf-reference/00000000-0000-0000-0000-000000000001", device: "D",
            payload: try stored(ShelfReferenceValue(name: "Reference", locationDescription: "file-provider"))))
        let future = #"{"v":7,"updated":1,"token":"t","value":"\"future\""}"#
        context.insert(UserValue(key: "metadata/\(key)/author", device: "future", payload: future))
        let hint = PositionSourceHint(source_kind: .managedLocal, relative_path: "folder/one.txt", file_name: "one.txt",
                                      byte_size: 42, decoding: "UTF-8")
        let samePosition = try stored(PositionValue(content_key: key, offset: .max, source_hint: hint))
        context.insert(UserValue(key: "position/\(key)", device: "D", payload: samePosition))
        context.insert(UserPosition(contentKey: key, payload: samePosition))
        let conflictKey = String(repeating: "d", count: 64)
        let original = try stored(PositionValue(content_key: conflictKey, offset: 1, source_hint: hint))
        let conflict = try stored(PositionValue(content_key: conflictKey, offset: 2, source_hint: hint))
        context.insert(UserValue(key: "position/\(conflictKey)", device: "D", payload: original))
        context.insert(UserPosition(contentKey: conflictKey, payload: conflict))
        let note = AnnotationCandidate(id: "note", ancestors: ["not-materialized"], content: .init(start: .max-1, end: .max, excerpt: "", note: "fixture"),
            created: .max, bookmark: false, relatedMarks: ["remote-mark"])
        context.insert(AnnotationOperation(id: note.id, contentKey: key, markID: "mark", payload: try UserSyncJSON.encode(note, envelope: true)))
        let slice = ReadingSlice(id: "shared-fact", sessionId: "session", visitId: "visit", bookId: "old-book-id", startedMs: 12, endedMs: 42,
            localDay: 20260101, utcOffsetSeconds: 3600, preview: true,
            exposures: [.init(startUtf8: 9, endUtf8: .max, durationMs: .max)])
        let payload = try encodeReadingFact(contentKey: pendingKey, title: "Title", device: "Device", slice: slice)
        context.insert(ReadingFact(id: slice.id, contentKey: key, payload: payload))
        draft.insert(ReadingFact(id: slice.id, contentKey: pendingKey, payload: payload))
        context.insert(StatisticsClear(payload: try UserSyncJSON.encode(ClearValue(book: key, session: "session", through: 11,
            ids: ["not-materialized"]), envelope: true)))
        let unreadableClear = #"{"v":7,"book":"scope","session":null,"through":1,"ids":[]}"#
        context.insert(StatisticsClear(payload: unreadableClear))
        try context.save()
        try draft.save()

        let owner = try DataSession(layout: layout)
        let (lease, _) = try await owner.activate(.signedOut)
        var source = LegacyUserSnapshot(scope: nil, formal: formal, pending: pending)
        await #expect(throws: DataV2Error.incompatibleSource("unconfirmed legacy user ownership")) {
            try await owner.importLegacyUsers(source, token: lease)
        }
        source.scope = .local
        source.deviceState.resume[key] = .init(offset: .max, lastLocalWriteToken: nil)
        let events = Mutex([LegacyImportProgress]())
        try owner.prepareIndex(root.appending(path: "unused-reader.sqlite3"), token: lease)
        try owner.prepareUsers(lease, progress: { event in events.withLock { $0.append(event) } }) { source }
        let reported = events.withLock { $0 }
        let expected = try #require(owner.readUsers(lease) { try Int.fetchOne($0, sql: "SELECT sum(imported_count) FROM usr.legacy_import_state") })
        #expect(reported.first == .rows(processed: 0, total: expected))
        #expect(reported.last == .finishing)
        #expect(reported.contains { if case .rows(let done, let total) = $0 { return done > 0 && done < total }; return false })
        try owner.prepareUsers(lease, progress: { _ in Issue.record("Completed import emitted more progress") }) {
            Issue.record("Completed import reopened the old source")
            return nil
        }
        try await owner.read(lease) { db throws -> Void in
            try #expect(Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usr.metadata_text_candidate") == 3)
            try #expect(Bool.fetchOne(db, sql: "SELECT is_deleted FROM usr.tag_candidate") == true)
            try #expect(Bool.fetchOne(db, sql: "SELECT is_retracted FROM usr.chapter_override_candidate") == true)
            try #expect(String.fetchOne(db, sql: "SELECT source_id FROM usr.legacy_import_state LIMIT 1") == "local")
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.legacy_import_state") == 12)
            try #expect(Data.fetchOne(db, sql: "SELECT bytes FROM usr.cover_asset") == bytes)
            try #expect(String.fetchOne(db, sql: "SELECT created FROM usr.annotation_candidate") == "18446744073709551615")
            try #expect(String.fetchOne(db, sql: "SELECT ancestor_id FROM usr.annotation_ancestor") == "not-materialized")
            try #expect(String.fetchOne(db, sql: "SELECT related_mark_id FROM usr.annotation_related_mark") == "remote-mark")
            try #expect(String.fetchOne(db, sql: "SELECT candidate_id FROM usr.annotation_current_head") == note.id)
            try #expect(Int.fetchOne(db, sql: "SELECT recent_ms FROM usr.reading_current WHERE book_key=?", arguments: [key]) == 123)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.reading_current WHERE book_key=?", arguments: [conflictKey]) == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.metadata_current WHERE author_id IS NULL AND cover_id IS NOT NULL") == 1)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.chapter_override_current") == 0)
            let position = try Row.fetchAll(db, sql: """
                SELECT device_id,offset,relative_path FROM usr.position_candidate WHERE book_key=?
                """, arguments: [key])
            #expect(position.count == 1 && (position.first?["device_id"] as String?) == "D")
            #expect((position.first?["offset"] as String?) == "18446744073709551615")
            #expect((position.first?["relative_path"] as String?) == "folder/one.txt")
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.quarantined_record WHERE source_type='UserPosition'") == 1)
            try #expect(Data.fetchOne(db, sql: """
                SELECT raw_bytes FROM usr.quarantined_record
                WHERE source_type='UserPosition' AND book_key=? AND reason='stable-id-conflict'
                """, arguments: [conflictKey]) == Data(conflict.utf8))
            try #expect(String.fetchOne(db, sql: "SELECT offset FROM usr.local_resume WHERE last_local_write_token IS NULL") == "18446744073709551615")
            try #expect(Int.fetchOne(db, sql: "SELECT opened_ms FROM usr.opened_candidate") == 123)
            try #expect(String.fetchOne(db, sql: "SELECT decoding FROM usr.source_decoding_candidate") == "UTF-8")
            try #expect(Bool.fetchOne(db, sql: "SELECT is_deleted FROM usr.palette_candidate") == true)
            try #expect(String.fetchOne(db, sql: "SELECT location_description FROM usr.shelf_reference_candidate") == "file-provider")
            try #expect(Int.fetchAll(db, sql: "SELECT partition FROM usr.reading_fact ORDER BY partition") == [0,1])
            try #expect(String.fetchAll(db, sql: "SELECT book_key FROM usr.reading_fact ORDER BY partition") == [key,pendingKey])
            try #expect(Int.fetchOne(db, sql: "SELECT duration_ms FROM usr.reading_fact LIMIT 1") == 30)
            try #expect(Int.fetchOne(db, sql: "SELECT utc_offset_seconds FROM usr.reading_fact LIMIT 1") == 3600)
            try #expect(String.fetchOne(db, sql: "SELECT visit_id FROM usr.reading_fact LIMIT 1") == "visit")
            try #expect(String.fetchOne(db, sql: "SELECT fact_id FROM usr.statistics_clear_id") == "not-materialized")
            try #expect(String.fetchOne(db, sql: "SELECT book_key FROM usr.quarantined_record WHERE source_type='StatisticsClear'") == "scope")
            try #expect(Data.fetchOne(db, sql: "SELECT raw_bytes FROM usr.quarantined_record WHERE source_type='UserValue'") == Data(future.utf8))
        }
        try await owner.close()
    }

    private func missingCover(_ id: String) -> UserCover {
        let row = UserCover(id: id, bytes: Data())
        row.bytes = nil
        return row
    }

    private func coverReference(_ id: String, sha: String, book: String) throws -> UserValue {
        let value = """
        {"id":"\(id)","sha256":"\(sha)","extension":"jpg","width":1,"height":2}
        """
        return UserValue(key: "metadata/\(book)/cover", device: "D",
                         payload: try UserSyncJSON.encode(StoredValue(updated: 17, token: "t", value: value)))
    }

    @Test func resolvedCoverAttachmentsPermitLocalClaim() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DataSession(layout: DataLayout(applicationSupport: root))
        let formal = try container(), pending = try container()
        let source = ModelContext(formal), drafts = ModelContext(pending)
        let duplicateID = "10000000-0000-0000-0000-000000000001"
        let cacheID = "10000000-0000-0000-0000-000000000002"
        let duplicateBytes = Data([1,2,3]), cacheBytes = Data([4,5,6])
        let cacheSHA = DataIdentity.sha(cacheBytes)
        source.insert(missingCover(duplicateID))
        drafts.insert(UserCover(id: duplicateID, bytes: duplicateBytes))
        source.insert(missingCover(cacheID))
        source.insert(try coverReference(duplicateID, sha: DataIdentity.sha(duplicateBytes), book: String(repeating: "a", count: 64)))
        source.insert(try coverReference(cacheID, sha: cacheSHA, book: String(repeating: "b", count: 64)))
        try cacheBytes.write(to: root.appending(path: "\(cacheID)-\(cacheSHA).jpg"))
        try source.save()
        try drafts.save()

        let (local, _) = try await owner.activate(.signedOut)
        try await owner.importLegacyUsers(.init(scope: .local, formal: formal, pending: pending, coverDirectory: root), token: local)
        try await owner.read(local) { db throws -> Void in
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM usr.quarantined_record WHERE completeness='incomplete'") == 0)
            try #expect(String.fetchAll(db, sql: """
                SELECT completeness FROM usr.legacy_import_state WHERE source_model='UserCover' ORDER BY partition
                """) == ["complete","complete"])
        }
        let account = try scope("cover-account")
        _ = try await owner.activate(.confirmed(account, syncRequested: true))
        try await owner.claimLocal(for: account)
        let (claimed, _) = try await owner.activate(.confirmed(account, syncRequested: true))
        let bytes = try await owner.read(claimed) { db in
            try Data.fetchAll(db, sql: """
                SELECT a.bytes FROM usr.cover_candidate c JOIN usr.cover_asset a ON a.asset_id=c.asset_id ORDER BY a.legacy_cover_id
                """)
        }
        #expect(bytes == [duplicateBytes,cacheBytes])
        try await owner.close()
    }

    @Test func corruptCacheAndAmbiguousCoverKeepMissingEvidence() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DataSession(layout: DataLayout(applicationSupport: root))
        let formal = try container(), source = ModelContext(formal)
        let wrongCacheID = "10000000-0000-0000-0000-000000000001"
        let ambiguousID = "10000000-0000-0000-0000-000000000002"
        let expectedSHA = DataIdentity.sha(Data([1,2,3]))
        try Data([9]).write(to: root.appending(path: "\(wrongCacheID)-\(expectedSHA).jpg"))
        source.insert(missingCover(wrongCacheID))
        source.insert(try coverReference(wrongCacheID, sha: expectedSHA, book: String(repeating: "a", count: 64)))
        source.insert(missingCover(ambiguousID))
        source.insert(UserCover(id: ambiguousID, bytes: Data([1,2,3])))
        source.insert(UserCover(id: ambiguousID, bytes: Data([4,5,6])))
        try source.save()
        let (local, _) = try await owner.activate(.signedOut)
        try await owner.importLegacyUsers(.init(scope: .local, formal: formal, pending: nil, coverDirectory: root), token: local)
        try await owner.read(local) { db throws -> Void in
            try #expect(Data.fetchAll(db, sql: """
                SELECT raw_bytes FROM usr.quarantined_record WHERE completeness='incomplete' ORDER BY raw_bytes
                """) == [Data(wrongCacheID.utf8),Data(ambiguousID.utf8)])
            try #expect(String.fetchAll(db, sql: "SELECT availability FROM usr.cover_asset ORDER BY availability") ==
                        ["available","available","missing"])
            try #expect(String.fetchAll(db, sql: """
                SELECT completeness FROM usr.legacy_import_state
                WHERE source_model IN ('UserCover','UserValue') ORDER BY source_model
                """) == ["incomplete","incomplete"])
        }
        let account = try scope("cover-account")
        _ = try await owner.activate(.confirmed(account, syncRequested: true))
        await #expect(throws: DataV2Error.migrationNotVerified) { try await owner.claimLocal(for: account) }
        let (reopened, selected) = try await owner.activate(.unknown)
        #expect(selected.scope == .local)
        let remaining = try await owner.read(reopened) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.quarantined_record") }
        #expect(remaining == 2)
        try await owner.close()
    }

    @Test func claimsLocalOnlyOnConfirmationAndKeepsAccountsIsolated() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let a = try scope("A"), b = try scope("B"), dev = try scope("A", .development)
        #expect(a != b && a != dev)
        let owner = try DataSession(layout: layout)
        let (local, _) = try await owner.activate(.unknown)
        let formal = try container()
        let key = "metadata/" + String(repeating: "b", count: 64) + "/author"
        let context = ModelContext(formal)
        context.insert(UserValue(key: key, device: "local-fixture", payload: try stored("unassigned")))
        try context.save()
        try await owner.importLegacyUsers(.init(scope: .local, formal: formal), token: local)
        let (signedIn, unconfirmed) = try await owner.activate(.confirmed(a, syncRequested: true))
        #expect(signedIn == local && unconfirmed.scope == .local && !unconfirmed.maySync)
        try await owner.claimLocal(for: a)
        await #expect(throws: DataV2Error.leaseExpired) { _ = try await owner.read(local) { _ in 0 } }

        let (off, info) = try await owner.activate(.unknown)
        #expect(info.scope == a && !info.maySync)
        let readBack = try await owner.read(off) { db in
            try String.fetchOne(db, sql: """
                SELECT c.value_text FROM usr.metadata_current m JOIN usr.metadata_text_candidate c
                  ON c.partition=m.source_partition AND c.record_id=m.author_id
                """)
        }
        #expect(readBack == "unassigned")
        try await owner.close()
        let restarted = try DataSession(layout: layout)
        let (_, unknown) = try await restarted.activate(.unknown)
        #expect(unknown == info)
        let (out, signedOut) = try await restarted.activate(.signedOut)
        #expect(signedOut.scope == .local && !signedOut.maySync)
        let remaining = try await restarted.read(out) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.metadata_text_candidate") }
        #expect(remaining == 0)
        let (_, stillLocal) = try await restarted.activate(.unknown)
        #expect(stillLocal.scope == .local)
        _ = try await restarted.activate(.confirmed(b, syncRequested: false))
        try await restarted.claimLocal(for: b)
        let (newAccount, _) = try await restarted.activate(.confirmed(b, syncRequested: true))
        let leaked = try await restarted.read(newAccount) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.metadata_text_candidate") }
        #expect(leaked == 0)
        try await restarted.close()
    }

    @Test func retiresCloudCallbacksWithoutClosingSameAccountReaders() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try scope("A"), b = try scope("B")
        let owner = try DataSession(layout: .init(applicationSupport: root), confirmedLegacyOwner: a)
        let legacyIndex = root.appending(path: "unused")
        let (localA, _) = try owner.activate(.confirmed(a, syncRequested: true))
        try owner.prepareIndex(legacyIndex, token: localA)
        #expect(throws: DataV2Error.migrationNotVerified) { _ = try CloudCallbackJournal(session: owner, lease: localA) }
        try owner.prepareUsers(localA) { nil }
        // This case exercises an ordinary cursor after the upgrade, rather
        // than the unresolved initial intake which may not save that cursor.
        try owner.writeUsers(localA) { db in try UpgradeOrigins.finish(db) }
        let old = try CloudCallbackJournal(session: owner, lease: localA)
        try await old.initializeZone(exists: true)
        try await old.persistCheckpoint(Data([1]))

        let (offline, selection) = try owner.activate(.unknown)
        #expect(offline == localA && !selection.maySync)
        #expect(throws: DataV2Error.leaseExpired) { _ = try CloudCallbackJournal(session: owner, lease: offline) }
        try owner.writeUsers(localA) { try $0.execute(sql: "INSERT INTO usr.local_hidden_book VALUES ('fixture')") }

        let (resumed, _) = try owner.activate(.confirmed(a, syncRequested: true))
        #expect(resumed == localA)
        let current = try CloudCallbackJournal(session: owner, lease: resumed)
        await #expect(throws: DataV2Error.leaseExpired) { try await old.persistCheckpoint(Data([2])) }
        old.retire()  // Finishing old SDK cancellation cannot revoke its replacement.
        #expect(try await current.checkpoint() == Data([1]))

        let (paused, _) = try owner.activate(.confirmed(a, syncRequested: false))
        #expect(paused == localA)
        #expect(try owner.readUsers(paused) { try String.fetchOne($0, sql: "SELECT book_key FROM usr.local_hidden_book") } == "fixture")
        await #expect(throws: DataV2Error.leaseExpired) { _ = try await current.checkpoint() }

        let (localB, _) = try owner.activate(.confirmed(b, syncRequested: true))
        try owner.prepareIndex(legacyIndex, token: localB)
        try owner.prepareUsers(localB) { nil }
        let other = try CloudCallbackJournal(session: owner, lease: localB)
        #expect(try await other.checkpoint() == nil)
        #expect(throws: DataV2Error.leaseExpired) { _ = try owner.readUsers(localA) { _ in 0 } }
        let (returned, _) = try owner.activate(.confirmed(a, syncRequested: true))
        try owner.prepareIndex(legacyIndex, token: returned)
        try owner.prepareUsers(returned) { nil }
        #expect(returned != localA)
        #expect(try await CloudCallbackJournal(session: owner, lease: returned).checkpoint() == Data([1]))
        await #expect(throws: DataV2Error.leaseExpired) { try await other.persistCheckpoint(Data([3])) }
        try owner.close()
    }

    @Test func rebindsWALIndexToFreshAccountBeforeOpeningReaders() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let a = try scope("A"), b = try scope("B")
        let session = try DataSession(layout: layout, confirmedLegacyOwner: a)
        let (leaseA, _) = try session.activate(.unknown)
        let keyA = String(repeating: "a", count: 64), keyB = String(repeating: "b", count: 64)
        func snapshot(_ scope: DataScope, hidden key: String) throws -> LegacyUserSnapshot {
            var source = LegacyUserSnapshot(scope: scope, formal: try container(), pending: nil)
            source.deviceState.hidden = [key]
            return source
        }
        func hidden(_ token: DataSessionLease) throws -> [String] {
            try session.read(token) { try String.fetchAll($0, sql: "SELECT book_key FROM usr.local_hidden_book") }
        }
        try session.importLegacyUsers(snapshot(a, hidden: keyA), token: leaseA)
        let (leaseB, selection) = try session.activate(.confirmed(b, syncRequested: false))
        #expect(selection.scope == b && !selection.maySync)
        try #expect(hidden(leaseB).isEmpty)
        #expect(throws: DataV2Error.leaseExpired) { _ = try hidden(leaseA) }
        #expect(throws: DataV2Error.leaseExpired) {
            try session.importLegacyUsers(snapshot(a, hidden: keyB), token: leaseA)
        }
        try session.importLegacyUsers(snapshot(b, hidden: keyB), token: leaseB)
        let (newA, _) = try session.activate(.confirmed(a, syncRequested: false))
        try #expect(hidden(newA) == [keyA])
        let (newB, _) = try session.activate(.confirmed(b, syncRequested: false))
        try #expect(hidden(newB) == [keyB])
        try session.close()
    }

    @Test func requiresVerifiedUserIntakeAndCommitsPositionWithDeviceBaseline() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let session = try DataSession(layout: layout)
        let (lease, _) = try session.activate(.unknown)
        let oldIndex = root.appending(path: "reader.sqlite3")
        try session.prepareIndex(oldIndex, token: lease)
        #expect(throws: DataV2Error.migrationNotVerified) { _ = try session.readUsers(lease) { _ in 0 } }

        let book = String(repeating: "a", count: 64)
        var source = LegacyUserSnapshot(scope: .local, formal: try container(), pending: nil)
        source.deviceState.hidden = [book]
        try session.prepareUsers(lease) { source }
        try session.writeUsers(lease) { db in
            try ReadingPositionRows.recordOpened(db, book: book, openedAt: 12, file: "file", device: "sample",
                                                now: 12, token: "opened")
        }
        try #expect(session.readUsers(lease) { try ReadingPositionRows.position($0, book: book, partition: 0) } == nil)
        _ = try session.writeUsers(lease) { db in
            try ReadingPositionRows.recordPosition(db, book: book, offset: UInt64.max, hint: nil, file: nil,
                                                  device: "sample", now: 13, token: "position")
        }
        try session.close()

        let (newLease, _) = try session.activate(.unknown)
        try session.prepareIndex(oldIndex, token: newLease)
        try session.prepareUsers(newLease) { throw DataV2Error.migrationAlreadyComplete }
        let state = try session.readUsers(newLease) { db in
            (try LocalReadingRows.resume(db, book: book), try LocalReadingRows.hidden(db, book: book),
             try LocalReadingRows.preferredFile(db, book: book), try ReadingPositionRows.position(db, book: book, partition: 0))
        }
        #expect(state.0 == .init(offset: UInt64.max, token: "position") && !state.1 && state.2 == "file")
        #expect(state.3?.value.offset == UInt64.max && state.3?.token == "position")
        try session.close()
    }

    @Test func pendingPromotionRollsBackBeforeReclaimingItsIndexAlias() throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try DataSession(layout: .init(applicationSupport: root))
        let (lease, _) = try session.activate(.unknown)
        try session.prepareIndex(root.appending(path: "reader.sqlite3"), token: lease)
        try session.prepareUsers(lease) { nil }
        let index = ReaderIndex(session: session, lease: lease)
        let control = try index.createImport(title: "Synthetic")
        let key = serializeReadingKey(key: .pending(bookId: control.id))
        let bytes = Data("第一章\n合成正文\n".utf8)
        let source = root.appending(path: "fixture.txt")
        try bytes.write(to: source)
        let sha = DataIdentity.sha(bytes)
        _ = try session.writeUsers(lease) {
            try ReadingPositionRows.recordPosition($0, book: sha, offset: 1, hint: nil, file: nil,
                                                   device: "device", now: 10, token: "old")
        }
        // This job was already running at deletion, but its SHA was unknown.
        // Reading it after deletion creates new data that can still promote.
        let deleted = try index.deleteUserBooks([sha], activeReadingIDs: []) { ReadingDataError.busy }
        #expect(deleted == [sha])
        _ = try session.writeUsers(lease) {
            try ReadingPositionRows.recordPosition($0, book: key, offset: 3, hint: nil, file: "fixture",
                                                   device: "device", now: 12, token: "pending")
        }
        try #expect(index.promotePendingUserData(bookId: control.id) == .notReady)
        try index.streamImport(control: control, filePath: source.path, expectedRawSha256: sha, encodingOverride: nil)
        _ = try index.finishImport(control: control)

        try session.writeUsers(lease) {
            try $0.execute(sql: """
                CREATE TRIGGER usr.reject_pending_removal BEFORE DELETE ON position_candidate
                WHEN OLD.partition=1 BEGIN SELECT RAISE(ABORT,'fixture'); END
                """)
        }
        #expect(throws: DatabaseError.self) { _ = try index.promotePendingUserData(bookId: control.id) }
        try #expect(index.pendingUserPromotionKeys() == [key])
        try #expect(index.importStatus(bookId: control.id).phase == .complete)
        try #expect(session.readUsers(lease) { try ReadingPositionRows.position($0, book: sha, partition: 0) } == nil)
        try #expect(session.readUsers(lease) { try String.fetchAll($0, sql: "SELECT book_key FROM usr.reading_current") } == [key])

        try session.writeUsers(lease) { try $0.execute(sql: "DROP TRIGGER usr.reject_pending_removal") }
        try #expect(index.promotePendingUserData(bookId: control.id) == .committed(sha256: sha))
        try #expect(index.promotePendingUserData(bookId: control.id) == .committed(sha256: sha))
        try #expect(index.pendingUserPromotionKeys().isEmpty)
        try #expect(session.readUsers(lease) { try ReadingPositionRows.position($0, book: sha, partition: 0)?.token } == "pending")
        try #expect(session.readUsers(lease) { try String.fetchAll($0, sql: "SELECT book_key FROM usr.reading_current") } == [sha])
        try #expect(!index.reclaimCompletedImport(bookId: control.id))
        try #expect(index.reclaimCompletedImport(bookId: control.id, userPromotionCommitted: true))
        try session.close()
    }

    @Test func recoversCommittedLocalClaimBeforeSelectingAnotherAccount() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DataLayout(applicationSupport: root)
        let a = try scope("A"), b = try scope("B")
        let owner = try DataSession(layout: layout)
        let (local, _) = try await owner.activate(.signedOut)
        let formal = try container()
        let book = String(repeating: "c", count: 64)
        let key = "metadata/\(book)/author"
        let context = ModelContext(formal)
        context.insert(UserValue(key: key, device: "fixture", payload: try stored("frozen local")))
        try context.save()
        try await owner.importLegacyUsers(.init(scope: .local, formal: formal), token: local)
        try await owner.close()

        let intent = DataOwnerState.Move(id: UUID(), target: a)
        var savedOwner = try DataOwnerState.load(at: layout.ownerState)
        savedOwner.move = intent
        try savedOwner.save(at: layout.ownerState)
        // Reopen at the before-commit interruption point: the source must
        // still be readable and the abandoned move must not be completed.
        let before = try DataSession(layout: layout)
        let (old, notClaimed) = try await before.activate(.unknown)
        #expect(notClaimed.scope == .local)
        let unassigned = try await before.read(old) { try String.fetchOne($0, sql: "SELECT value_text FROM usr.metadata_text_candidate") }
        #expect(unassigned == "frozen local")
        try await before.close()

        // Freeze again, commit only the real target transaction, and leave
        // the original intent file untouched as if the process terminated.
        let marker = DataOwnerState.Move(id: UUID(), target: a)
        savedOwner.move = marker
        try savedOwner.save(at: layout.ownerState)
        let aFile = try layout.user(a), localFile = try layout.user(.local)
        try FileManager.default.createDirectory(at: aFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.prepareDatabase { db in try db.execute(sql: "ATTACH DATABASE ? AS usr", arguments: [aFile.path]) }
        let writer = try DatabasePool(path: layout.index.path, configuration: config)
        try DataV2Schema.prepare(writer, bundle: .main)
        try await writer.writeWithoutTransaction { db in
            try LocalScopeImport.withSource(db, url: localFile, readOnly: true) {
                try LocalScopeImport.copy(db, move: marker.id)
            }
        }
        try writer.close()

        let after = try DataSession(layout: layout)
        let (new, selection) = try await after.activate(.confirmed(b, syncRequested: false))
        #expect(selection.scope == b && !selection.maySync)
        let bRows = try await after.read(new) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.metadata_text_candidate") }
        #expect(bRows == 0)
        let (previous, _) = try await after.activate(.confirmed(a, syncRequested: false))
        let aValue = try await after.read(previous) { try String.fetchOne($0, sql: "SELECT value_text FROM usr.metadata_text_candidate") }
        #expect(aValue == "frozen local")
        let (out, _) = try await after.activate(.signedOut)
        let localRows = try await after.read(out) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.metadata_text_candidate") }
        #expect(localRows == 0)
        let recoveredOwner = try DataOwnerState.load(at: layout.ownerState)
        #expect(recoveredOwner.move == nil)
        try await after.close()
    }

}
