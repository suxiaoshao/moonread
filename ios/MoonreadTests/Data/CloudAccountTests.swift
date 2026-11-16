import CryptoKit
import GRDB
import Observation
import SQLite3
import SwiftData
import SwiftUI
import Synchronization
import UIKit
import XCTest

@testable import Moonread

final class CloudAccountReaderIntegrationTests: ReaderIntegrationFixture {
  // S323: 当前账户发现失败不清空已知书架，旧账户/超时代次的晚到回调不得发布；两个确定事件顺序。
  @MainActor func testBuiltinDiscoveryFailureAndStaleAccountDoNotPublishEmpty() async throws {
    let (root, service, _, _, _, _, _, suite) = try singleBookFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let model = LibraryModel(
      service: service, prepareLibrary: {}, refreshLibrary: {},
      cloudDiscoveryRequired: true, adoptCloudDocuments: { _ in throw CocoaError(.fileReadUnknown) }
    )
    let old = model.discoveryGeneration
    model.failCloudDiscovery(old)  // Both query-start failure and the timeout use this boundary.
    XCTAssertEqual(model.builtinDiscovery, .unavailable)
    model.resetCloudDiscovery()
    XCTAssertNotEqual(model.discoveryGeneration, old)
    model.receiveCloudDiscovery(.init(generation: old, revision: 99, gathered: true, items: []))
    model.builtinDirectoryLoaded(generation: old, snapshotRevision: 99)
    model.failCloudDiscovery(old)
    XCTAssertEqual(model.builtinDiscovery, .discovering)
    XCTAssertEqual(model.discoveryRevision, 0)
    model.failCloudDiscovery(model.discoveryGeneration)
    XCTAssertEqual(model.builtinDiscovery, .unavailable)
    CloudDocumentQuery.shared.stop()
  }
}

final class CloudAccountCloudAccountTests: XCTestCase {
  @MainActor func testSyncStatusPresentsExistingActivityAndRecoveryFacts() {
    let cloud = CloudStore()
    XCTAssertEqual(cloud.syncTitle, String(localized: "阅读数据同步已关闭"))
    cloud.status = CloudSyncStatus(requested: true, activation: .awaitingAccountConfirmation(.init(recordName: "fixture"), revision: UUID(), message: "fixture"))
    XCTAssertEqual(cloud.syncTitle, String(localized: "需要确认同步账户"))
    cloud.status.activation = .unavailable("fixture")
    XCTAssertEqual(cloud.syncTitle, String(localized: "阅读数据同步已暂停"))
    cloud.status.activation = .enabled(.init(recordName: "fixture"), revision: UUID()); cloud.status.syncing = true; cloud.busy = true
    XCTAssertEqual(cloud.syncTitle, String(localized: "正在处理并同步"))
    cloud.busy = false
    XCTAssertEqual(cloud.syncTitle, String(localized: "正在同步"))
    cloud.status.syncing = false; cloud.status.transportMessage = "fixture error"
    XCTAssertEqual(cloud.syncTitle, String(localized: "同步需要处理"))
    cloud.status.transportMessage = nil
    XCTAssertEqual(cloud.syncTitle, String(localized: "阅读数据同步已开启"))
  }

    private static func require(_ ok: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(ok, message, file: file, line: line)
        if !ok { throw NSError(domain: message, code: 1) }
    }

    func testCancelsAndJoinsDirectLookup() async throws {
        let held = SyncLifecycleHeldLookup(), queue = OperationQueue()
        defer { held.release.signal() }
        let log = SyncLifecycleEvents()
        let query = Task {
            defer { held.sawCancel.continuation.finish() }
            do {
                let _: Int = try await ReadingCloudLookup.run(held, bind: { _ in }, submit: { queue.addOperation(held) })
                throw NSError(domain: "expected cancellation", code: 1)
            } catch is CancellationError {
                try Self.require(held.isFinished, "caller returned before operation finished")
                await log.add("lookup-return")
            }
        }
        for await _ in held.entered.stream { break }
        query.cancel()
        for await _ in held.sawCancel.stream { break }
        try Self.require(held.isCancelled && !held.isFinished, "actual Operation must receive cancel while running")
        try Self.require(await !log.entries.contains("lookup-return"), "cannot report drained while Operation is in flight")
        held.release.signal()
        try await query.value
    }

    func testWaitsForDrainAndRejectsStaleAccountConsent() async throws {
        let events = SyncLifecycleEvents(), backend = SyncLifecycleBackend(events)
        let suite = "SyncLifecycle-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let service = AppDataService(sourceDefaultsSuite: suite)
        let owner = CloudSyncCoordinator(service: service, runtime: .init(
            lookup: { await backend.lookup() },
            isApproved: { await backend.isApproved($0) },
            select: { await backend.bind($0, approval: $1) },
            open: { await backend.open($0) }))
        await owner.setEnabled(true)
        await events.wait("turn-A")
        await backend.holdNextLookup()
        let passive = Task { await owner.resume() }
        await events.wait("lookup-held")
        await backend.move(.confirmed(backend.b))
        let switchB = Task { await owner.identityChanged() }
        await events.wait("close-A")
        try Self.require(await !events.entries.contains("bind-b-off"), "must not switch while old transport closes")
        await events.add("allow-lookup")
        await passive.value
        await events.add("allow-close-A")
        await events.wait("drained-A")
        try Self.require(await !events.entries.contains("bind-b-off"), "must not switch before old turn returns")
        await events.add("allow-turn-A")
        await switchB.value
        let order = await events.entries
        try Self.require(order.firstIndex(of: "turn-ended-A")! < order.firstIndex(of: "bind-b-off")!,
                    "actual turn must finish before replacement scope binds")
        guard case .awaitingAccountConfirmation(let b, let old, _) = await owner.currentStatus().activation,
              b.recordName == "B" else { throw NSError(domain: "B consent not offered", code: 1) }
        try Self.require(!order.contains("open-B"), "B is locally selected without starting a transport")

        await backend.move(.confirmed(backend.c))
        await owner.confirmAccount("B", revision: old)
        guard case .awaitingAccountConfirmation(let c, let latest, _) = await owner.currentStatus().activation,
              c.recordName == "C" else { throw NSError(domain: "C consent not offered", code: 1) }
        await owner.confirmAccount("C", revision: old)
        try Self.require(await !events.entries.contains("approve-C"), "stale revision cannot approve C")
        await owner.confirmAccount("C", revision: latest)
        try Self.require(await events.entries.contains("open-C"), "matching explicit approval starts C")
        try Self.require(await !events.entries.contains("approve-B"), "stale B approval must never merge B")
        await owner.scene(active: false)
        try Self.require(await events.entries.contains("drained-C"), "background drains foreground transport")
        try Self.require(await events.entries.contains("paused"), "ordinary background suspends only network authority")
        try Self.require(await !events.entries.contains("unknown"), "ordinary background is not an identity failure")
        await owner.identityChanged()
        try Self.require(await events.entries.contains("unknown"), "an account event in background invalidates the confirmed scope")
        await backend.move(.signedOut)
        await owner.scene(active: true)
        let status = await owner.currentStatus()
        try Self.require(status.requested && !status.enabled, "sign-out must preserve explicit sync intent")
        try Self.require(await events.entries.contains("signout"), "explicit signout is distinct from unknown")
    }

