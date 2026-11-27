import MoonreadReader
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import CloudKit
import Foundation
import Synchronization

/// A direct lookup is outside CKSyncEngine.cancelOperations(). Cancel its
/// operation explicitly and only let its caller proceed after completion.
enum ReadingCloudLookup {
    static func run<Value: Sendable>(
        _ operation: Operation,
        bind: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void,
        submit: () -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> Value {
        let outcome = Mutex<Result<Value, any Error>?>(nil)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value: Value = try await withCheckedThrowingContinuation { continuation in
                bind { result in outcome.withLock { $0 = result } }
                operation.completionBlock = { [weak operation] in
                    if operation?.isCancelled == true {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        let result = outcome.withLock { $0 }
                        continuation.resume(with: result ?? .failure(CKError(.internalError)))
                    }
                }
                submit()
            }
            try Task.checkCancellation()
            return value
        } onCancel: {
            operation.cancel()
        }
    }
}

/// One engine for the approved account's prepared library. The app and the
/// separately signed test host have fixed, distinct container entry points.
@MainActor
final class ReadingSyncEngineAdapter: CKSyncEngineDelegate, ReadingCloudTransport {
    #if DEBUG || os(macOS)
    static let testContainer = "iCloud.dev.moonread.SyncProbe"
    #endif
    static let ownZone = CKRecordZone.ID(zoneName: ReadingHistoryTransport.zone, ownerName: CKCurrentUserDefaultName)
    nonisolated static let attachmentLimit = CloudAttachmentLimits.bytes

    enum Failure: Error {
        case inactive, accountChanged, busy, wrongIdentity, invalidSystemFields, zoneNotReady
    }

    private struct Offered {
        let attempt: CloudTransportRows.Attempt
        let record: CKRecord?
        let asset: URL?
    }

    private let journal: CloudCallbackJournal
    private let database: CKDatabase
    private let account: CKRecord.ID
    private let installation: UUID
    private let subscriptionID: String
    private let receivedChanges: @Sendable () -> Void
    private let staging: URL
    private let zone: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var active = true
    private var turn: Task<Void, any Error>?
    private var reportPhase: (@Sendable (CloudSyncPhase?) async -> Void)?
    private var reportingFirstUpload = false
    private var shutdown: Task<Void, Never>?
    private var initialSignInAllowed: Bool
    private var fatal: (any Error)?
    private var joiningControl: ReadingCloudInitialization.Control?
    private var joiningCheckpoint: Data?
    private var joiningZoneFinished = false
    private var interruptedBaseline = false
    private var ownZoneMissingDuringFetch = false
    private var ownZoneFetchSucceeded = false
    private var offered: [CKRecord.ID: Offered] = [:]

    private init(journal: CloudCallbackJournal, database: CKDatabase, account: CKRecord.ID, staging: URL,
                 zone: CKRecordZone.ID, installation: UUID, subscriptionID: String, initialSignInAllowed: Bool,
                 receivedChanges: @escaping @Sendable () -> Void) {
        self.journal = journal; self.database = database; self.account = account; self.staging = staging
        self.zone = zone; self.installation = installation; self.subscriptionID = subscriptionID
        self.initialSignInAllowed = initialSignInAllowed
        self.receivedChanges = receivedChanges
    }

    /// Bind to a library prepared by the test host. The scope key includes
    /// this literal container and Development; a production lease cannot pass.
    #if DEBUG || os(macOS)
    static func openTestContainer(session: DataSession, lease: DataSessionLease) async throws -> ReadingSyncEngineAdapter {
        let (container, account) = try await verifiedTestContainer(session: session, lease: lease)
        return try await open(session: session, lease: lease, container: container, account: account,
                              subscriptionID: "Moonread-SyncProbe-v2")
    }
    #endif

    #if os(iOS)
    static func openAppContainer(session: DataSession, lease: DataSessionLease, account: CloudSyncCoordinator.Account,
                                 environment: DataScope.Environment) async throws -> ReadingSyncEngineAdapter {
        let (container, current) = try await verifiedAppContainer(lease: lease, account: account, environment: environment)
        return try await open(session: session, lease: lease, container: container, account: current,
                              subscriptionID: "Moonread-Reading-v2", receivedChanges: {
            NotificationCenter.default.post(name: .cloudDataReceived, object: nil)
        })
    }

    static func probeAppZone(lease: DataSessionLease, account: CloudSyncCoordinator.Account,
                             environment: DataScope.Environment) async throws -> CloudAccountZoneRecovery.Presence {
        let (container, _) = try await verifiedAppContainer(lease: lease, account: account, environment: environment)
        return try await probeZone(in: container.privateCloudDatabase)
    }

