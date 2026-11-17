import Foundation
import Synchronization

enum CloudConfiguration {
    struct VerifiedAccount: Equatable, Sendable { let recordName: String }
    static let containerID = "iCloud.dev.moonread.Moonread"
    static var availableInBuild: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return false }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "MoonreadCloudEnabled") as? String == "YES"
    }
}
extension Notification.Name {
    static let readingDataChanged = Notification.Name("Moonread.readingDataChanged")
    static let cloudDataReceived = Notification.Name("Moonread.cloudDataReceived")
    static let cloudStatusChanged = Notification.Name("Moonread.cloudStatusChanged")
    static let readingCloudStatusChanged = Notification.Name("Moonread.readingCloudStatusChanged")
}
enum CloudActivation: Sendable {
    case local
    case checking(revision: UUID)
    case awaitingAccountConfirmation(CloudConfiguration.VerifiedAccount, revision: UUID, message: String)
    case enabled(CloudConfiguration.VerifiedAccount, revision: UUID)
    case unavailable(String)
}
struct CloudSyncStatus: Sendable {
    var requested = false
    var activation = CloudActivation.local
    var syncing = false
    var lastSync: Date?
    var transportMessage: String?
    var canRetry = false

    var enabled: Bool { if case .enabled = activation { true } else { false } }
    var accountToConfirm: String? {
        if case .awaitingAccountConfirmation(let account, _, _) = activation { account.recordName } else { nil }
    }
    var message: String? {
        switch activation {
        case .awaitingAccountConfirmation(_, _, let message), .unavailable(let message): message
        default: transportMessage
        }
    }
}

/// Device-local intent is a tiny thread-safe UserDefaults write, independent of
/// account lookup, store activation, and either service actor's work queue.
final class CloudSyncIntent: @unchecked Sendable {
    private static let scopeKey = "Moonread.readingCloudApprovedScope.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    var requested: Bool { defaults.bool(forKey: "Moonread.userCloudEnabled") }
    func set(_ enabled: Bool) { defaults.set(enabled, forKey: "Moonread.userCloudEnabled") }
    var approvedScopeKey: String? { defaults.string(forKey: Self.scopeKey) }
    func approve(_ scope: DataScope) { defaults.set(scope.key, forKey: Self.scopeKey) }
}

/// GRDB executes the commit check on its writer queue. Cancellation has to
/// reach it even when that queue doesn't inherit the Swift Task context.
final class CloudScopeCancellation: Sendable {
    private let cancelled = Mutex(false)
    func cancel() { cancelled.withLock { $0 = true } }
    func check() throws {
        if cancelled.withLock({ $0 }) { throw CancellationError() }
        try Task.checkCancellation()
    }
}

protocol ReadingCloudTransport: Sendable {
    func syncNow() async throws
    /// Revoke the old writer before a different account can be selected.
    func retire()
    /// Cleanup can finish without holding up the new account.
    func close() async
}