    func testRelationalBindingRechecksD1AndSwitchesWithoutCopyingAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SyncBinding-" + UUID().uuidString)
        let suite = root.lastPathComponent
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let layout = DataLayout(applicationSupport: root)
        let session = try DataSession(layout: layout)
        let local = try session.activate(.signedOut).0
        try session.prepareIndex(root.appending(path: "unused"), token: local)
        try session.prepareUsers(local) { nil }
        try session.writeUsers(local) { try $0.execute(sql: "INSERT INTO usr.local_hidden_book VALUES ('fixture')") }
        let index = ReaderIndex(session: session, lease: local)
        let service = AppDataService(core: index, libraryDirectory: root, sourceDefaultsSuite: suite)
        let activity = SyncLifecycleEvents()
        let a = CloudSyncCoordinator.Account(identity: .init(recordName: "A"),
            scope: try .confirmed(container: "fixture.invalid", environment: .development, recordName: "A"))
        let b = CloudSyncCoordinator.Account(identity: .init(recordName: "B"),
            scope: try .confirmed(container: "fixture.invalid", environment: .development, recordName: "B"))
        service.cloudSyncIntent.set(true)

        let stale = Task {
            try await service.selectReadingCloudScope(.confirmed(a.scope, syncRequested: true), approval: a, lookup: {
                await activity.add("inside-write-gate")
                await activity.wait("release-stale-lookup")
                return .confirmed(a)
            })
        }
        await activity.wait("inside-write-gate")
        try Self.require(await service.userDataOperationBusy, "identity is rechecked inside the user writer gate")
        stale.cancel()
        await activity.add("release-stale-lookup")
        do { _ = try await stale.value; XCTFail("cancelled D1 selected") } catch is CancellationError { }
        try Self.require(try await service.relationalUserIndex().lease == local, "cancelled D1 retains the local authority")
        try Self.require(service.cloudSyncIntent.approvedScopeKey == nil, "cancelled D1 never persists consent")

        do {
            _ = try await service.selectReadingCloudScope(.confirmed(a.scope, syncRequested: true), approval: a,
                lookup: { .confirmed(b) })
            XCTFail("changed approval selected")
        } catch ReaderError.CloudAccountChanged { }
        let claimed = try await service.selectReadingCloudScope(.confirmed(a.scope, syncRequested: true),
            approval: a, lookup: { .confirmed(a) })
        let ownedA = try await service.relationalUserIndex()
        try Self.require(claimed.scope == a.scope && claimed.maySync && ownedA.session === session, "approved D1 uses the same pool owner")
        try Self.require(service.cloudSyncIntent.approvedScopeKey == a.scope.key, "persist only exact approved scope")
        try Self.require(try session.readUsers(ownedA.lease) { try String.fetchOne($0, sql: "SELECT book_key FROM usr.local_hidden_book") } == "fixture",
                    "D1 data belongs to A")