    private static func verifiedAppContainer(lease: DataSessionLease, account: CloudSyncCoordinator.Account,
                                             environment: DataScope.Environment) async throws -> (CKContainer, CKRecord.ID) {
        try Task.checkCancellation()
        guard CloudConfiguration.availableInBuild, CloudConfiguration.readingEnvironment == environment,
              lease.scope == account.scope else { throw Failure.wrongIdentity }
        let container = CKContainer(identifier: CloudConfiguration.containerID)
        let current = try await container.userRecordID()
        try Task.checkCancellation()
        guard current.recordName == account.identity.recordName,
              try DataScope.confirmed(container: CloudConfiguration.containerID, environment: environment,
                                      recordName: current.recordName) == lease.scope else { throw Failure.accountChanged }
        return (container, current)
    }
    #endif

    private static func open(session: DataSession, lease: DataSessionLease, container: CKContainer,
                             account: CKRecord.ID, subscriptionID: String,
                             receivedChanges: @escaping @Sendable () -> Void = {}) async throws -> ReadingSyncEngineAdapter {
        let database = container.privateCloudDatabase
        let root = try session.layout.staging(lease.scope).appending(path: "ck-sandbox-" + UUID().uuidString, directoryHint: .isDirectory)
        let journal = try CloudCallbackJournal(session: session, lease: lease)
        do {
            let bytes = try await journal.engineCheckpoint()
            try Task.checkCancellation()
            let state = try bytes.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            guard let installation = UUID(uuidString: try session.readingInstallationID()) else { throw Failure.wrongIdentity }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let adapter = ReadingSyncEngineAdapter(journal: journal, database: database, account: account, staging: root,
                                                   zone: ownZone, installation: installation, subscriptionID: subscriptionID,
                                                   initialSignInAllowed: bytes == nil, receivedChanges: receivedChanges)
            adapter.engine = adapter.makeEngine(state)
            return adapter
        } catch {
            journal.retire()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func makeEngine(_ state: CKSyncEngine.State.Serialization?) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: self)
        configuration.automaticallySync = false
        configuration.subscriptionID = subscriptionID
        return CKSyncEngine(configuration)
    }

    #if DEBUG || os(macOS)
    static func probeTestZone(session: DataSession, lease: DataSessionLease) async throws -> CloudAccountZoneRecovery.Presence {
        let (container, _) = try await verifiedTestContainer(session: session, lease: lease)
        return try await probeZone(in: container.privateCloudDatabase)
    }
    #endif

    private static func probeZone(in database: CKDatabase) async throws -> CloudAccountZoneRecovery.Presence {
        do {
            let found = try await fetchZone(database: database, id: ownZone)
            guard found.zoneID == ownZone else { throw Failure.wrongIdentity }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return .absent
        }
        // A peer may already have made the replacement by the time this
        // device checks presence. The writer compares its initialization ID
        // with the old decision. Never infer zone absence from this point read.
        let id = CKRecord.ID(recordName: ReadingCloudInitialization.recordName, zoneID: ownZone)
        do {
            let record = try await fetchRecord(database: database, id: id)
            return .presentWithControl(try ReadingCloudInitialization.Control.decode(record, in: ownZone))
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return .present
        } catch is ReadingCloudInitialization.Failure {
            // If no deletion was recorded, zone presence is sufficient to
            // resume the old path; a malformed control never proves replacement.
            return .present
        }
    }

    #if DEBUG || os(macOS)
    private static func verifiedTestContainer(session: DataSession, lease: DataSessionLease) async throws -> (CKContainer, CKRecord.ID) {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let synthetic = session.layout.root.resolvingSymlinksInPath().path
        guard synthetic.hasPrefix(temporary + "/Moonread-CKProbe-") else { throw Failure.wrongIdentity }
        try Task.checkCancellation()
        let container = CKContainer(identifier: testContainer)
        let account = try await container.userRecordID()
        try Task.checkCancellation()
        let expected = try DataScope.confirmed(container: testContainer, environment: .development, recordName: account.recordName)
        guard lease.scope == expected else { throw Failure.wrongIdentity }
        return (container, account)
    }
    #endif

    nonisolated func retire() { journal.retire() }

    func close() async {
        if let shutdown { await shutdown.value; return }
        active = false
        retire()
        let work = turn
        work?.cancel()
        let old = engine
        engine = nil
        let shutdown = Task {
            await old?.cancelOperations()
            _ = await work?.result
            clearOffered()
            try? FileManager.default.removeItem(at: staging)
        }
        self.shutdown = shutdown
        await shutdown.value
    }

