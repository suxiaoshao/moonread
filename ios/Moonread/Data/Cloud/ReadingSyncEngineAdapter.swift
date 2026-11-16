import CloudKit
import Foundation

/// Proof carried by one explicit, scoped fetch. An opaque state event alone
/// is never a fetch watermark. Each new inbox page invalidates an older state.
struct OwnZoneFetchProof {
    let floor: Int64
    private(set) var began = false
    private var ended = false
    private var failed = false
    private var endedTurn = false
    private var deliveredPage = false
    private var stateAfterPage: Data?

    init(floor: Int64) { self.floor = floor }

    mutating func beganZone() {
        if began { failed = true }
        began = true
    }
    mutating func committedPage() {
        if !began || ended { failed = true }
        deliveredPage = true
        stateAfterPage = nil
    }
    mutating func updatedState(_ state: Data) {
        if began { stateAfterPage = state }
    }
    mutating func endedZone(success: Bool) {
        if !began || ended || !success { failed = true }
        ended = true
    }
    mutating func finishedFetch() { endedTurn = true }

    func coverage(previousCheckpoint: Data?, moreOwnChanges: Bool) -> Data? {
        guard began, ended, endedTurn, !failed, !moreOwnChanges else { return nil }
        // A complete empty zone response with no new state has retained the
        // prior durable cursor. A committed page always needs newer state.
        return stateAfterPage ?? (deliveredPage ? nil : previousCheckpoint)
    }
}

/// Network orchestration shared by the SDK delegate and the local fixture.
/// Awaits below run outside CKSyncEngineDelegate.handleEvent.
@MainActor
enum ReadingSyncTurn {
    static func run(fetch: () async throws -> Bool, verify: () async throws -> Bool,
                    send: () async throws -> Void, needsCatchUp: () async throws -> Bool) async throws {
        _ = try await fetch()
        _ = try await verify()
        try await send()
        while true {
            let covered: Bool
            if try await needsCatchUp() { covered = try await fetch() }
            else { covered = false }
            let verified = try await verify()
            // A nil/failed coverage doesn't release anything or spin.
            guard covered || verified else { return }
            // Rebuild SDK pending from the durable outbox every time, after
            // the checkpoint transaction, including un-offered replacements.
            try await send()
        }
    }
}

/// One scan makes forward progress by key, even when every earlier item
/// fails. The boundary is per page; there is no persisted retry cursor.
@MainActor
enum CloudVerificationScan {
    static func run(page: (CloudTransportRows.Key?, Int) async throws -> [CloudSaveVerification.Ticket],
                    inspect: (CloudSaveVerification.Ticket) async throws -> Bool) async throws -> Bool {
        let pageSize = 16
        var after: CloudTransportRows.Key?
        var progressed = false
        while true {
            let tickets = try await page(after, pageSize)
            for ticket in tickets {
                if try await inspect(ticket) { progressed = true }
            }
            guard tickets.count == pageSize else { return progressed }
            after = tickets.last?.attempt.key
        }
    }
}

/// The first integration uses a separately attributed test account library
/// and the dedicated Development test container. No caller in the App's
/// production lifecycle constructs this adapter yet.
@MainActor
final class ReadingSyncEngineAdapter: CKSyncEngineDelegate {
    static let testContainer = "iCloud.dev.moonread.SyncProbe"
    static let ownZone = CKRecordZone.ID(zoneName: ReadingHistoryTransport.zone, ownerName: CKCurrentUserDefaultName)
    nonisolated private static let attachmentLimit = 16 * 1024 * 1024

    enum Failure: Error {
        case inactive, accountChanged, busy, wrongIdentity, invalidSystemFields, zoneNotReady, zoneVerificationRequired
    }

    private struct Offered {
        let attempt: CloudTransportRows.Attempt
        let record: CKRecord?
        let asset: URL?
    }

    private let journal: CloudCallbackJournal
    private let database: CKDatabase
    private let account: CKRecord.ID
    private let staging: URL
    private let zone: CKRecordZone.ID
    private var engine: CKSyncEngine?
    private var active = true
    private var running = false
    private var initialSignInAllowed: Bool
    private var fatal: (any Error)?
    private var deferredZoneLoss: CloudAccountZoneRecovery.Loss?
    private var proof: OwnZoneFetchProof?
    private var offered: [CKRecord.ID: Offered] = [:]

