import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

public enum CloudInboxRows {
    public struct Asset: Codable, Sendable {
        public let field: String
        public let bytes: Data?

        public init(field: String, bytes: Data? = nil) {
            self.field = field
            self.bytes = bytes
        }
    }
    public struct Record: Codable, Sendable {
        public let type, name: String
        public let id, logical, device, mark, payload: String?
        public let systemFields, archive: Data
        let archiveComplete: Bool
        let assets: [Asset]

        public init(type: String,
                    name: String,
                    id: String? = nil,
                    logical: String? = nil,
                    device: String? = nil,
                    mark: String? = nil,
                    payload: String? = nil,
                    systemFields: Data,
                    archive: Data,
                    archiveComplete: Bool,
                    assets: [Asset]) {
            self.type = type
            self.name = name
            self.id = id
            self.logical = logical
            self.device = device
            self.mark = mark
            self.payload = payload
            self.systemFields = systemFields
            self.archive = archive
            self.archiveComplete = archiveComplete
            self.assets = assets
        }
    }
    public struct Deletion: Hashable, Sendable {
        public let type, name: String

        public init(type: String, name: String) {
            self.type = type
            self.name = name
        }
    }

    public static func apply(_ db: Database, records: [Record], deletions: [Deletion], scope: DataScope) throws {
        var changed = ReadingHistoryRows.Changed()
        try stage(db, records: records, deletions: deletions, scope: scope, changed: &changed)
        try changed.settle(db, scope: scope)
    }

    static func stage(_ db: Database, records: [Record], deletions: [Deletion], scope: DataScope,
                      changed: inout ReadingHistoryRows.Changed, completeBaseline: Bool = false) throws {
        let removed = Set(deletions)
        var history = [ReadingHistoryTransport.Fetched]()
        for record in records where !removed.contains(.init(type: record.type, name: record.name)) {
            if let type = ReadingHistoryTransport.RecordType(rawValue: record.type) {
                if record.payload == nil { try isolate(db, record, trusted: nil, reason: "cloud-missing-history-payload") }
                let routedBook = completeBaseline && record.id.map({ ReadingHistoryTransport.name(type, id: $0) }) != record.name
                    ? nil : record.logical
                history.append(.init(type: type, recordName: record.name, id: record.id, trustedBook: routedBook,
                                     body: record.payload ?? "{\"v\":0}", systemFields: record.systemFields))
            } else if let family = CausalCloudRows.Family(rawValue: record.type) {
                try applyCausalOrIsolate(db, family, record)
            } else {
                try applyFixedOrIsolate(db, record)
            }
        }
        for deletion in deletions {
            if let family = FixedValueCloudRows.Family(rawValue: deletion.type) {
                _ = try FixedValueCloudRows.applyDeletion(db, family, name: deletion.name)
            } else if let family = CausalCloudRows.Family(rawValue: deletion.type) {
                try CausalCloudRows.delete(db, family, name: deletion.name)
            } else if let type = ReadingHistoryTransport.RecordType(rawValue: deletion.type) {
                history.append(.init(type: type, recordName: deletion.name, id: nil, trustedBook: nil, body: nil))
                try deleteOpaque(db, deletion)
            } else {
                try deleteOpaque(db, deletion)
            }
        }
        if completeBaseline {
            try ReadingHistoryTransport.stageFetched(db, records: history, scope: scope, changed: &changed)
        } else {
            try ReadingHistoryTransport.applyFetched(db, records: history, scope: scope)
        }
    }

    private struct CausalRoute {
        let family: CausalCloudRows.Family
        let id, book: String
        let mark: String?
    }

    private static func applyCausalOrIsolate(_ db: Database, _ family: CausalCloudRows.Family, _ record: Record) throws {
        guard let id = record.id, let book = record.logical, !id.isEmpty,
              DataIdentity.canonical(id) == id, (try? parseSha256(value: book)) == book,
              CausalCloudRows.key(family, id: id).name == record.name else {
            try isolate(db, record, trusted: nil, reason: "cloud-unrecognized-causal-record")
            return
        }
        let mark = record.mark.flatMap { !$0.isEmpty && DataIdentity.canonical($0) == $0 ? $0 : nil }
        do {
            try db.inSavepoint {
                try CausalCloudRows.ingest(db, family, record: record, id: id, book: book)
                return .commit
            }
        } catch let error where error is UserSyncCompatibilityError || error is DecodingError ||
            error is ReadingDataError || error is ReaderError {
            let known = try Row.fetchOne(db, sql: """
                SELECT book_key\(family == .annotation ? ",mark_id" : "") FROM usr.\(family.table)
                WHERE partition=0 AND record_id=?
                """, arguments: [id])
            // A same-ID conflict applies to the route we already know,
            // not merely to the conflicting peer's asserted book or mark.
            let originalBook: String = known?["book_key"] ?? book
            let originalMark: String? = family == .annotation ? (known?["mark_id"] ?? mark) : nil
            let route = CausalRoute(family: family, id: id, book: originalBook, mark: originalMark)
            try isolate(db, record, trusted: nil, causal: route, reason: "cloud-incompatible-causal-record")
            try CloudTransportRows.recordPresent(db, CausalCloudRows.key(family, id: id), businessID: id,
                                                  systemFields: record.systemFields)
        }
    }