    func syncNow(report: @escaping @Sendable (CloudSyncPhase?) async -> Void = { _ in }) async throws {
        guard let engine else { throw Failure.inactive }
        try checkActive(engine)
        guard turn == nil else { throw Failure.busy }
        reportPhase = report
        let work = Task { try await self.runTurn(engine) }
        turn = work
        defer {
            reportPhase = nil
            turn = nil
            // A failed baseline must never continue using the advanced SDK
            // cursor from a staging inbox that was just discarded.
            if interruptedBaseline, active, self.engine === engine, fatal == nil {
                initialSignInAllowed = true
                self.engine = makeEngine(nil)
            }
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func runTurn(_ engine: CKSyncEngine) async throws {
        do {
            try await ready(engine)
            if try await journal.needsInitializationDecision() {
                let decision = try await decideInitialization(engine)
                switch decision.role {
                case .selectedFirst:
                    try await uploadFirstInitialization(decision.control, engine: engine)
                    return
                case .waitingExisting: throw ReadingCloudInitialization.Failure.awaitingExistingUpload
                case .joiningExisting:
                    try await fetchJoiningBaseline(decision.control, engine: engine)
                    try checkActive(engine)
                    try await runBusinessTurn(engine)
                    try checkActive(engine)
                    return
                case .claiming: throw ReadingCloudInitialization.Failure.inconsistentDecision
                }
            }
            try await runBusinessTurn(engine)
            try checkActive(engine)
        } catch {
            try checkActive(engine)  // Prefer a recorded, more specific callback failure.
            if (error as? CKError)?.code == .zoneNotFound { throw CloudZoneRecoverySignal.verificationRequired }
            throw error
        }
    }

    private func runBusinessTurn(_ engine: CKSyncEngine) async throws {
        try await fetchOwnZone(engine)
        try await verifyRecords(engine)
        try await sendDurable(engine)
        // One follow-up pull lets a restore retry after the delete echoes have been consumed.
        if try await journal.historyDeletionNeedsFetch() { try await fetchOwnZone(engine) }
    }

    private func uploadFirstInitialization(_ control: ReadingCloudInitialization.Control, engine: CKSyncEngine) async throws {
        try checkActive(engine)
        reportingFirstUpload = true
        defer { reportingFirstUpload = false }
        await reportPhase?(.firstUpload(nil))
        try checkActive(engine)
        try await journal.beginFirstUpload(control)
        var completion = try await journal.sealFirstUpload(control)
        if completion == .pending {
            await reportUploadProgress()
            try checkActive(engine)
            try await runBusinessTurn(engine)
            try checkActive(engine)
            completion = try await journal.sealFirstUpload(control)
        }
        switch completion {
        case .pending: throw ReadingCloudInitialization.Failure.awaitingFirstUpload
        case .uncovered: throw ReadingCloudInitialization.Failure.incompleteFirstUpload
        case .sealed: break
        }
        reportingFirstUpload = false
        await reportPhase?(.finishing)
        try checkActive(engine)
        let ready = if control.phase == .ready { control }
            else { try await publishFirstReady(control, engine: engine) }
        try checkActive(engine)
        try await journal.finishFirstUpload(ready)
    }

    private func reportUploadProgress() async {
        guard reportingFirstUpload, let reportPhase else { return }
        let progress = try? await journal.firstUploadProgress()
        await reportPhase(.firstUpload(progress))
    }

    private func ready(_ engine: CKSyncEngine) async throws {
        let stage = try await journal.zoneStage()
        var sawAbsence = false
        try checkActive(engine)
        if let signal = stage.recoverySignal { throw signal }
        if stage == .unverified {
            do {
                let found = try await Self.fetchZone(database: database, id: zone)
                try checkActive(engine)
                guard found.zoneID == zone else { throw Failure.wrongIdentity }
                try await journal.initializeZone(exists: true)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                try checkActive(engine)
                try await journal.initializeZone(exists: false)
                sawAbsence = true
            }
        }
        if try await journal.zoneStage() == .needsCreation {
            let create = CKSyncEngine.PendingDatabaseChange.saveZone(CKRecordZone(zoneID: zone))
            // A peer may have created the zone since our durable absence
            // proof. Presence releases only zone creation, not first upload.
            if !sawAbsence, try await confirmExistingCreation(engine) {
                engine.state.remove(pendingDatabaseChanges: [create])
            } else {
                try checkActive(engine)
                engine.state.add(pendingDatabaseChanges: [create])
                try await engine.sendChanges(.init(scope: .zoneIDs([zone])))
            }
        }
        try checkActive(engine)
        guard try await journal.zoneStage() == .ready else { throw Failure.zoneNotReady }
    }

    private func confirmExistingCreation(_ engine: CKSyncEngine) async throws -> Bool {
        try checkActive(engine)
        do {
            let found = try await Self.fetchZone(database: database, id: zone)
            try checkActive(engine)
            guard found.zoneID == zone else { throw Failure.wrongIdentity }
            _ = try await journal.confirmZoneCreation()
            try checkActive(engine)
            return true
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return false
        }
    }

    private func fetchOwnZone(_ engine: CKSyncEngine) async throws {
        try checkActive(engine)
        ownZoneMissingDuringFetch = false
        ownZoneFetchSucceeded = false
        defer { ownZoneMissingDuringFetch = false }
        try await engine.fetchChanges(.init(scope: .zoneIDs([zone])))
        try checkActive(engine)
        if ownZoneMissingDuringFetch { throw CloudZoneRecoverySignal.verificationRequired }
        if ownZoneFetchSucceeded, !engine.state.zoneIDsWithUnfetchedServerChanges.contains(zone) {
            // The SDK has awaited the inbox and checkpoint callbacks for this fetch.
            try await journal.finishHistoryDeletionFetch()
            try checkActive(engine)
        }
    }

    private func fetchJoiningBaseline(_ ready: ReadingCloudInitialization.Control, engine: CKSyncEngine) async throws {
        try checkActive(engine)
        try await journal.beginJoiningBaseline(ready)
        interruptedBaseline = true
        joiningControl = ready
        defer {
            joiningControl = nil; joiningCheckpoint = nil
            joiningZoneFinished = false; ownZoneMissingDuringFetch = false
        }
        do {
            await reportPhase?(.firstDownload(received: 0))
            try checkActive(engine)
            repeat {
                let previous = joiningCheckpoint
                joiningZoneFinished = false; ownZoneMissingDuringFetch = false
                try await engine.fetchChanges(.init(scope: .zoneIDs([zone])))
                try checkActive(engine)
                if ownZoneMissingDuringFetch { throw CloudZoneRecoverySignal.verificationRequired }
                guard joiningZoneFinished, joiningCheckpoint != nil,
                      !engine.state.zoneIDsWithUnfetchedServerChanges.contains(zone) || joiningCheckpoint != previous else {
                    throw ReadingCloudInitialization.Failure.awaitingExistingBaseline
                }
            } while engine.state.zoneIDsWithUnfetchedServerChanges.contains(zone)
            let id = CKRecord.ID(recordName: ReadingCloudInitialization.recordName, zoneID: zone)
            let record = try await fetchRecord(id)
            try checkActive(engine)
            guard try ReadingCloudInitialization.Control.decode(record, in: zone) == ready,
                  let joiningCheckpoint else { throw ReadingCloudInitialization.Failure.inconsistentDecision }
            try await journal.finishJoiningBaseline(ready, checkpoint: joiningCheckpoint)
            try checkActive(engine)
            interruptedBaseline = false
            await reportPhase?(nil)
            receivedChanges()
        } catch {
            if active, self.engine === engine, fatal == nil { try await journal.discardJoiningBaseline() }
            throw error
        }
    }

    private func sendDurable(_ engine: CKSyncEngine) async throws {
        var requested: Set<CKSyncEngine.PendingRecordZoneChange> = []
        while true {
            try checkActive(engine)
            let durable = try await journal.pendingInOwnZone()
            try checkActive(engine)
            let desired = Set(durable.map { item -> CKSyncEngine.PendingRecordZoneChange in
                let id = CKRecord.ID(recordName: item.key.name, zoneID: zone)
                return item.isSave ? .saveRecord(id) : .deleteRecord(id)
            })
            let scheduled = Set(engine.state.pendingRecordZoneChanges.filter { id(of: $0)?.zoneID == zone })
            engine.state.remove(pendingRecordZoneChanges: Array(scheduled.subtracting(desired)))
            engine.state.add(pendingRecordZoneChanges: Array(desired.subtracting(scheduled)))
            // A causal SAVE ACK can make DELETEs ready mid-turn. Reschedule
            // those explicitly, but do not spin on unchanged rejected work.
            guard !desired.subtracting(requested).isEmpty else { return }
            requested.formUnion(desired)
            do {
                try await engine.sendChanges(.init(scope: .zoneIDs([zone])))
                clearOffered()
            } catch {
                clearOffered()
                throw error
            }
        }
    }

    private func verifyRecords(_ engine: CKSyncEngine) async throws {
        for ticket in try await journal.verificationRequests(limit: 16) {
            try checkActive(engine)
            let id = CKRecord.ID(recordName: ticket.attempt.key.name, zoneID: zone)
            let record: CKRecord
            do { record = try await fetchRecord(id) }
            catch let error as CKError {
                try checkActive(engine)
                if error.code == .zoneNotFound { throw CloudZoneRecoverySignal.verificationRequired }
                if error.code == .unknownItem { _ = try await journal.resolve(ticket, record: nil) }
                continue
            }
            try checkActive(engine)
            guard record.recordID == id, record.recordType == ticket.attempt.key.type else { continue }
            let captured = try await Self.captureOffMain([record])
            try checkActive(engine)
            _ = try await journal.resolve(ticket, record: captured[0])
        }
    }

    private static func fetchZone(database: CKDatabase, id: CKRecordZone.ID) async throws -> CKRecordZone {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [id])
        return try await ReadingCloudLookup.run(operation, bind: { complete in
            operation.perRecordZoneResultBlock = { @Sendable found, result in
                if found == id { complete(result) }
            }
            operation.fetchRecordZonesResultBlock = { @Sendable result in
                // An item-specific result (including absence) is more precise
                // than the operation's aggregate partialFailure.
                if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                    complete(.failure(error))
                }
            }
        }, submit: { database.add(operation) })
    }