    private init(journal: CloudCallbackJournal, database: CKDatabase, account: CKRecord.ID, staging: URL,
                 zone: CKRecordZone.ID, initialSignInAllowed: Bool) {
        self.journal = journal; self.database = database; self.account = account; self.staging = staging
        self.zone = zone; self.initialSignInAllowed = initialSignInAllowed
    }

    /// Bind to a library prepared by the test host. The scope key includes
    /// this literal container and Development; a production lease cannot pass.
    static func openTestContainer(session: DataSession, lease: DataSessionLease) async throws -> ReadingSyncEngineAdapter {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let synthetic = session.layout.root.resolvingSymlinksInPath().path
        guard synthetic.hasPrefix(temporary + "/Moonread-CKProbe-") else { throw Failure.wrongIdentity }
        let container = CKContainer(identifier: testContainer)
        let account = try await container.userRecordID()
        let expected = try DataScope.confirmed(container: testContainer, environment: .development, recordName: account.recordName)
        guard lease.scope == expected else { throw Failure.wrongIdentity }
        let database = container.privateCloudDatabase
        let root = try session.layout.staging(lease.scope).appending(path: "ck-sandbox-" + UUID().uuidString, directoryHint: .isDirectory)
        let journal = try CloudCallbackJournal(session: session, lease: lease)
        do {
            let bytes = try await journal.checkpoint()
            try Task.checkCancellation()
            let state = try bytes.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let adapter = ReadingSyncEngineAdapter(journal: journal, database: database, account: account, staging: root,
                                                   zone: ownZone, initialSignInAllowed: bytes == nil)
            var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: state, delegate: adapter)
            configuration.automaticallySync = false
            configuration.subscriptionID = "Moonread-SyncProbe-v2"
            adapter.engine = CKSyncEngine(configuration)
            return adapter
        } catch {
            journal.retire()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    var requestedZoneLoss: CloudAccountZoneRecovery.Loss? { deferredZoneLoss }

    func close() async {
        active = false
        journal.retire()
        let old = engine
        engine = nil
        await old?.cancelOperations()
        clearOffered()
        try? FileManager.default.removeItem(at: staging)
    }

    func syncNow() async throws {
        guard let engine else { throw Failure.inactive }
        try checkActive(engine)
        guard !running else { throw Failure.busy }
        running = true
        defer { running = false; proof = nil }
        try await ready(engine)
        try await ReadingSyncTurn.run(fetch: { try await self.fetchOwnZone(engine) },
                                      verify: { try await self.verifyRecords(engine) },
                                      send: { try await self.sendDurable(engine) },
                                      needsCatchUp: { try await self.journal.requiresOwnZoneCatchUp() })
        try checkActive(engine)
    }

    private func ready(_ engine: CKSyncEngine) async throws {
        let stage = try await journal.zoneStage()
        try checkActive(engine)
        if stage == .unverified {
            do {
                let found = try await database.recordZone(for: zone)
                try checkActive(engine)
                guard found.zoneID == zone else { throw Failure.wrongIdentity }
                try await journal.initializeZone(exists: true)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                try checkActive(engine)
                try await journal.initializeZone(exists: false)
            }
        }
        if try await journal.zoneStage() == .needsCreation {
            try checkActive(engine)
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zone))])
            try await engine.sendChanges(.init(scope: .zoneIDs([zone])))
        }
        try checkActive(engine)
        guard try await journal.zoneStage() == .ready else { throw Failure.zoneNotReady }
    }

    private func fetchOwnZone(_ engine: CKSyncEngine) async throws -> Bool {
        try checkActive(engine)
        let previous = try await journal.checkpoint()
        let floor = try await journal.ownZoneFetchFloor()
        try checkActive(engine)
        proof = OwnZoneFetchProof(floor: floor)
        defer { proof = nil }
        try await engine.fetchChanges(.init(scope: .zoneIDs([zone])))
        try checkActive(engine)
        guard let proof, let state = proof.coverage(previousCheckpoint: previous,
            moreOwnChanges: engine.state.zoneIDsWithUnfetchedServerChanges.contains(zone)) else { return false }
        try await journal.persistCheckpoint(state, confirmedOwnZoneThrough: proof.floor)
        return true
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

    private func verifyRecords(_ engine: CKSyncEngine) async throws -> Bool {
        try await CloudVerificationScan.run(page: { after, limit in
            try await self.journal.verificationRequests(after: after, limit: limit)
        }) { ticket in
            try checkActive(engine)
            let id = CKRecord.ID(recordName: ticket.attempt.key.name, zoneID: zone)
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError {
                try checkActive(engine)
                switch error.code {
                case .unknownItem:
                    return try await journal.resolve(ticket, record: nil)
                case .zoneNotFound:
                    throw Failure.zoneVerificationRequired
                default:
                    // A transport error is not a proof of absence. Keep this
                    // ID's durable hold, and allow other IDs in the same turn.
                    return false
                }
            }
            try checkActive(engine)
            guard record.recordID == id, record.recordType == ticket.attempt.key.type else { return false }
            let captured = try await Self.captureOffMain([record])
            try checkActive(engine)
            return try await journal.resolve(ticket, record: captured[0])
        }
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
        guard applies(syncEngine) else { return }
        do {
            switch event {
            case .accountChange(let event):
                if initialSignInAllowed, case .signIn(let identity) = event.changeType, identity == account {
                    initialSignInAllowed = false
                } else {
                    fatal = Failure.accountChanged
                    journal.retire()
                }
            case .willFetchRecordZoneChanges(let event) where event.zoneID == zone:
                proof?.beganZone()
            case .didFetchRecordZoneChanges(let event) where event.zoneID == zone:
                proof?.endedZone(success: event.error == nil)
            case .didFetchChanges:
                initialSignInAllowed = false
                proof?.finishedFetch()
            case .didSendChanges:
                initialSignInAllowed = false
            case .stateUpdate(let update):
                let bytes = try JSONEncoder().encode(update.stateSerialization)
                if proof != nil { proof?.updatedState(bytes) }
                else { try await journal.persistCheckpoint(bytes) }
            case .fetchedRecordZoneChanges(let event):
                let ownRecords = event.modifications.map(\.record).filter { $0.recordID.zoneID == zone }
                let ownDeletes = event.deletions.filter { $0.recordID.zoneID == zone }
                    .map { CloudInboxRows.Deletion(type: $0.recordType, name: $0.recordID.recordName) }
                if !ownRecords.isEmpty || !ownDeletes.isEmpty {
                    let captured = try await Self.captureOffMain(ownRecords)
                    try checkActive(syncEngine)
                    try await journal.applyOwnInbox(records: captured, deletions: ownDeletes)
                    proof?.committedPage()
                }
            case .sentDatabaseChanges(let event):
                if event.savedZones.contains(where: { $0.zoneID == zone }) { _ = try await journal.confirmZoneCreation() }
            case .fetchedDatabaseChanges(let event):
                for deletion in event.deletions where deletion.zoneID == zone {
                    switch deletion.reason {
                    case .purged: deferredZoneLoss = .purged
                    case .encryptedDataReset: deferredZoneLoss = .encryptedDataReset
                    case .deleted: deferredZoneLoss = .confirmedUnexpectedAbsence
                    @unknown default: break
                    }
                    // The lifecycle owner first fences App writers and then
                    // runs the destructive transaction/reopens a new engine.
                    if deferredZoneLoss != nil { fatal = Failure.zoneVerificationRequired }
                }
            case .sentRecordZoneChanges(let event):
                try await applySent(event, engine: syncEngine)
            default: break
            }
        } catch {
            fatal = error
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
            logical = nil; device = nil; mark = nil; attachment = nil
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
            case .zoneNotFound: fatal = Failure.zoneVerificationRequired
            default: break
            }
            removeOffer(id)
        }
        if event.failedRecordDeletes.contains(where: { $0.key.zoneID == zone && $0.value.code == .zoneNotFound }) {
            fatal = Failure.zoneVerificationRequired
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