        let switched = try await service.selectReadingCloudScope(.confirmed(b.scope, syncRequested: false),
            approval: nil, lookup: { .confirmed(b) })
        let ownedB = try await service.relationalUserIndex()
        try Self.require(switched.scope == b.scope && !switched.maySync && ownedB.session === session, "B uses a distinct attached user file")
        try Self.require(try session.readUsers(ownedB.lease) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.local_hidden_book") } == 0,
                    "A contents cannot be claimed by B")
        _ = try await service.selectReadingCloudScope(.paused, approval: nil, lookup: { .unknown })
        try Self.require(await service.verifiedScopePublicationPending == false, "ordinary background keeps the latest confirmed shared scope")
        let offline = try await service.selectReadingCloudScope(.unknown, approval: nil, lookup: { .unknown })
        try Self.require(offline.scope == b.scope && !offline.maySync, "temporarily unknown still uses B")
        try Self.require(await service.verifiedScopePublicationPending == true, "unknown B stays out of shared snapshots")
        try Self.require(try await service.relationalUserIndex().lease == ownedB.lease, "temporarily unknown does not retire local reads")
        let signedOut = try await service.selectReadingCloudScope(.signedOut, approval: nil, lookup: { .signedOut })
        let returnedLocal = try await service.relationalUserIndex()
        try Self.require(signedOut.scope == .local, "confirmed sign-out selects local")
        try Self.require(try session.readUsers(returnedLocal.lease) { try Int.fetchOne($0, sql: "SELECT count(*) FROM usr.local_hidden_book") } == 0,
                    "the committed D1 source cannot be claimed again")
    }

    @MainActor func testRejectedAccountChangeKeepsDetailDraftUntilOriginalDiscardConfirmation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ScopeDraft-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try DataScope.confirmed(container: "fixture.invalid", environment: .development, recordName: "A")
        let b = try DataScope.confirmed(container: "fixture.invalid", environment: .development, recordName: "B")
        let session = try DataSession(layout: .init(applicationSupport: root), confirmedLegacyOwner: a)
        let old = try session.activate(.confirmed(a, syncRequested: false)).0
        try session.prepareIndex(root.appending(path: "unused"), token: old)
        try session.prepareUsers(old) { nil }
        let suite = root.lastPathComponent
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let service = AppDataService(core: .init(session: session, lease: old), libraryDirectory: root, sourceDefaultsSuite: suite)
        let info = BookInformationModel(service: service)
        let editors = UserScopeEditors()
        editors.track(info) { $0.blocksUserScopeChange }
        let invalidations = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: .readingContinuationInvalidated, object: service, queue: nil) { _ in
            invalidations.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let sha = String(repeating: "a", count: 64)
        let base = BookMetadata(sha: sha, author: "", synopsis: "", tags: [], cover: nil, status: .unread)
        let cover = BookCoverAsset(id: UUID().uuidString, sha256: sha, extension: "jpg", width: 1, height: 1)
        let coverFile = await service.coverDraftURL(cover)
        try FileManager.default.createDirectory(at: coverFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: coverFile.deletingLastPathComponent()) }
        let coverBytes = Data([1, 4, 9])
        try coverBytes.write(to: coverFile)
        let draft = BookMetadataDraft(base: base, service: service)
        info.draft = draft
        service.cloudSyncIntent.set(true)
        let accountB = CloudSyncCoordinator.Account(identity: .init(recordName: "B"), scope: b)
        let performHandoff: @MainActor () async throws -> DataScopeSelection = {
            try await service.selectReadingCloudScope(.confirmed(b, syncRequested: true), approval: accountB,
                lookup: { .confirmed(accountB) }, beforeRebind: { try editors.requireReady() })
        }
        func expectRefusal() async throws {
            do { _ = try await performHandoff(); XCTFail("dirty editor allowed switch") }
            catch CloudScopePresentationError.editing { }
            try Self.require(try await service.relationalUserIndex().lease == old, "refusal cannot replace the lease")
            try Self.require(invalidations.withLock { $0 } == 0 && info.draft === draft && info.requestRevision == 0,
                             "refusal cannot invalidate the model, navigation or draft")
            XCTAssertNil(service.cloudSyncIntent.approvedScopeKey)
        }

        let coverRead = SyncLifecycleEvents()
        let preparation = draft.chooseImage { () async -> Data? in await coverRead.wait("release"); return nil }
        try await expectRefusal()  // Includes loading from the picker, before decoding starts.
        await coverRead.add("release")
        await preparation?.value

        draft.saving = true
        try await expectRefusal()
        draft.saving = false

        draft.value.author = "fixture author"
        try await expectRefusal()
        XCTAssertEqual(draft.value.author, "fixture author")
        draft.value.author = base.author
        draft.value.cover = cover
        try await expectRefusal()  // Cover-only changes are an independent blocker.
        XCTAssertEqual(draft.value.cover, cover)
        XCTAssertEqual(try Data(contentsOf: coverFile), coverBytes)

        guard case .confirmDiscard = draft.requestLeave() else { return XCTFail("existing cancel must prompt before discarding") }
        try await expectRefusal()  // Cancelling the existing alert has no effect.
        XCTAssertEqual(try Data(contentsOf: coverFile), coverBytes)
        let discard = draft.cancel()  // Same action as the alert's destructive button.
        await discard?.value
        info.draft = nil             // Sheet's binding releases the discarded draft.
        let selected = try await performHandoff()
        XCTAssertEqual(selected.scope, b)
        XCTAssertTrue(selected.maySync)
        XCTAssertEqual(invalidations.withLock { $0 }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverFile.path))
    }

    #if DEBUG
    @MainActor func testWholeBookDeletesPresentLegacyMirrorBeforeNewUserCommit() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, service) = try fixture.open()
        try fixture.seed(index)
        let account = try CloudCallbackJournal(session: index.session, lease: index.lease)
        try await account.initializeZone(exists: true)
        let book = ZoneRecoveryFixture.book, other = String(repeating: "b", count: 64)
        let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
        let mirror = store.container
        let context = ModelContext(mirror)
        let shared = Data("shared".utf8), exclusive = Data("exclusive".utf8)
        func cover(_ key: String, device: String, id: String, bytes: Data) throws {
            let ref = "{\"id\":\"\(id)\",\"sha256\":\"\(DataIdentity.sha(bytes))\",\"extension\":\"png\",\"width\":1,\"height\":1}"
            let stored = StoredValue(updated: 1, token: device, value: ref)
            context.insert(UserValue(key: "metadata/\(key)/cover", device: device, payload: try UserSyncJSON.encode(stored, envelope: true)))
        }
        context.insert(UserCover(id: "shared", bytes: shared))
        context.insert(UserCover(id: "exclusive", bytes: exclusive))
        try cover(book, device: "a", id: "shared", bytes: shared)
        try cover(book, device: "b", id: "exclusive", bytes: exclusive)
        try cover(other, device: "c", id: "shared", bytes: shared)
        context.insert(UserValue(key: "metadata/\(book)/future", device: "a", payload: "{}"))
        context.insert(UserValue(key: "metadata/pending:fixture/future", device: "a", payload: "{}"))
        context.insert(UserValue(key: "future/\(book)/global", device: "a", payload: "{}"))
        context.insert(UserPosition(contentKey: book, payload: "unreadable future position"))
        context.insert(AnnotationOperation(id: "old", contentKey: book, markID: "old", payload: "{}"))
        context.insert(ReadingFact(id: "old", contentKey: book, payload: "{}"))
        context.insert(StatisticsClear(payload: "{\"v\":999,\"book\":\"\(book)\"}"))
        context.insert(StatisticsClear(payload: "{\"v\":999,\"book\":42}"))
        try context.save()

        try await account.requireLegacyBridge()
        try await account.bindLegacyDeletionMirror(store)
        do {
            _ = try index.deleteUserBooks([book], activeReadingIDs: ["unavailable-active-book"]) { ReadingDataError.busy }
            XCTFail("old mirror must never commit before the reading check")
        } catch ReadingDataError.busy { }
        XCTAssertEqual(try ModelContext(mirror).fetchCount(FetchDescriptor<UserPosition>()), 1)
        _ = try await service.deleteReadingData(["pending:fixture"])
        XCTAssertEqual(try ModelContext(mirror).fetchCount(FetchDescriptor<UserValue>()), 6)
        account.retire()
        do {
            _ = try await service.deleteReadingData([book])
            XCTFail("paused authority must not silently delete only the new side")
        } catch ReadingDataError.legacyDeletionUnavailable { }
        XCTAssertEqual(try fixture.state(index).formal, 1)
        XCTAssertEqual(try ModelContext(mirror).fetchCount(FetchDescriptor<UserPosition>()), 1)

        let replacement = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { replacement.retire() }
        try await replacement.bindLegacyDeletionMirror(store)
        _ = try await service.deleteReadingData([book])
        let read = ModelContext(mirror)
        XCTAssertEqual(Set(try read.fetch(FetchDescriptor<UserCover>()).map(\.id)), ["shared"])
        XCTAssertEqual(Set(try read.fetch(FetchDescriptor<UserValue>()).map(\.key)), [
            "metadata/\(other)/cover", "metadata/pending:fixture/future", "future/\(book)/global",
        ])
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<UserPosition>()), 0)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<AnnotationOperation>()), 0)
        XCTAssertEqual(try read.fetchCount(FetchDescriptor<ReadingFact>()), 0)
        XCTAssertEqual(try read.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload), ["{\"v\":999,\"book\":42}"])
        let deletes = try await replacement.pendingInOwnZone()
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(deletes.allSatisfy { !$0.isSave })
        XCTAssertEqual(try fixture.state(index).formal, 0)
    }

    @MainActor func testWholeBookRetryAfterOnlyLegacyCommitNeverRestoresOldRows() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, _) = try fixture.open()
        try fixture.seed(index)
        let book = ZoneRecoveryFixture.book
        let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
        let mirror = store.container
        do {
            let context = ModelContext(mirror)
            context.insert(UserPosition(contentKey: book, payload: "{}"))
            try context.save()
        }
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        try await journal.initializeZone(exists: true)
        try await journal.requireLegacyBridge()
        try await journal.bindLegacyDeletionMirror(store)
        let before = try fixture.state(index)
        try index.session.writeUsers(index.lease) { db in
            try db.execute(sql: """
                CREATE TRIGGER usr.fixture_deny_delete BEFORE DELETE ON position_candidate
                BEGIN SELECT RAISE(ABORT, 'fixture denies new commit'); END
                """)
        }
        do {
            _ = try index.deleteUserBooks([book], activeReadingIDs: []) { ReadingDataError.busy }
            XCTFail("new transaction was expected to fail after the old save")
        } catch ReadingDataError.legacyDeletedTryAgain { }
        XCTAssertEqual(try ModelContext(mirror).fetchCount(FetchDescriptor<UserPosition>()), 0)
        XCTAssertEqual(try fixture.state(index), before, "the new candidate and outbox rolled back together")
        try index.session.writeUsers(index.lease) { try $0.execute(sql: "DROP TRIGGER usr.fixture_deny_delete") }
        _ = try index.deleteUserBooks([book], activeReadingIDs: []) { ReadingDataError.busy }
        XCTAssertEqual(try ModelContext(mirror).fetchCount(FetchDescriptor<UserPosition>()), 0)
        XCTAssertEqual(try fixture.state(index).formal, 0)
        XCTAssertEqual(try fixture.state(index).pending, 1)
    }

    @MainActor func testLegacyMirrorObligationSurvivesReopenAndResetClosesIt() async throws {
        for reason in [CloudTransportRows.ZoneDeletion.purged, .encryptedDataReset] {
            let fixture = try ZoneRecoveryFixture()
            defer { fixture.remove() }
            let (first, _) = try fixture.open()
            let owner = try CloudCallbackJournal(session: first.session, lease: first.lease)
            try await owner.initializeZone(exists: true)
            try fixture.seed(first)
            try await owner.requireLegacyBridge() // Process exits before the container opens.
            owner.retire()
            try first.session.close()

            let (index, service) = try fixture.open()
            let book = ZoneRecoveryFixture.book
            do {
                _ = try await service.deleteReadingData([book])
                XCTFail("an empty binding after restart must not authorize a one-sided deletion")
            } catch ReadingDataError.legacyDeletionUnavailable { }
            XCTAssertEqual(try fixture.state(index).formal, 1)
            let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
            let foreign = try DataScope.confirmed(container: "fixture.invalid", environment: .development, recordName: "fixture-B")
            let wrongAccount = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: foreign)
            let otherRoot = DataLayout(applicationSupport: fixture.root.appending(path: "different-data-root"))
            let wrongFile = try LegacyMirrorStore.localFixture(layout: otherRoot, scope: index.lease.scope)
            for store in [wrongAccount, wrongFile] {
                do {
                    try await journal.bindLegacyDeletionMirror(store)
                    XCTFail("journal scope alone cannot authorize a foreign mirror")
                } catch DataV2Error.leaseExpired { }
            }
            let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
            try await journal.bindLegacyDeletionMirror(store)
            let context = ModelContext(store.container)
            context.insert(UserPosition(contentKey: book, payload: "old bytes"))
            try context.save()
            let signal = try await journal.holdZoneDeletion(reason)
            XCTAssertEqual(signal, .resetPending)
            do {
                try await journal.bindLegacyDeletionMirror(store)
                XCTFail("a reset notice already closes old intake")
            } catch LegacyBridgePolicy.Failure.notReady { }
            do {
                _ = try await service.deleteReadingData([book])
                XCTFail("a reset notice must not mutate the old mirror")
            } catch ReadingDataError.legacyDeletionUnavailable { }
            journal.retire()
            let recovered = try await service.recoverReadingCloudZone(fixture.account, presence: nil, lookup: { .confirmed(fixture.account) })
            XCTAssertEqual(recovered, .reset)
            XCTAssertEqual(try fixture.state(index).formal, 0)
            XCTAssertEqual(try fixture.state(index).pending, 1)
            XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<UserPosition>()), 1)
            try index.session.close()

            let (after, _) = try fixture.open()
            let stranded = try CloudCallbackJournal(session: after.session, lease: after.lease)
            defer { stranded.retire() }
            do {
                try await stranded.requireLegacyBridge()
                XCTFail("old bytes must not reactivate the account's finished bridge")
            } catch LegacyBridgePolicy.Failure.finished { }
            XCTAssertEqual(try after.session.readUsers(after.lease) { try LegacyBridgePolicy.phase($0) }, .finished)
            XCTAssertEqual(try fixture.state(after).outbox, 0)
        }
    }

    @MainActor func testExplicitLegacyBridgeFinishDisablesOldMutationsWithoutDeletingMirror() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, service) = try fixture.open()
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        try await journal.initializeZone(exists: true)
        try fixture.seed(index)
        try await journal.requireLegacyBridge()
        let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
        try await journal.bindLegacyDeletionMirror(store)
        let book = ZoneRecoveryFixture.book
        let context = ModelContext(store.container)
        context.insert(UserPosition(contentKey: book, payload: "legacy evidence"))
        try context.save()
        try await journal.finishLegacyBridgeAfterUpgrade()
        do {
            try await journal.requireLegacyBridge()
            XCTFail("reopening the engine does not undo explicit bridge retirement")
        } catch LegacyBridgePolicy.Failure.finished { }
        _ = try await service.deleteReadingData([book])
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<UserPosition>()), 1)
        XCTAssertEqual(try fixture.state(index).formal, 0)
    }

    @MainActor func testLegacyMirrorConsumesHistoryWithAtomicCursorAndExactDeletion() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, service) = try fixture.open(requireBridge: true)
        let book = ZoneRecoveryFixture.book, other = String(repeating: "b", count: 64)
        let firstKey = "metadata/\(book)/author", secondKey = "metadata/\(other)/author"
        let first = try UserValueRows.Key(firstKey), second = try UserValueRows.Key(secondKey)
        let firstID = UserValueRows.recordID(logical: first.logical, device: "device")
        let secondID = UserValueRows.recordID(logical: second.logical, device: "device")
        func state() throws -> (String?, Int, Int) {
            try index.session.readUsers(index.lease) { db in
                (try String.fetchOne(db, sql: "SELECT value FROM usr.local_data_state WHERE state_key=?",
                                     arguments: [LegacyUserImport.mirrorCursor]),
                 try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.metadata_text_candidate") ?? -1,
                 try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cloud_outbox") ?? -1)
            }
        }
        func payload(_ updated: Int64, _ token: String, _ value: String) throws -> String {
            try UserSyncJSON.encode(StoredValue(updated: updated, token: token, value: UserSyncJSON.encode(value)), envelope: true)
        }
        do {
            _ = try await service.deleteReadingData([book])
            XCTFail("the first call before the engine must honor W1")
        } catch ReadingDataError.legacyDeletionUnavailable { }
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        try await journal.initializeZone(exists: true)
        let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
        try await journal.bindLegacyDeletionMirror(store)
        let context = ModelContext(store.container)
        let a = UserValue(key: firstKey, device: "device", payload: try payload(1, "old-a", "A"))
        let b = UserValue(key: secondKey, device: "device", payload: try payload(1, "old-b", "B"))
        context.insert(a); context.insert(b)
        try context.save()

        try index.session.writeUsers(index.lease) { db in
            try db.execute(sql: """
                CREATE TRIGGER usr.fail_bridge_link BEFORE INSERT ON legacy_mirror_link
                BEGIN SELECT RAISE(ABORT, 'fixture'); END
                """)
        }
        do {
            _ = try await journal.consumeLegacyMirrorPage()
            XCTFail("bridge must roll back prior mutations with failed link/cursor")
        } catch is DatabaseError { }
        let failed = try state()
        XCTAssertNil(failed.0); XCTAssertEqual(failed.1, 0); XCTAssertEqual(failed.2, 0)
        try index.session.writeUsers(index.lease) { try $0.execute(sql: "DROP TRIGGER usr.fail_bridge_link") }
        let consumed = try await journal.consumeLegacyMirrorPage()
        XCTAssertTrue(consumed)
        let committed = try state()
        XCTAssertNotNil(committed.0); XCTAssertEqual(committed.1, 2); XCTAssertEqual(committed.2, 2)
        let empty = try await journal.consumeLegacyMirrorPage()
        XCTAssertFalse(empty)
        XCTAssertEqual(try state().0, committed.0)

        // Change the same slot in the new authority after importing it.
        _ = try index.session.writeUsers(index.lease) { db in
            try UserValueRows.put(db, key: first, value: UserSyncJSON.encode("New A"), device: "device", now: 9,
                                  scope: index.lease.scope)
        }
        context.delete(a); context.delete(b)
        try context.save()
        let removed = try await journal.consumeLegacyMirrorPage()
        XCTAssertTrue(removed)
        let remaining = try index.session.readUsers(index.lease) {
            try String.fetchAll($0, sql: "SELECT record_id FROM usr.metadata_text_candidate ORDER BY record_id")
        }
        XCTAssertEqual(remaining, [firstID])
        let pending = try await journal.pendingInOwnZone()
        XCTAssertEqual(Set(pending.filter { !$0.isSave }.map(\.businessID)), [secondID])
        XCTAssertEqual(Set(pending.filter(\.isSave).map(\.businessID)), [firstID])

        context.insert(UserValue(key: secondKey, device: "device", payload: try payload(10, "late", "Late")))
        try context.save()
        let floor = try state().0
        _ = try await journal.holdZoneDeletion(.purged)
        do {
            _ = try await journal.consumeLegacyMirrorPage()
            XCTFail("old data must not advance any cursor or pending write after reset evidence")
        } catch LegacyBridgePolicy.Failure.notReady { }
        XCTAssertEqual(try state().0, floor)
        XCTAssertEqual(try state().1, 1)
        let withheld = try await journal.pendingInOwnZone()
        XCTAssertTrue(withheld.isEmpty)
    }

    @MainActor func testLegacyMirrorDeletingFixedWinnerFindsOlderLiveObject() async throws {
        for olderFirst in [true, false] {
            let fixture = try ZoneRecoveryFixture()
            defer { fixture.remove() }
            let (index, _) = try fixture.open(requireBridge: true)
            let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
            defer { journal.retire() }
            try await journal.initializeZone(exists: true)
            let store = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
            try await journal.bindLegacyDeletionMirror(store)
            let context = ModelContext(store.container)
            let key = "metadata/\(ZoneRecoveryFixture.book)/author"
            let id = UserValueRows.recordID(logical: key, device: "same-device")
            func value(_ name: String, at time: Int64) throws -> UserValue {
                let body = try UserSyncJSON.encode(name)
                let payload = try UserSyncJSON.encode(StoredValue(updated: time, token: name, value: body), envelope: true)
                return UserValue(key: key, device: "same-device", payload: payload)
            }
            func current() throws -> String? {
                try index.session.readUsers(index.lease) {
                    try String.fetchOne($0, sql: "SELECT value_text FROM usr.metadata_text_candidate WHERE partition=0 AND record_id=?",
                                        arguments: [id])
                }
            }
            let a = try value("A", at: 1), b = try value("B", at: 2)
            for object in (olderFirst ? [a,b] : [b,a]) {
                context.insert(object)
                try context.save()
                let consumed = try await journal.consumeLegacyMirrorPage()
                XCTAssertTrue(consumed)
            }
            XCTAssertEqual(try current(), "B")
            context.delete(b)
            try context.save()
            let consumed = try await journal.consumeLegacyMirrorPage()
            XCTAssertTrue(consumed)
            XCTAssertEqual(try current(), "A", "Deleting B must rediscover surviving A (olderFirst=\(olderFirst))")
            let pending = try await journal.pendingInOwnZone()
            XCTAssertEqual(pending.filter { $0.businessID == id }.map(\.isSave), [true])

            // Removing another winning object must not rediscover A if the
            // same fixed slot already has a durable new-zone DELETE.
            let c = try value("C", at: 3)
            context.insert(c)
            try context.save()
            let changed = try await journal.consumeLegacyMirrorPage()
            XCTAssertTrue(changed)
            XCTAssertEqual(try current(), "C")
            let cloud = FixedValueCloudRows.key(.author, id: id)
            try index.session.writeUsers(index.lease) { try CloudTransportRows.enqueueDelete($0,cloud,businessID: id) }
            let before = try index.session.readUsers(index.lease) { try CloudTransportRows.pending($0,cloud)?.generation }
            context.delete(c)
            try context.save()
            let blocked = try await journal.consumeLegacyMirrorPage()
            XCTAssertTrue(blocked)
            XCTAssertNil(try current())
            let after = try index.session.readUsers(index.lease) { try CloudTransportRows.pending($0,cloud)?.generation }
            XCTAssertEqual(after, before)
            let fenced = try await journal.pendingInOwnZone()
            XCTAssertEqual(fenced.filter { $0.businessID == id }.map(\.isSave), [false])
        }
    }

    @MainActor func testLegacyMirrorSchemaUpgradePreservesExistingAccountRows() throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (old, _) = try fixture.open()
        try fixture.seed(old)
        let path = try old.session.layout.user(old.lease.scope)
        try old.session.close()
        do {
            let db = try DatabaseQueue(path: path.path)
            try db.write { try $0.execute(sql: "DROP TABLE legacy_mirror_link; PRAGMA user_version=2;") }
        }
        let (index, _) = try fixture.open(requireBridge: true)
        let migrated = try index.session.readUsers(index.lease) { db in
            (try Int.fetchOne(db, sql: "PRAGMA usr.user_version"),
             try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.legacy_mirror_link"),
             try LegacyBridgePolicy.phase(db))
        }
        XCTAssertEqual(migrated.0, 3); XCTAssertEqual(migrated.1, 0); XCTAssertEqual(migrated.2, .required)
        XCTAssertEqual(try fixture.state(index).formal, 1)
        XCTAssertEqual(try fixture.state(index).pending, 1)
    }

    @MainActor func testLegacyMirrorIntakesSixModelsAndSendsCoverOnlyOnceAvailable() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, _) = try fixture.open(requireBridge: true)
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        try await journal.initializeZone(exists: true)
        let mirror = try LegacyMirrorStore.localFixture(layout: index.session.layout, scope: index.lease.scope)
        try await journal.bindLegacyDeletionMirror(mirror)
        let context = ModelContext(mirror.container)
        let book = ZoneRecoveryFixture.book
        let coverID = "legacy-asset", bytes = Data("synthetic cover".utf8)
        func stored(_ encoded: String) throws -> String {
            try UserSyncJSON.encode(StoredValue(updated: 1, token: "old-token", value: encoded), envelope: true)
        }
        let cover = "{\"id\":\"\(coverID)\",\"sha256\":\"\(DataIdentity.sha(bytes))\",\"extension\":\"png\",\"width\":1,\"height\":1}"
        context.insert(UserValue(key: "metadata/\(book)/cover", device: "device", payload: try stored(cover)))
        context.insert(UserValue(key: "new-namespace/independent", device: "device", payload: "{}"))
        let position = PositionValue(content_key: book, offset: 12, source_hint: nil)
        context.insert(UserPosition(contentKey: book, payload: try stored(UserSyncJSON.encode(position))))
        let note = AnnotationCandidate(id: "old-note", ancestors: [], content: .init(start: 1, end: 2, excerpt: "", note: "fixture"),
                                       created: 1, bookmark: false)
        context.insert(AnnotationOperation(id: note.id, contentKey: book, markID: "old-mark", payload: try UserSyncJSON.encode(note, envelope: true)))
        let fact = ReadingSlice(id: "old-fact", sessionId: "old-session", visitId: "visit", bookId: "legacy",
            startedMs: 12, endedMs: 42, localDay: 20260101, utcOffsetSeconds: 0, preview: false, exposures: [])
        context.insert(ReadingFact(id: fact.id, contentKey: book,
            payload: try encodeReadingFact(contentKey: book, title: "", device: "old-device", slice: fact)))
        let clear = ClearValue(book: book, session: "old-session", through: 50, ids: ["old-fact"])
        context.insert(StatisticsClear(payload: try UserSyncJSON.encode(clear, envelope: true)))
        try context.save()
        let first = try await journal.consumeLegacyMirrorPage()
        XCTAssertTrue(first)
        let intents = try await journal.pendingInOwnZone()
        XCTAssertEqual(Set(intents.map(\.key.type)), ["ReadingPosition", "AnnotationOperation", "StatisticsClear"])
        let counts = try index.session.readUsers(index.lease) { db in
            try ["position_candidate", "annotation_current_head", "reading_fact", "reading_fact_current",
                 "statistics_clear", "quarantined_record"].map { try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.\($0)") }
        }
        XCTAssertEqual(counts, [1, 1, 1, 0, 1, 1], "Clear suppresses the old fact before this transaction is observable")

        context.insert(UserCover(id: coverID, bytes: bytes))
        try context.save()
        let second = try await journal.consumeLegacyMirrorPage()
        XCTAssertTrue(second)
        let pending = try await journal.pendingInOwnZone()
        XCTAssertEqual(pending.filter { $0.key.type == "BookCover" && $0.isSave }.count, 1)
    }

    func testLegacyUpgradeConfirmationCannotRetireAfterSuspension() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, service) = try fixture.open(requireBridge: true)
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        defer { journal.retire() }
        try await journal.initializeZone(exists: true)
        let control = SyncLifecycleEvents()
        let handle = LegacyUpgradeFixtureTransport(journal: journal, control: control)
        let owner = CloudSyncCoordinator(service: service, runtime: .init(
            lookup: { .confirmed(fixture.account) }, isApproved: { _ in true },
            select: { _, _ in .init(scope: fixture.account.scope, maySync: true) },
            open: { _ in handle }
        ))
        await owner.setEnabled(true)
        guard let original = await owner.currentStatus().legacyUpgradeRevision else {
            return XCTFail("eligible upgrade control is missing")
        }
        let suspended = Task { try await owner.confirmLegacyUpgrade(revision: original) }
        await control.wait("before-writer")
        await owner.scene(active: false)
        await control.add("resume-writer")
        do { try await suspended.value; XCTFail("old revision was not cancelled at the writer") }
        catch is CancellationError { }
        let active = try await journal.isLegacyBridgeActive()
        XCTAssertTrue(active)
        let pausedPrompt = await owner.currentStatus().legacyUpgradeRevision
        XCTAssertNil(pausedPrompt)
        await owner.scene(active: true)
        guard let fresh = await owner.currentStatus().legacyUpgradeRevision else {
            return XCTFail("current eligible upgrade control is missing")
        }
        XCTAssertTrue(fresh != original)
        try await owner.confirmLegacyUpgrade(revision: fresh)
        let phase = try await journal.legacyBridgePhase()
        XCTAssertEqual(phase, .finished)
        let finishedPrompt = await owner.currentStatus().legacyUpgradeRevision
        XCTAssertNil(finishedPrompt)
    }
    #endif

    func testZoneRecoveryRequiresDurableDeletionAndExactAbsence() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (index, service) = try fixture.open()
        let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
        try await journal.initializeZone(exists: true)
        try await journal.persistCheckpoint(Data([21]))
        try fixture.seed(index)

        do {
            _ = try await service.recoverReadingCloudZone(fixture.account, presence: .absent, lookup: { .confirmed(fixture.account) })
            XCTFail("a live engine must not share the recovery writer")
        } catch DataV2Error.leaseExpired { }
        journal.retire()
        let before = try fixture.state(index)
        let hint = try await service.recoverReadingCloudZone(fixture.account, presence: .absent, lookup: { .confirmed(fixture.account) })
        XCTAssertEqual(hint, .awaitingEvidence)
        XCTAssertEqual(try fixture.state(index), before)
        let present = try await service.recoverReadingCloudZone(fixture.account, presence: .present, lookup: { .confirmed(fixture.account) })
        XCTAssertEqual(present, .resume)
        XCTAssertEqual(try fixture.state(index), before)

        let events = try CloudCallbackJournal(session: index.session, lease: index.lease)
        let event = try await events.holdZoneDeletion(.deleted)
        XCTAssertEqual(event, .verificationRequired)
        events.retire()
        let conflict = try await service.recoverReadingCloudZone(fixture.account, presence: .present, lookup: { .confirmed(fixture.account) })
        XCTAssertEqual(conflict, .awaitingEvidence)
        let held = try fixture.state(index)
        XCTAssertEqual(held.stage, .deletedPending)
        XCTAssertEqual(held.checkpoint, before.checkpoint)
        XCTAssertEqual(held.outbox, before.outbox)

        let rebuilt = try await service.recoverReadingCloudZone(fixture.account, presence: .absent, lookup: { .confirmed(fixture.account) })
        XCTAssertEqual(rebuilt, .rebuild)
        let rebuiltState = try fixture.state(index)
        XCTAssertEqual(rebuiltState.stage, .needsCreation)
        XCTAssertNil(rebuiltState.checkpoint)
        XCTAssertEqual(rebuiltState.formal, before.formal)
        XCTAssertEqual(rebuiltState.pending, before.pending)
        XCTAssertEqual(rebuiltState.outbox, before.outbox)
        let newEngine = try CloudCallbackJournal(session: index.session, lease: index.lease)
        let beforeCreation = try await newEngine.pendingInOwnZone()
        XCTAssertTrue(beforeCreation.isEmpty)
        let created = try await newEngine.confirmZoneCreation()
        XCTAssertTrue(created)
        let ready = try await newEngine.pendingInOwnZone()
        XCTAssertEqual(ready.count, before.outbox)
        newEngine.retire()
        try index.session.close()
    }

    func testZoneResetSurvivesRefusalRestartAndWrongAccountWithoutResending() async throws {
        for reason in [CloudTransportRows.ZoneDeletion.purged, .encryptedDataReset] {
            let fixture = try ZoneRecoveryFixture()
            defer { fixture.remove() }
            let (index, service) = try fixture.open()
            let journal = try CloudCallbackJournal(session: index.session, lease: index.lease)
            try await journal.initializeZone(exists: true)
            try await journal.persistCheckpoint(Data([22]))
            try fixture.seed(index)
            _ = try await journal.holdZoneDeletion(.deleted)
            let resetSignal = try await journal.holdZoneDeletion(reason)
            XCTAssertEqual(resetSignal, .resetPending)
            _ = try await journal.holdZoneDeletion(.deleted)  // A later weaker reason cannot win.
            do { try await journal.persistCheckpoint(Data([99])); XCTFail("advanced held checkpoint") }
            catch CloudCallbackJournal.Failure.restartRequired { }
            journal.retire()
            do {
                _ = try await service.recoverReadingCloudZone(fixture.account, presence: nil, lookup: { .confirmed(fixture.account) },
                    beforeClear: { throw CloudScopePresentationError.editing })
                XCTFail("purge bypassed the editor guard")
            } catch CloudScopePresentationError.editing { }
            let held = try fixture.state(index)
            XCTAssertTrue(held.stage.requiresLocalClear)
            XCTAssertEqual(held.checkpoint, Data([22]))
            XCTAssertEqual(held.formal, 1)
            XCTAssertGreaterThan(held.outbox, 0)
            try index.session.close()

            let (reopened, owner) = try fixture.open()
            XCTAssertEqual(try fixture.state(reopened), held)
            let other = CloudSyncCoordinator.Account(identity: .init(recordName: "fixture-B"),
                scope: try .confirmed(container: "fixture.invalid", environment: .development, recordName: "fixture-B"))
            do {
                _ = try await owner.recoverReadingCloudZone(fixture.account, presence: nil, lookup: { .confirmed(other) })
                XCTFail("old account evidence crossed the identity check")
            } catch ReaderError.CloudAccountChanged { }
            XCTAssertEqual(try fixture.state(reopened), held)
            let reset = try await owner.recoverReadingCloudZone(fixture.account, presence: nil, lookup: { .confirmed(fixture.account) })
            XCTAssertEqual(reset, .reset)
            let after = try fixture.state(reopened)
            XCTAssertEqual(after.stage, .reset)
            XCTAssertNil(after.checkpoint)
            XCTAssertEqual(after.formal, 0)
            XCTAssertEqual(after.pending, held.pending)
            XCTAssertEqual(after.outbox, 0)
            try reopened.session.close()
        }
    }

    func testZoneRecoveryStopsOldHandleBeforeProbeAndRestartsOnlyOnce() async throws {
        let fixture = try ZoneRecoveryFixture()
        defer { fixture.remove() }
        let (_, service) = try fixture.open()
        let trace = ZoneOwnerTrace()
        let signals = AsyncStream<Void>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: .readingCloudStatusChanged, object: nil, queue: nil) { _ in
            signals.continuation.yield()
        }
        defer { NotificationCenter.default.removeObserver(observer); signals.continuation.finish() }
        let account = fixture.account
        let coordinator = CloudSyncCoordinator(service: service, runtime: .init(
            lookup: { .confirmed(account) }, isApproved: { _ in true },
            select: { _, _ in .init(scope: account.scope, maySync: true) },
            open: { _ in await trace.open() },
            zoneRecovery: .init(probe: { _ in await trace.record("probe"); return .absent },
                                apply: { _, _ in await trace.record("apply"); return .rebuild })))
        await coordinator.setEnabled(true)
        for await _ in signals.stream {
            if case .unavailable = await coordinator.currentStatus().activation { break }
        }
        let events = await trace.events
        XCTAssertEqual(events, ["open-1","send-1","close-1","probe","apply","open-2","send-2","close-2"])
    }
}