    private func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        try await Self.fetchRecord(database: database, id: id)
    }

    private static func fetchRecord(database: CKDatabase, id: CKRecord.ID) async throws -> CKRecord {
        let operation = CKFetchRecordsOperation(recordIDs: [id])
        return try await ReadingCloudLookup.run(operation, bind: { complete in
            operation.perRecordResultBlock = { @Sendable found, result in
                if found == id { complete(result) }
            }
            operation.fetchRecordsResultBlock = { @Sendable result in
                if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                    complete(.failure(error))
                }
            }
        }, submit: { database.add(operation) })
    }

    private func decideInitialization(_ engine: CKSyncEngine) async throws -> ReadingCloudInitialization.Decision {
        let id = CKRecord.ID(recordName: ReadingCloudInitialization.recordName, zoneID: zone)
        return try await ReadingCloudInitialization.decide(journal: journal, installation: installation, lookup: {
            try self.checkActive(engine)
            do {
                let record = try await self.fetchRecord(id)
                try self.checkActive(engine)
                return try ReadingCloudInitialization.Control.decode(record, in: self.zone)
            } catch let error as CKError where error.code == .unknownItem {
                try self.checkActive(engine)
                return nil
            }
        }, emptyZone: {
            try self.checkActive(engine)
            let result = try await self.confirmEmptyInitializationZone()
            try self.checkActive(engine)
            return result
        }, create: { proposal in
            try self.checkActive(engine)
            let result = try await self.conditionallyCreateInitialization(proposal)
            try self.checkActive(engine)
            return result
        })
    }

    /// Any record (including an unknown type), deletion, or unfinished page
    /// invalidates emptiness. No business payloads/assets or cursor are saved.
    private func confirmEmptyInitializationZone() async throws -> Bool {
        let expectedZone = zone
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.resultsLimit = 1
        configuration.desiredKeys = []
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [expectedZone],
                                                         configurationsByRecordZoneID: [expectedZone: configuration])
        operation.fetchAllChanges = false
        let occupied = Mutex(false)
        return try await ReadingCloudLookup.run(operation, bind: { complete in
            operation.recordWasChangedBlock = { @Sendable _, _ in occupied.withLock { $0 = true } }
            operation.recordWithIDWasDeletedBlock = { @Sendable _, _ in occupied.withLock { $0 = true } }
            operation.recordZoneFetchResultBlock = { @Sendable found, result in
                guard found == expectedZone else { return }
                complete(result.map { !occupied.withLock { $0 } && !$0.moreComing })
            }
            operation.fetchRecordZoneChangesResultBlock = { @Sendable result in
                if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                    complete(.failure(error))
                }
            }
        }, submit: { database.add(operation) })
    }

    private func conditionallyCreateInitialization(_ proposal: ReadingCloudInitialization.Control) async throws
        -> ReadingCloudInitialization.Creation {
        let record = proposal.ckRecord(in: zone)
        do {
            let saved = try await conditionallySaveInitialization(record)
            return .saved(try ReadingCloudInitialization.Control.decode(saved, in: zone))
        } catch let error as CKError where error.code == .serverRecordChanged {
            return .alreadyExists
        }
    }

    private func publishFirstReady(_ expected: ReadingCloudInitialization.Control, engine: CKSyncEngine) async throws
        -> ReadingCloudInitialization.Control {
        let id = CKRecord.ID(recordName: ReadingCloudInitialization.recordName, zoneID: zone)
        try checkActive(engine)
        let original = try await fetchRecord(id)
        try checkActive(engine)
        let current = try ReadingCloudInitialization.Control.decode(original, in: zone)
        guard current.matches(expected) else { throw ReadingCloudInitialization.Failure.inconsistentDecision }
        if current.phase == .ready { return current }
        let update = try ReadingCloudInitialization.readyUpdate(original, expected: expected, zone: zone)
        let saved: CKRecord
        do { saved = try await conditionallySaveInitialization(update) }
        catch {
            // A collision or lost reply can never authorize overwriting a
            // different owner. At most one point read, no unconditional retry.
            try checkActive(engine)
            saved = try await fetchRecord(id)
        }
        try checkActive(engine)
        let ready = try ReadingCloudInitialization.Control.decode(saved, in: zone)
        guard ready.matches(expected), ready.phase == .ready else {
            throw ReadingCloudInitialization.Failure.awaitingFirstUpload
        }
        return ready
    }

    private func conditionallySaveInitialization(_ record: CKRecord) async throws -> CKRecord {
        let id = record.recordID
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = true
        return try await ReadingCloudLookup.run(operation, bind: { complete in
            operation.perRecordSaveBlock = { @Sendable found, result in
                if found == id { complete(result) }
            }
            operation.modifyRecordsResultBlock = { @Sendable result in
                if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                    complete(.failure(error))
                }
            }
        }, submit: { database.add(operation) })
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        Self.scopeFetch(context.options, zone: zone, allowed: applies(syncEngine))
    }

    static func scopeFetch(_ options: CKSyncEngine.FetchChangesOptions, zone: CKRecordZone.ID,
                           allowed: Bool) -> CKSyncEngine.FetchChangesOptions {
        var value = options
        let wanted = allowed && options.scope.contains(zone)
        value.scope = .zoneIDs(wanted ? [zone] : [])
        value.prioritizedZoneIDs = wanted ? [zone] : []
        return value
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard active, syncEngine === engine else { return }
        if let fatal {
            // Keep accepting zone-reason evidence and account invalidation
            // from this still-running delegate turn after a weaker hint.
            // No inbox, ACK, or checkpoint can run after a fatal signal.
            guard fatal is CloudZoneRecoverySignal else { return }
            switch event {
            case .fetchedDatabaseChanges, .accountChange: break
            default: return
            }
        }
        do {
            switch event {
            case .accountChange(let event):
                if initialSignInAllowed, case .signIn(let identity) = event.changeType, identity == account {
                    initialSignInAllowed = false
                } else {
                    fatal = Failure.accountChanged
                    journal.retire()
                }
            case .didFetchRecordZoneChanges(let event) where event.zoneID == zone:
                if joiningControl != nil { joiningZoneFinished = event.error == nil }
                else { ownZoneFetchSucceeded = event.error == nil }
                if event.error?.code == .zoneNotFound { ownZoneMissingDuringFetch = true }
            case .didFetchChanges:
                initialSignInAllowed = false
            case .didSendChanges:
                initialSignInAllowed = false
            case .stateUpdate(let update):
                let bytes = try JSONEncoder().encode(update.stateSerialization)
                if joiningControl != nil { joiningCheckpoint = bytes }
                else { try await journal.persistCheckpoint(bytes) }
            case .fetchedRecordZoneChanges(let event):
                let ownRecords = event.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
                let ownDeletions = event.deletions.filter { $0.recordID.zoneID == zone }
                if ownDeletions.contains(where: { $0.recordID.recordName == ReadingCloudInitialization.recordName }) {
                    throw ReadingCloudInitialization.Failure.accountAlreadyHadZone
                }
                let businessRecords = try ownRecords.filter { record in
                    guard record.recordID.recordName == ReadingCloudInitialization.recordName else { return true }
                    let decoded = try ReadingCloudInitialization.Control.decode(record, in: zone)
                    if let joiningControl, decoded != joiningControl {
                        throw ReadingCloudInitialization.Failure.inconsistentDecision
                    }
                    return false
                }
                let ownDeletes = ownDeletions
                    .map { CloudInboxRows.Deletion(type: $0.recordType, name: $0.recordID.recordName) }
                if !businessRecords.isEmpty || !ownDeletes.isEmpty {
                    if joiningControl != nil { joiningCheckpoint = nil }
                    try await capturePage(businessRecords, deletions: ownDeletes, engine: syncEngine)
                }
            case .sentDatabaseChanges(let event):
                if event.savedZones.contains(where: { $0.zoneID == zone }) { _ = try await journal.confirmZoneCreation() }
            case .fetchedDatabaseChanges(let event):
                var ownDeletion: CloudTransportRows.ZoneDeletion?
                for deletion in event.deletions where deletion.zoneID == zone {
                    switch deletion.reason {
                    case .purged: ownDeletion = .purged
                    case .encryptedDataReset: ownDeletion = .encryptedDataReset
                    case .deleted: if ownDeletion == nil { ownDeletion = .deleted }
                    @unknown default: break
                    }
                }
                if let ownDeletion {
                    // Other SDK events cannot advance the checkpoint while
                    // the App has yet to consume this durable reason.
                    fatal = CloudZoneRecoverySignal.verificationRequired
                    fatal = try await journal.holdZoneDeletion(ownDeletion)
                }
            case .sentRecordZoneChanges(let event):
                try await applySent(event, engine: syncEngine)
                await reportUploadProgress()
            default: break
            }
        } catch {
            fatal = error
        }
    }

    private func capturePage(_ records: [CKRecord], deletions: [CloudInboxRows.Deletion], engine: CKSyncEngine) async throws {
        let captured = try await Self.captureOffMain(records)
        try await applyCapturedPage(captured, deletions: deletions, engine: engine)
    }

    private func applyCapturedPage(_ records: [CloudInboxRows.Record], deletions: [CloudInboxRows.Deletion],
                                   engine: CKSyncEngine) async throws {
        try checkActive(engine)
        if let joiningControl {
            try await journal.stageJoiningPage(joiningControl, records: records, deletions: deletions)
            if let reportPhase {
                let count = try? await journal.joiningReceivedCount()
                await reportPhase(.firstDownload(received: count))
            }
        } else {
            try await journal.applyOwnInbox(records: records, deletions: deletions)
            try checkActive(engine)
            await reportUploadProgress()
            receivedChanges()
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard applies(syncEngine) else { return nil }
        do {
            let durable = try await journal.pendingInOwnZone()
            let sends = Set(syncEngine.state.pendingRecordZoneChanges)
            var saves = [CKRecord](), deletes = [CKRecord.ID]()
            for item in durable {
                if saves.count + deletes.count == 16 { break }
                try checkActive(syncEngine)
                let id = CKRecord.ID(recordName: item.key.name, zoneID: zone)
                let change: CKSyncEngine.PendingRecordZoneChange = item.isSave ? .saveRecord(id) : .deleteRecord(id)
                guard sends.contains(change), context.options.scope.contains(change) else { continue }
                // An outstanding offer may be requested again, but only while
                // it still belongs to the current durable attempt.
                guard let prepared = try await prepare(item, id: id) else { continue }
                try checkActive(syncEngine)
                offered[id] = prepared
                if let record = prepared.record { saves.append(record) } else { deletes.append(id) }
            }
            if saves.isEmpty && deletes.isEmpty { return nil }
            return .init(recordsToSave: saves, recordIDsToDelete: deletes)
        } catch {
            fatal = error
            return nil
        }
    }

    private func prepare(_ item: CloudCallbackJournal.Pending, id: CKRecord.ID) async throws -> Offered? {
        let attempt: CloudTransportRows.Attempt, payload: String?, fields: Data?, logical: String?, device: String?, mark: String?, attachment: Data?
        if let family = FixedValueCloudRows.Family(rawValue: item.key.type),
           let value = try await journal.prepareFixedValueChange(family, id: item.businessID) {
            attempt = value.attempt; payload = value.payload; fields = value.systemFields
            logical = value.logical; device = value.device; mark = nil; attachment = value.attachment
        } else if let type = ReadingHistoryTransport.RecordType(rawValue: item.key.type),
                  let value = try await journal.prepareHistoryChange(type: type, id: item.businessID) {
            attempt = value.attempt; payload = value.payload; fields = value.systemFields
            logical = value.logical; device = nil; mark = nil; attachment = nil
        } else if let family = CausalCloudRows.Family(rawValue: item.key.type),
                  let value = try await journal.prepareCausalChange(family, id: item.businessID) {
            attempt = value.attempt; payload = value.material?.payload; fields = value.systemFields
            logical = value.material?.book; device = value.material?.device; mark = value.material?.mark; attachment = nil
        } else { return nil }
        guard attempt.key == item.key, item.isSave == (payload != nil) else { return nil }
        if let previous = offered[id] {
            // Never replace an in-flight offer with a different generation.
            return previous.attempt == attempt ? previous : nil
        }
        guard let payload else { return .init(attempt: attempt, record: nil, asset: nil) }
        let record: CKRecord
        do { record = try Self.restoreRecord(id: id, type: item.key.type, fields: fields) }
        catch {
            try await journal.requireMissingSaveVerification(attempt)
            return nil
        }
        record["businessID"] = item.businessID
        record["logical"] = logical
        record["device"] = device
        record["mark"] = mark
        record["payload"] = payload
        var file: URL?
        if let attachment {
            guard attachment.count <= Self.attachmentLimit else { return nil }
            let url = staging.appending(path: UUID().uuidString)
            do { try attachment.write(to: url, options: .atomic) }
            catch { return nil }
            record["attachment"] = CKAsset(fileURL: url)
            file = url
        } else { record["attachment"] = nil }
        return .init(attempt: attempt, record: record, asset: file)
    }

    private func applySent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) async throws {
        var results = [CloudCallbackJournal.Sent]()
        var completed = Set<CKRecord.ID>()
        for record in event.savedRecords where record.recordID.zoneID == zone {
            guard let entry = offered[record.recordID], entry.attempt.key.type == record.recordType,
                  let original = entry.record,
                  case .save(let digest) = entry.attempt.intent,
                  let payload = record["payload"] as? String, DataIdentity.sha(Data(payload.utf8)) == digest,
                  record["businessID"] as? String == entry.attempt.businessID,
                  record["logical"] as? String == original["logical"] as? String,
                  record["mark"] as? String == original["mark"] as? String,
                  record["device"] as? String == original["device"] as? String else { continue }
            results.append(.init(attempt: entry.attempt, systemFields: Self.systemFields(record)))
            completed.insert(record.recordID)
        }
        for id in event.deletedRecordIDs where id.zoneID == zone {
            guard let attempt = offered[id]?.attempt, attempt.intent == .delete else { continue }
            results.append(.init(attempt: attempt, systemFields: nil))
            completed.insert(id)
        }
        for (id, error) in event.failedRecordDeletes where id.zoneID == zone && error.code == .unknownItem {
            guard let attempt = offered[id]?.attempt, attempt.intent == .delete else { continue }
            results.append(.init(attempt: attempt, systemFields: nil))
            completed.insert(id)
        }
        _ = try await journal.acknowledge(results)
        try checkActive(engine)
        for id in completed { removeOffer(id) }
        for failure in event.failedRecordSaves where failure.record.recordID.zoneID == zone {
            let id = failure.record.recordID
            guard let entry = offered[id], entry.attempt.key.type == failure.record.recordType,
                  case .save(let digest) = entry.attempt.intent, let payload = failure.record["payload"] as? String,
                  DataIdentity.sha(Data(payload.utf8)) == digest else { continue }
            switch failure.error.code {
            case .unknownItem:
                try await journal.requireMissingSaveVerification(entry.attempt)
            case .serverRecordChanged:
                if let server = failure.error.serverRecord, server.recordID == id, server.recordType == entry.attempt.key.type {
                    let records = try await Self.captureOffMain([server])
                    try checkActive(engine)
                    try await journal.applyOwnInbox(records: records, deletions: [])
                }
            case .zoneNotFound: fatal = CloudZoneRecoverySignal.verificationRequired
            default: break
            }
            removeOffer(id)
        }
        if event.failedRecordDeletes.contains(where: { $0.key.zoneID == zone && $0.value.code == .zoneNotFound }) {
            fatal = CloudZoneRecoverySignal.verificationRequired
        }
    }

    private func id(of change: CKSyncEngine.PendingRecordZoneChange) -> CKRecord.ID? {
        switch change {
        case .saveRecord(let id), .deleteRecord(let id): return id
        @unknown default: return nil
        }
    }

    private func applies(_ sender: CKSyncEngine) -> Bool { active && fatal == nil && sender === engine }

    private func checkActive(_ sender: CKSyncEngine) throws {
        if let fatal { throw fatal }
        guard applies(sender) else { throw Failure.inactive }
        try Task.checkCancellation()
    }

    private func removeOffer(_ id: CKRecord.ID) {
        if let file = offered.removeValue(forKey: id)?.asset { try? FileManager.default.removeItem(at: file) }
    }

    private func clearOffered() { for id in Array(offered.keys) { removeOffer(id) } }

    nonisolated private static func systemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    nonisolated private static func restoreRecord(id: CKRecord.ID, type: String, fields: Data?) throws -> CKRecord {
        guard let fields else { return .init(recordType: type, recordID: id) }
        let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        guard let record = CKRecord(coder: decoder), record.recordID == id, record.recordType == type else {
            throw Failure.invalidSystemFields
        }
        return record
    }

    nonisolated private static func readAttachment(_ handle: FileHandle, limit: Int) throws -> Data? {
        var bytes = Data()
        while bytes.count <= limit {
            let maximum = min(64 * 1024, limit + 1 - bytes.count)
            guard let block = try handle.read(upToCount: maximum), !block.isEmpty else {
                return bytes.isEmpty ? nil : bytes
            }
            bytes.append(block)
        }
        return nil
    }

    nonisolated static func captureOffMain(_ records: [CKRecord]) async throws -> [CloudInboxRows.Record] {
        try await Task.detached {
            var pageRemaining = attachmentLimit * 2
            return try records.map { record in
                // CKAsset URLs are temporary. Capture bytes before returning
                // from the delegate, outside the writer, with a record cap.
                var remaining = attachmentLimit
                let assets = record.allKeys().sorted().flatMap { field -> [(String,CKAsset)] in
                    if let asset = record[field] as? CKAsset { return [(field,asset)] }
                    if let list = record[field] as? [CKAsset] {
                        return list.enumerated().map { ("\(field)[\($0.offset)]",$0.element) }
                    }
                    return []
                }.map { field, asset -> CloudInboxRows.Asset in
                    let limit = min(remaining,pageRemaining)
                    guard limit > 0, let url = asset.fileURL, let handle = try? FileHandle(forReadingFrom: url) else {
                        return .init(field: field, bytes: nil)
                    }
                    defer { try? handle.close() }
                    guard let bytes = try? readAttachment(handle, limit: limit) else {
                        return .init(field: field, bytes: nil)
                    }
                    remaining -= bytes.count
                    pageRemaining -= bytes.count
                    return .init(field: field, bytes: bytes)
                }
                let archived = try? NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                let raw = try archived ?? JSONEncoder().encode(["type": record.recordType, "name": record.recordID.recordName,
                    "payloadPrefix": String((record["payload"] as? String ?? "").prefix(4096))])
                return CloudInboxRows.Record(type: record.recordType, name: record.recordID.recordName,
                    id: record["businessID"] as? String, logical: record["logical"] as? String,
                    device: record["device"] as? String, mark: record["mark"] as? String, payload: record["payload"] as? String,
                    systemFields: systemFields(record), archive: raw, archiveComplete: archived != nil, assets: assets)
            }
        }.value
    }
}