    static func applyFixedOrIsolate(_ db: Database, _ record: Record, verifying: Bool = false) throws {
        guard let family = FixedValueCloudRows.Family(rawValue: record.type),
              let id = record.id, let logical = record.logical, let device = record.device,
              let key = try? UserValueRows.Key(logical), FixedValueCloudRows.Family(key.kind) == family,
              logical == key.logical,
              UserValueRows.recordID(logical: logical, device: device) == id,
              FixedValueCloudRows.key(family, id: id).name == record.name else {
            try isolate(db, record, trusted: nil, reason: "cloud-unrecognized-record")
            return
        }
        guard let payload = record.payload else {
            try isolate(db, record, trusted: key, reason: "cloud-missing-payload")
            return
        }
        let asset = record.assets.first(where: { $0.field == "attachment" })?.bytes
        do {
            try db.inSavepoint {
                if try FixedValueCloudRows.receiveMissingCover(db, record, verifying: verifying) { return .commit }
                try FixedValueCloudRows.applyRemote(db, .init(family: family, name: record.name, id: id, logical: logical,
                    device: device, payload: payload, attachment: asset, systemFields: record.systemFields), verifying: verifying)
                return .commit
            }
        } catch is UserSyncCompatibilityError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch is DecodingError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch is ReaderError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        } catch ReadingDataError.missingAsset {
            try isolate(db, record, trusted: key, reason: "unavailable-attachment")
        } catch is ReadingDataError {
            try isolate(db, record, trusted: key, reason: "cloud-incompatible-value")
        }
    }

    private static func deleteOpaque(_ db: Database, _ deletion: Deletion) throws {
        try db.execute(sql: """
            DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=?
              AND raw_format IN ('ck-record-archive','ck-record-summary')
            """, arguments: [deletion.type,deletion.name])
    }

    private static func isolate(_ db: Database, _ record: Record, trusted: UserValueRows.Key?, causal: CausalRoute? = nil,
                                reason: String) throws {
        let digest = DataIdentity.sha(record.archive)
        let id = causal?.id ?? (trusted == nil ? record.name : (record.id ?? record.name))
        let complete = record.archiveComplete && !record.assets.contains { $0.bytes == nil } && reason != "unavailable-attachment"
        let logical = trusted?.logical ?? causal.flatMap { $0.family == .position ? "position/" + $0.book : nil }
        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,logical_key,mark_id,
                raw_format,raw_bytes,digest,reason,completeness)
              VALUES(0,'cloud',?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason) DO NOTHING
            """, arguments: [record.name,record.type,id,trusted?.book ?? causal?.book,logical,causal?.mark,
                            record.archiveComplete ? "ck-record-archive" : "ck-record-summary",
                            record.archive,digest,reason,complete ? "complete" : "incomplete"])
        let quarantine = try Int64.fetchOne(db, sql: """
            SELECT quarantine_id FROM usr.quarantined_record
            WHERE partition=0 AND source='cloud' AND source_id=? AND source_type=? AND record_id=? AND digest=? AND reason=?
            """, arguments: [record.name,record.type,id,digest,reason])
        guard let quarantine else { throw DataV2Error.migrationNotVerified }
        let assets = (reason == "unavailable-attachment" && !record.assets.contains(where: { $0.field == "attachment" }))
            ? record.assets + [.init(field: "attachment", bytes: nil)] : record.assets
        for asset in assets {
            try db.execute(sql: """
                INSERT INTO usr.quarantine_asset(quarantine_id,field,bytes,digest,missing_reason)
                VALUES(?,?,?,?,?) ON CONFLICT(quarantine_id,field) DO UPDATE SET
                    bytes=excluded.bytes,digest=excluded.digest,missing_reason=excluded.missing_reason
                WHERE quarantine_asset.bytes IS NULL
                """, arguments: [quarantine,asset.field,asset.bytes,asset.bytes.map(DataIdentity.sha),
                                asset.bytes == nil ? "unavailable-attachment" : nil])
        }
        try CloudTransportRows.withdrawInitialSave(db,
            .init(zone: ReadingHistoryTransport.zone, type: record.type, name: record.name))
        if let trusted { try trusted.settle(db) }
        if let causal { try CausalCloudRows.settle(db, causal.family, book: causal.book, mark: causal.mark) }
    }
}