private actor ZoneOwnerTrace {
    private(set) var events = [String]()
    private var opened = 0
    func record(_ event: String) { events.append(event) }
    func open() -> ZoneRecoveryTestTransport {
        opened += 1
        record("open-\(opened)")
        return .init(id: opened, trace: self)
    }
}
private struct ZoneRecoveryTestTransport: ReadingCloudTransport {
    let id: Int
    let trace: ZoneOwnerTrace
    func syncNow() async throws {
        await trace.record("send-\(id)")
        throw CloudZoneRecoverySignal.verificationRequired
    }
    func close() async { await trace.record("close-\(id)") }
}

private struct ZoneRecoveryFixture: Sendable {
    struct State: Equatable, Sendable {
        let stage: CloudTransportRows.ZoneStage
        let checkpoint: Data?
        let formal, pending, outbox: Int
    }
    let root = FileManager.default.temporaryDirectory.appending(path: "ScopeZone-" + UUID().uuidString)
    let account: CloudSyncCoordinator.Account
    static let book = String(repeating: "a", count: 64)
    init() throws {
        account = .init(identity: .init(recordName: "fixture-A"),
            scope: try .confirmed(container: "fixture.invalid", environment: .development, recordName: "fixture-A"))
    }
    func open(requireBridge: Bool = false) throws -> (ReaderIndex, AppDataService) {
        let session = try DataSession(layout: .init(applicationSupport: root), confirmedLegacyOwner: account.scope,
                                      legacyBridgeScope: requireBridge ? account.scope : nil)
        let lease = try session.activate(.confirmed(account.scope, syncRequested: true)).0
        try session.prepareIndex(root.appending(path: "unused"), token: lease)
        try session.prepareUsers(lease) { nil }
        let index = ReaderIndex(session: session, lease: lease)
        let service = AppDataService(core: index, libraryDirectory: root, sourceDefaultsSuite: root.lastPathComponent)
        service.cloudSyncIntent.set(true)
        service.cloudSyncIntent.approve(account.scope)
        return (index, service)
    }
    func remove() {
        UserDefaults(suiteName: root.lastPathComponent)?.removePersistentDomain(forName: root.lastPathComponent)
        try? FileManager.default.removeItem(at: root)
    }
    func seed(_ index: ReaderIndex) throws {
        try index.session.writeUsers(index.lease) { db in
            _ = try ReadingPositionRows.recordPosition(db, book: Self.book, offset: 12, hint: nil, file: nil,
                device: "fixture", now: 1, token: "fixture-formal", scope: account.scope)
            _ = try ReadingPositionRows.recordPosition(db, book: "pending:fixture", offset: 24, hint: nil, file: nil,
                device: "fixture", now: 2, token: "fixture-pending", scope: account.scope)
        }
    }
    func state(_ index: ReaderIndex) throws -> State {
        try index.session.readUsers(index.lease) { db in
            let zone = ReadingHistoryTransport.zone
            return State(stage: try CloudTransportRows.zoneStage(db, zone: zone),
                checkpoint: try CloudTransportRows.checkpoint(db, zone: zone),
                formal: try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.position_candidate WHERE partition=0")!,
                pending: try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.position_candidate WHERE partition=1")!,
                outbox: try Int.fetchOne(db, sql: "SELECT count(*) FROM usr.cloud_outbox WHERE zone=?", arguments: [zone])!)
        }
    }
}

