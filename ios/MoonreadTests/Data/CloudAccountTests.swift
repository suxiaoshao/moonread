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
    let (root, service, _, _, _, _, suite) = try singleBookFixture()
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

    func testSwitchDoesNotWaitForTransportAndRejectsStaleAccountConsent() async throws {
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
        await events.add("allow-lookup")
        await passive.value
        await switchB.value
        let order = await events.entries
        try Self.require(order.contains("bind-b-off") && !order.contains("turn-ended-A"),
                         "B must get its own data authority without waiting for A's old network round")
        await events.add("allow-close-A")
        await events.add("allow-turn-A")
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
                    beforeClear: { throw CancellationError() })
                XCTFail("purge bypassed the editor guard")
            } catch is CancellationError { }
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

    func testZoneRecoveryRestartsOnlyOnce() async throws {
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
        XCTAssertEqual(events.filter { !$0.hasPrefix("close-") }, ["open-1","send-1","probe","apply","open-2","send-2"])
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
    func retire() {}
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
    private static let book = String(repeating: "a", count: 64)
    init() throws {
        account = .init(identity: .init(recordName: "fixture-A"),
            scope: try .confirmed(container: "fixture.invalid", environment: .development, recordName: "fixture-A"))
    }
    func open() throws -> (ReaderIndex, AppDataService) {
        let session = try DataSession(layout: .init(applicationSupport: root), confirmedLegacyOwner: account.scope)
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
    nonisolated func retire() {}
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
