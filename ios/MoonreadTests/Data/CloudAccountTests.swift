import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
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
        try Self.require(await events.entries.contains("unknown"), "background suspends current network authority")
        await backend.move(.signedOut)
        await owner.scene(active: true)
        let status = await owner.currentStatus()
        try Self.require(status.requested && !status.enabled, "sign-out must preserve explicit sync intent")
        try Self.require(await events.entries.contains("signout"), "explicit signout is distinct from unknown")
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
