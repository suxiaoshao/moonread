import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
import Testing
@testable import Moonread

struct ReleasedReadingDataLayoutMigrationTests {
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
        let root = try dataV2MigrationSandbox()
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
        let root = try dataV2MigrationSandbox()
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
}