/// The coordinator is the only App owner of a running reading-data transport.
/// The cutover binding is supplied separately from iCloud Drive discovery.
actor CloudSyncCoordinator {
    static let shared = CloudSyncCoordinator()

    struct Account: Equatable, Sendable {
        let identity: CloudConfiguration.VerifiedAccount
        let scope: DataScope
    }
    enum Identity: Sendable {
        case unknown, signedOut, confirmed(Account)
    }
    struct Runtime: Sendable {
        struct ZoneRecovery: Sendable {
            let probe: @Sendable (Account) async throws -> CloudAccountZoneRecovery.Presence
            let apply: @Sendable (Account, CloudAccountZoneRecovery.Presence?) async throws -> CloudAccountZoneRecovery.Outcome
        }
        let lookup: @Sendable () async -> Identity
        let isApproved: @Sendable (Account) async -> Bool
        /// A non-nil approval is explicit, and bound to the exact account
        /// which was re-verified for this transition.
        let select: @Sendable (DataIdentityStatus, Account?) async throws -> DataScopeSelection
        let open: @Sendable (Account) async throws -> any ReadingCloudTransport
        let zoneRecovery: ZoneRecovery?

        init(lookup: @escaping @Sendable () async -> Identity,
             isApproved: @escaping @Sendable (Account) async -> Bool,
             select: @escaping @Sendable (DataIdentityStatus, Account?) async throws -> DataScopeSelection,
             open: @escaping @Sendable (Account) async throws -> any ReadingCloudTransport,
             zoneRecovery: ZoneRecovery? = nil) {
            self.lookup = lookup; self.isApproved = isApproved; self.select = select
            self.open = open; self.zoneRecovery = zoneRecovery
        }

        static func relational(
            service: AppDataService,
            lookup: @escaping @Sendable () async -> Identity,
            beforeRebind: (@MainActor @Sendable () async throws -> Void)? = nil,
            afterRebind: (@MainActor @Sendable (Bool) -> Void)? = nil,
            probeZone: (@Sendable (Account, ReaderIndex) async throws -> CloudAccountZoneRecovery.Presence)? = nil,
            open: @escaping @Sendable (Account, ReaderIndex) async throws -> any ReadingCloudTransport
        ) -> Self {
            let recovery = probeZone.map { probe in
                ZoneRecovery(probe: { account in
                    let bound = try await service.relationalUserIndex()
                    guard bound.lease.scope == account.scope else { throw DataV2Error.leaseExpired }
                    return try await probe(account, bound)
                }, apply: { account, presence in
                    try await service.recoverReadingCloudZone(account, presence: presence, lookup: lookup,
                                                               beforeClear: beforeRebind, afterClear: afterRebind)
                })
            }
            return .init(lookup: lookup, isApproved: { await service.isReadingCloudApproved($0.scope) },
                  select: { status, approved in
                      try await service.selectReadingCloudScope(status, approval: approved, lookup: lookup,
                                                               beforeRebind: beforeRebind, afterRebind: afterRebind)
                  }, open: { account in
                      let bound = try await service.relationalUserIndex()
                      guard bound.lease.scope == account.scope else { throw DataV2Error.leaseExpired }
                      try bound.session.readUsers(bound.lease) {
                          if try CloudTransportRows.zoneStage($0, zone: ReadingHistoryTransport.zone) == .reset {
                              throw CloudZoneRecoverySignal.resetComplete
                          }
                      }
                      return try await open(account, bound)
                  }, zoneRecovery: recovery)
        }
    }

    private let service: AppDataService
    private let runtime: Runtime?
    private var status = CloudSyncStatus()
    private var foreground = true
    private var revision = UUID()
    private var transition: Task<Void, Never>?
    private var transport: (account: Account, handle: any ReadingCloudTransport)?
    private var turn: Task<Void, Never>?
    private var dirty = false
    private var restartPending = false
    private var identityNeedsVerification = false
    private var confirmationCandidate: Account?
    private struct RecoveryRequest: Sendable {
        let account: Account
        let signal: CloudZoneRecoverySignal
        let mayAttempt: Bool
    }

    // The App remains in trial mode until the account writer, old bridge
    // and production cutover gates provide a runtime.
    init(service: AppDataService = .shared, runtime: Runtime? = nil) {
        self.service = service; self.runtime = runtime
    }
    func currentStatus() -> CloudSyncStatus { status }

    nonisolated func persistIntent(_ enabled: Bool) { service.cloudSyncIntent.set(enabled) }

    func setEnabled(_ enabled: Bool) async {
        persistIntent(enabled)
        await enqueue(restart: !enabled)
    }

    func resume() async {
        if let transition, status.requested == service.cloudSyncIntent.requested {
            await transition.value
            return
        }
        await enqueue(restart: !service.cloudSyncIntent.requested)
    }

    func scene(active: Bool) async {
        guard active != foreground else { return }
        foreground = active
        await enqueue(restart: !active)
    }

    func identityChanged() async {
        identityNeedsVerification = true
        await enqueue(restart: true)
    }

    func confirmAccount(_ target: String, revision displayed: UUID) async {
        guard foreground, service.cloudSyncIntent.requested,
              case .awaitingAccountConfirmation(let pending, let revision, _) = status.activation,
              revision == displayed, pending.recordName == target, let candidate = confirmationCandidate else { return }
        await enqueue(restart: true, approval: candidate)
    }

    private func enqueue(restart: Bool, approval: Account? = nil, recovery: RecoveryRequest? = nil) async {
        let token = UUID()
        revision = token
        confirmationCandidate = nil
        let previous = transition
        previous?.cancel()
        if restart {
            restartPending = true
            // Cancel already-running I/O immediately, even when the previous
            // account lookup or other transition hasn't returned yet.
            stop()
            if runtime != nil { status.activation = .checking(revision: token); publish() }
        }
        let work = Task {
            await previous?.value
            guard current(token) else { return }
            await reconcile(token, approval: approval, recovery: recovery)
            if revision == token { transition = nil }
        }
        transition = work
        await work.value
    }

    private func current(_ token: UUID) -> Bool { revision == token && !Task.isCancelled }

    private func reconcile(_ token: UUID, approval: Account?, recovery: RecoveryRequest?) async {
        status.requested = service.cloudSyncIntent.requested
        guard let runtime else {
            restartPending = false
            status.activation = status.requested
                ? .unavailable(String(localized: "此版本暂不进行阅读数据 iCloud 同步，已保存的数据仍可在本机使用。"))
                : .local
            await service.refreshOfflineSystemReadingPolicy()
            if current(token) { publish() }
            return
        }
        status.canRetry = true
        status.activation = .checking(revision: token)
        publish()
        if restartPending || !foreground || !status.requested {
            stop()
            guard current(token) else { return }
            restartPending = false
        }
        guard current(token) else { return }
        do {
            let identity = foreground ? await runtime.lookup() : .unknown
            guard current(token) else { return }
            switch identity {
            case .unknown, .signedOut:
                stop()
                guard current(token) else { return }
                let input: DataIdentityStatus
                if !foreground && !identityNeedsVerification { input = .paused }
                else if case .signedOut = identity { input = .signedOut }
                else { input = .unknown }
                _ = try await runtime.select(input, nil)
                guard current(token) else { return }
                if case .signedOut = input { identityNeedsVerification = false }
                status.activation = status.requested
                    ? .unavailable(String(localized: "暂时无法连接 iCloud，阅读数据同步未完成。")) : .local
            case .confirmed(let account):
                let explicitlyApproved = approval == account
                let approvedBefore = await runtime.isApproved(account)
                guard current(token) else { return }
                let requested = service.cloudSyncIntent.requested
                let enabled = requested && (explicitlyApproved || approvedBefore)
                if !enabled || transport?.account != account { stop() }
                guard current(token) else { return }
                let selected = try await runtime.select(.confirmed(account.scope, syncRequested: enabled),
                                                        requested && explicitlyApproved ? account : nil)
                guard current(token) else { return }
                identityNeedsVerification = false
                guard requested else { status.activation = .local; publish(); return }
                guard enabled, selected.maySync, selected.scope == account.scope else {
                    confirmationCandidate = account
                    status.activation = .awaitingAccountConfirmation(account.identity, revision: token,
                        message: String(localized: "需要确认同步账户"))
                    publish()
                    return
                }
                let repair = recovery.flatMap { $0.account == account ? $0 : nil }
                if let repair {
                    guard repair.mayAttempt, repair.signal != .resetComplete,
                          let zoneRecovery = runtime.zoneRecovery else { pauseForZone(); return }
                    let presence = repair.signal == .verificationRequired ? try await zoneRecovery.probe(account) : nil
                    guard current(token) else { return }
                    let outcome = try await zoneRecovery.apply(account, presence)
                    guard current(token) else { return }
                    guard outcome == .resume || outcome == .rebuild else { pauseForZone(); return }
                }
                if transport == nil {
                    let handle = try await runtime.open(account)
                    guard current(token) else {
                        handle.retire()
                        Task { await handle.close() }
                        return
                    }
                    transport = (account, handle)
                }
                status.activation = .enabled(account.identity, revision: token)
                status.transportMessage = nil
                startTurn(allowRecovery: repair == nil)
            }
            publish()
        } catch {
            guard current(token) else { return }
            stop()
            guard current(token) else { return }
            if (error as? CloudZoneRecoverySignal) == .resetComplete {
                pauseForZone()
                return
            } else {
                status.activation = .unavailable(String(localized: "暂时无法连接 iCloud，阅读数据同步未完成。"))
            }
            publish()
        }
    }

    func localDataChanged() {
        startTurn(allowRecovery: true)
    }

    private func startTurn(allowRecovery: Bool) {
        guard let transport, foreground, !restartPending, status.enabled, service.cloudSyncIntent.requested else { return }
        dirty = true
        guard turn == nil else { return }
        status.syncing = true; publish()
        turn = Task { await drive(transport.handle, account: transport.account, allowRecovery: allowRecovery) }
    }

    private func drive(_ handle: any ReadingCloudTransport, account: Account, allowRecovery: Bool) async {
        while dirty, !Task.isCancelled {
            dirty = false
            do {
                try await handle.syncNow()
                guard !Task.isCancelled else { return }
                status.lastSync = .now
                status.transportMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                if case .accountChanged? = error as? ReadingSyncEngineAdapter.Failure {
                    turn = nil
                    await identityChanged()
                    return
                }
                if let signal = error as? CloudZoneRecoverySignal {
                    turn = nil
                    // One immediate retry only. Any newly recorded reason
                    // remains on disk for a later foreground/retry event.
                    await enqueue(restart: true, recovery: .init(account: account, signal: signal, mayAttempt: allowRecovery))
                    return
                }
                status.transportMessage = String(localized: "暂时无法连接 iCloud，阅读数据同步未完成。")
                break  // retry on a real foreground/write/identity event
            }
        }
        if !Task.isCancelled {
            turn = nil; status.syncing = false; publish()
        }
    }

    private func pauseForZone() {
        status.activation = .unavailable(String(localized: "阅读数据同步已暂停"))
        publish()
    }

    private func stop() {
        let old = transport
        old?.handle.retire()
        turn?.cancel()
        transport = nil; turn = nil; dirty = false
        status.syncing = false; status.lastSync = nil; status.transportMessage = nil
        if let old { Task { await old.handle.close() } }
    }

    private func publish() { NotificationCenter.default.post(name: .readingCloudStatusChanged, object: nil) }
}
extension AppDataService {
    func cloudSyncRequested() -> Bool { cloudSyncIntent.requested }
    func setCloudSyncRequested(_ requested: Bool) { cloudSyncIntent.set(requested) }
    func userCloudOwner() -> String? { sourceDefaults.string(forKey: "Moonread.userOwner") }
    func isReadingCloudApproved(_ scope: DataScope) -> Bool {
        guard scope != .local else { return false }
        if let approved = cloudSyncIntent.approvedScopeKey { return scope.key == approved }
        // The previous owner proves consent for exactly its released scope.
        // Keep that provenance key intact for migration and the old bridge.
        return (try? publishedUserSource().scope) == scope
    }
    func dataChanged() {
        NotificationCenter.default.post(name: .readingDataChanged, object: nil)
    }
}
