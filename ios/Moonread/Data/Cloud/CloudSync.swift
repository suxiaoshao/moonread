import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import CloudKit
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
    static var readingEnvironment: DataScope.Environment? {
        switch Bundle.main.object(forInfoDictionaryKey: "MoonreadReadingCloudEnvironment") as? String {
        case "Development": .development
        case "Production": .production
        default: nil
        }
    }

    static func readingAccount(environment: DataScope.Environment) async -> CloudSyncCoordinator.Identity {
        let container = CKContainer(identifier: containerID)
        do {
            switch try await container.accountStatus() {
            case .noAccount: return .signedOut
            case .available:
                let recordName = try await container.userRecordID().recordName
                try Task.checkCancellation()
                let scope = try DataScope.confirmed(container: containerID, environment: environment, recordName: recordName)
                return .confirmed(.init(identity: .init(recordName: recordName), scope: scope))
            case .restricted: return .unavailable(.restricted)
            default: return .unknown
            }
        } catch { return .unavailable(.connection(error)) }
    }
}
extension Notification.Name {
    static let readingDataChanged = Notification.Name("Moonread.readingDataChanged")
    static let cloudStatusChanged = Notification.Name("Moonread.cloudStatusChanged")
    static let readingCloudStatusChanged = Notification.Name("Moonread.readingCloudStatusChanged")
}
enum CloudActivation: Sendable {
    case local
    case checking(revision: UUID)
    case awaitingAccountConfirmation(CloudConfiguration.VerifiedAccount, revision: UUID)
    case enabled(CloudConfiguration.VerifiedAccount, revision: UUID)
    case signedOut
    case unavailable(CloudSyncIssue)
}

enum CloudSyncIssue: Equatable, Sendable {
    case offline, quota, unavailable, restricted, unsupportedBuild, paused, incomplete

    static func connection(_ error: any Error) -> Self {
        if (error as? CKError)?.code == .networkUnavailable
            || (error as? URLError)?.code == .notConnectedToInternet { return .offline }
        if (error as? CKError)?.code == .quotaExceeded { return .quota }
        return .unavailable
    }
}

enum CloudSyncPhase: Equatable, Sendable {
    case firstUpload(CloudInitialUploadProgress?)
    case firstDownload(received: Int?)
    case finishing
    case waitingForDevice
}

struct CloudSyncStatus: Sendable {
    var requested = false
    var activation = CloudActivation.local
    var syncing = false
    var lastSync: Date?
    var phase: CloudSyncPhase?
    var transportIssue: CloudSyncIssue?
    var canRetry = false

    var enabled: Bool { if case .enabled = activation { true } else { false } }
}

/// Device-local intent is a tiny thread-safe UserDefaults write, independent of
/// account lookup, store activation, and either service actor's work queue.
final class CloudSyncIntent: @unchecked Sendable {
    private let scopeKey: String
    private let defaults: UserDefaults
    static let releasedDevelopmentApprovalKey = "Moonread.readingCloudApprovedScope.v1.development"
    init(defaults: UserDefaults, environment: DataScope.Environment) {
        self.defaults = defaults
        scopeKey = environment == .development ? "Moonread.readingCloudApprovedScope.v3.development" : "Moonread.readingCloudApprovedScope.v1"
    }
    var requested: Bool { defaults.bool(forKey: "Moonread.userCloudEnabled") }
    func set(_ enabled: Bool) { defaults.set(enabled, forKey: "Moonread.userCloudEnabled") }
    var approvedScopeKey: String? { defaults.string(forKey: scopeKey) }
    var releasedDevelopmentApproval: String? { defaults.string(forKey: Self.releasedDevelopmentApprovalKey) }
    func approve(_ scope: DataScope) { defaults.set(scope.key, forKey: scopeKey) }
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
    func syncNow(report: @escaping @Sendable (CloudSyncPhase?) async -> Void) async throws
    /// Revoke the old writer before a different account can be selected.
    func retire()
    /// Cleanup can finish without holding up the new account.
    func close() async
}