private actor SyncLifecycleEvents {
    private(set) var entries: [String] = []
    var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func add(_ value: String) {
        entries.append(value)
        waiters.removeValue(forKey: value)?.forEach { $0.resume() }
    }
    func wait(_ value: String) async {
        if !entries.contains(value) { await withCheckedContinuation { waiters[value, default: []].append($0) } }
    }
}
private actor LegacyUpgradeFixtureTransport: ReadingCloudTransport {
    let journal: CloudCallbackJournal
    let control: SyncLifecycleEvents
    var holdFirst = true
    init(journal: CloudCallbackJournal, control: SyncLifecycleEvents) { self.journal = journal; self.control = control }
    func syncNow() async throws {}
    // The fixture deliberately leaves the lease current; cancellation alone
    // must prevent an already queued confirmation from committing.
    func close() async {}
    func isLegacyBridgeActive() async throws -> Bool { try await journal.isLegacyBridgeActive() }
    func finishLegacyBridgeAfterUpgrade(check: @Sendable () throws -> Void) async throws {
        if holdFirst {
            holdFirst = false
            await control.add("before-writer")
            await control.wait("resume-writer")
        }
        try await journal.finishLegacyBridgeAfterUpgrade(check: check)
    }
}
private actor SyncLifecycleTransport: ReadingCloudTransport {
    let name: String
    let events: SyncLifecycleEvents
    init(_ name: String, _ events: SyncLifecycleEvents) { self.name = name; self.events = events }
    func syncNow() async throws {
        await events.add("turn-" + name)
        if name == "A" { await events.wait("allow-turn-A") }
        await events.add("turn-ended-" + name)
        try Task.checkCancellation()
    }
    func close() async {
        await events.add("close-" + name)
        if name == "A" { await events.wait("allow-close-A") }
        await events.add("drained-" + name)
    }
}
private actor SyncLifecycleBackend {
    let events: SyncLifecycleEvents
    let a = CloudSyncCoordinator.Account(identity: .init(recordName: "A"), scope: .account("a"))
    let b = CloudSyncCoordinator.Account(identity: .init(recordName: "B"), scope: .account("b"))
    let c = CloudSyncCoordinator.Account(identity: .init(recordName: "C"), scope: .account("c"))
    var identity: CloudSyncCoordinator.Identity
    var approved: Set<String> = ["A"]
    var holdLookup = false
    init(_ events: SyncLifecycleEvents) {
        self.events = events; identity = .confirmed(.init(identity: .init(recordName: "A"), scope: .account("a")))
    }
    func lookup() async -> CloudSyncCoordinator.Identity {
        if holdLookup {
            holdLookup = false
            let stale = identity
            await events.add("lookup-held")
            await events.wait("allow-lookup")
            return stale
        }
        return identity
    }
    func holdNextLookup() { holdLookup = true }
    func move(_ next: CloudSyncCoordinator.Identity) { identity = next }
    func isApproved(_ account: CloudSyncCoordinator.Account) -> Bool { approved.contains(account.identity.recordName) }
    func bind(_ status: DataIdentityStatus, approval: CloudSyncCoordinator.Account?) async -> DataScopeSelection {
        if let approval {
            let name = approval.identity.recordName
            approved.insert(name); await events.add("approve-" + name)
        }
        switch status {
        case .paused:
            await events.add("paused"); return .init(scope: a.scope, maySync: false)
        case .unknown:
            await events.add("unknown"); return .init(scope: a.scope, maySync: false)
        case .signedOut:
            await events.add("signout"); return .init(scope: .local, maySync: false)
        case let .confirmed(scope, enabled):
            await events.add("bind-" + scope.key + (enabled ? "-on" : "-off"))
            return .init(scope: scope, maySync: enabled)
        }
    }
    func open(_ account: CloudSyncCoordinator.Account) async -> SyncLifecycleTransport {
        let name = account.identity.recordName
        await events.add("open-" + name)
        return SyncLifecycleTransport(name, events)
    }
}

private final class SyncLifecycleHeldLookup: Operation, @unchecked Sendable {
    let entered = AsyncStream<Void>.makeStream()
    let sawCancel = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    override func main() {
        entered.continuation.yield()
        release.wait()
    }
    override func cancel() {
        super.cancel()
        sawCancel.continuation.yield()
    }
}