/// The coordinator is the only App owner of a running reading-data transport.
/// The cutover binding is supplied separately from iCloud Drive discovery.
actor CloudSyncCoordinator {
    static let shared: CloudSyncCoordinator = {
        let service = AppDataService.shared
        guard CloudConfiguration.availableInBuild, let environment = CloudConfiguration.readingEnvironment else {
            return CloudSyncCoordinator(service: service)
        }
        return CloudSyncCoordinator(service: service, runtime: .relational(
            service: service,
            lookup: { await CloudConfiguration.readingAccount(environment: environment) },
            probeZone: { account, index in
                try await ReadingSyncEngineAdapter.probeAppZone(lease: index.lease, account: account, environment: environment)
            },
            open: { account, index in
                try await ReadingSyncEngineAdapter.openAppContainer(session: index.session, lease: index.lease,
                                                                    account: account, environment: environment)
            }
        ))
    }()

    struct Account: Equatable, Sendable {
        let identity: CloudConfiguration.VerifiedAccount
        let scope: DataScope
    }
    enum Identity: Sendable {
        case unknown, unavailable(CloudSyncIssue), signedOut, confirmed(Account)
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
            return .init(lookup: lookup, isApproved: { await service.isReadingCloudApproved($0) },
                  select: { status, approved in
                      try await service.selectReadingCloudScope(status, approval: approved, lookup: lookup,
                                                               beforeRebind: beforeRebind, afterRebind: afterRebind)
                  }, open: { account in
                      let bound = try await service.relationalUserIndex()
                      guard bound.lease.scope == account.scope else { throw DataV2Error.leaseExpired }
                      try bound.requireOpenCloudZone()
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
    private var transport: (account: Account, handle: any ReadingCloudTransport, binding: UUID)?
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

    // No runtime for no-cloud builds or fixtures that don't inject one.
    init(service: AppDataService = .shared, runtime: Runtime? = nil) {
        self.service = service; self.runtime = runtime
    }
    func currentStatus() -> CloudSyncStatus { status }

    func organizeReadingDatabase(session: DataSession, lease: DataSessionLease) throws -> StorageDatabaseResult {
        guard transition == nil, turn == nil, !status.syncing else { throw StorageMaintenanceError.busy }
        // Keep coordinator admission while the session drains its readers.
        // The engine is manually driven, so no new sync turn can enter here.
        return try session.organizeUserDatabase(lease)
    }

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
              case .awaitingAccountConfirmation(let pending, let revision) = status.activation,
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
            status.activation = status.requested ? .unavailable(.unsupportedBuild) : .local
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
            case .unknown, .unavailable, .signedOut:
                stop()
                guard current(token) else { return }
                let input: DataIdentityStatus
                if !foreground && !identityNeedsVerification { input = .paused }
                else if case .signedOut = identity { input = .signedOut }
                else { input = .unknown }
                _ = try await runtime.select(input, nil)
                guard current(token) else { return }
                if case .signedOut = input { identityNeedsVerification = false }
                status.activation = if !status.requested { .local }
                    else if case .signedOut = identity { .signedOut }
                    else if case .unavailable(let issue) = identity { .unavailable(issue) }
                    else { .unavailable(.unavailable) }
            case .confirmed(let account):
                let explicitlyApproved = approval == account
                let approvedBefore = await runtime.isApproved(account)
                guard current(token) else { return }
                let requested = service.cloudSyncIntent.requested
                let enabled = requested && (explicitlyApproved || approvedBefore)
                if !enabled || transport?.account != account { stop() }
                guard current(token) else { return }
                let selected = try await runtime.select(.confirmed(account.scope, syncRequested: enabled,
                                                                  verifiedRecordName: account.identity.recordName),
                                                        requested && explicitlyApproved ? account : nil)
                guard current(token) else { return }
                identityNeedsVerification = false
                guard requested else { status.activation = .local; publish(); return }
                guard enabled, selected.maySync, selected.scope == account.scope else {
                    confirmationCandidate = account
                    status.activation = .awaitingAccountConfirmation(account.identity, revision: token)
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
                    transport = (account, handle, token)
                }
                status.activation = .enabled(account.identity, revision: token)
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
                status.activation = .unavailable(.connection(error))
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
        status.syncing = true; status.phase = nil; status.transportIssue = nil; publish()
        turn = Task { await drive(transport.handle, account: transport.account, binding: transport.binding,
                                  allowRecovery: allowRecovery) }
    }

    private func recordPhase(_ phase: CloudSyncPhase?, binding: UUID) {
        guard transport?.binding == binding, status.syncing, status.phase != phase else { return }
        status.phase = phase
        publish()
    }

    private func drive(_ handle: any ReadingCloudTransport, account: Account, binding: UUID, allowRecovery: Bool) async {
        while dirty, !Task.isCancelled {
            dirty = false
            do {
                try await handle.syncNow { [weak self] phase in await self?.recordPhase(phase, binding: binding) }
                guard !Task.isCancelled else { return }
                status.lastSync = .now
                status.phase = nil
                status.transportIssue = nil
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
                if case .awaitingExistingUpload? = error as? ReadingCloudInitialization.Failure {
                    status.phase = .waitingForDevice
                } else {
                    status.phase = nil
                    switch error as? ReadingCloudInitialization.Failure {
                    case .awaitingFirstUpload?, .incompleteFirstUpload?, .awaitingExistingBaseline?:
                        status.transportIssue = .incomplete
                    default:
                        status.transportIssue = .connection(error)
                    }
                }
                break  // retry on a real foreground/write/identity event
            }
        }
        if !Task.isCancelled {
            turn = nil; status.syncing = false; publish()
        }
    }

    private func pauseForZone() {
        status.activation = .unavailable(.paused)
        publish()
    }

    private func stop() {
        let old = transport
        old?.handle.retire()
        turn?.cancel()
        transport = nil; turn = nil; dirty = false
        status.syncing = false; status.lastSync = nil; status.phase = nil; status.transportIssue = nil
        if let old { Task { await old.handle.close() } }
    }

    private func publish() { NotificationCenter.default.post(name: .readingCloudStatusChanged, object: nil) }
}
extension AppDataService {
    func cloudSyncRequested() -> Bool { cloudSyncIntent.requested }
    func setCloudSyncRequested(_ requested: Bool) { cloudSyncIntent.set(requested) }
    func approveReadingCloudDuringLegacyCleanup() throws {
        // The mislabelled store may still carry its released Development key.
        // Production consent is resolved only after verifying the account.
        if case .mislabelledProduction = releasedReadingLayout { return }
        let source = try publishedUserSource()
        if source != .local, cloudSyncIntent.approvedScopeKey == nil {
            cloudSyncIntent.approve(source)
        }
    }

    func hasPreviouslyApprovedReadingAccount() -> Bool {
        if cloudSyncIntent.approvedScopeKey != nil { return true }
        switch releasedReadingLayout {
        case .mislabelledProduction(approvedScope: .some), .releasedDevelopment(approvedScope: .some): return true
        default: break
        }
        return if case .account = try? publishedUserSource() { true } else { false }
    }
    func isReadingCloudApproved(_ account: CloudSyncCoordinator.Account) -> Bool {
        if isReadingCloudApproved(account.scope) { return true }
        guard let change = try? releasedAccountChange(to: account.scope, recordName: account.identity.recordName) else { return false }
        return inheritsReleasedApproval(change)
    }

    func releasedAccountChange(to scope: DataScope, recordName: String) throws -> ReadingDataLayoutUpgrade.AccountChange? {
        guard case .mislabelledProduction = releasedReadingLayout else { return nil }
        let container = CloudConfiguration.containerID
        guard scope == (try DataScope.confirmed(container: container, environment: .production, recordName: recordName)) else {
            throw ReaderError.CloudAccountChanged
        }
        let old = try DataScope.confirmed(container: container, environment: .development, recordName: recordName)
        return .init(old: old, new: scope)
    }

    private func inheritsReleasedApproval(_ change: ReadingDataLayoutUpgrade.AccountChange) -> Bool {
        guard cloudSyncIntent.approvedScopeKey == nil,
              case .mislabelledProduction(let approval) = releasedReadingLayout else { return false }
        if let approval { return approval == change.old.key }
        return (try? publishedUserSource()) == change.old
    }

    func releasedApproval(for scope: DataScope, change: ReadingDataLayoutUpgrade.AccountChange?) -> DataScope? {
        guard cloudSyncIntent.approvedScopeKey == nil else { return nil }
        if let change, inheritsReleasedApproval(change) { return scope }
        if case .releasedDevelopment(let approved) = releasedReadingLayout, scope.key == approved { return scope }
        return nil
    }

    func isReadingCloudApproved(_ scope: DataScope) -> Bool {
        guard scope != .local else { return false }
        if let approved = cloudSyncIntent.approvedScopeKey { return scope.key == approved }
        switch releasedReadingLayout {
        case .mislabelledProduction(approvedScope: .some): return false
        case .releasedDevelopment(let approved?): return scope.key == approved
        default: break
        }
        // The previous owner proves consent for the released source as
        // attributed to this installation's environment.
        return (try? publishedUserSource()) == scope
    }
    func dataChanged() {
        NotificationCenter.default.post(name: .readingDataChanged, object: nil)
    }
}
