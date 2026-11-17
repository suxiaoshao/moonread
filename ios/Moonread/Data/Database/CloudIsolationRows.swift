import Foundation
import GRDB

/// Copies evidence between the quarantine tables of the two accounts' local
/// installs. Never decodes a quarantined payload as a current domain value.
enum CloudIsolationRows {
    static let type = "ReadingIsolationEvidence"
    private static let originalFactField = "moonread-original-formal-reading-fact-v1"

    struct Material: Sendable {
        let payload: String
        let book: String?
        let attachment: Data
    }

    private struct Header: Codable {
        let v: Int
        let packetSHA: String
    }

    private struct Attachment: Codable {
        let field: String
        let bytes: Data
        let digest: String
    }

    private struct Packet: Codable {
        let source, sourceID, sourceType, id, format, digest, reason, completeness: String
        let book, logical, mark, session, device: String?
        let schema: Int?
        let bytes: Data
        let attachments: [Attachment]

        var name: String { CloudIsolationRows.type + "-" + DataIdentity.id("isolated-cloud-v1", [
            source,sourceID,sourceType,id,digest,reason
        ]) }

        var retainedMissingCover: Bool {
            source == "swiftdata" && sourceType == "UserCover" && format == "legacy-cover-id"
                && reason == "unavailable-attachment" && completeness == "incomplete" && attachments.isEmpty
        }

        var valid: Bool {
            !source.isEmpty && !sourceType.isEmpty && sourceType != CloudIsolationRows.type
                && !id.isEmpty && !format.isEmpty && !reason.isEmpty
                && (completeness == "complete" || retainedMissingCover)
                && DataIdentity.sha(bytes) == digest
                && (book.map { (try? parseSha256(value: $0)) == $0 } ?? true)
                && Set(attachments.map(\.field)).count == attachments.count
                && attachments.allSatisfy { !$0.field.isEmpty && DataIdentity.sha($0.bytes) == $0.digest }
        }

        init(_ row: Row, attachments: [Attachment]) {
            source = row["source"]; sourceID = row["source_id"]; sourceType = row["source_type"]; id = row["record_id"]
            format = row["raw_format"]; digest = row["digest"]; reason = row["reason"]; completeness = row["completeness"]
            book = row["book_key"]; logical = row["logical_key"]; mark = row["mark_id"]
            session = row["session_id"]; device = row["device_id"]; schema = row["schema_version"]
            bytes = row["raw_bytes"]; self.attachments = attachments
        }
    }

    static func key(_ name: String) -> CloudTransportRows.Key {
        .init(zone: ReadingHistoryTransport.zone, type: type, name: name)
    }

    private static func packet(_ db: Database, row: Row) throws -> Packet? {
        guard (row["source"] as String) != CloudBootstrapFold.heldSource else { return nil }
        let id: Int64 = row["quarantine_id"]
        let limit = ReadingSyncEngineAdapter.attachmentLimit
        let sizes = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(length(bytes)),0) AS total,COUNT(*)-COUNT(bytes) AS missing
              FROM usr.quarantine_asset WHERE quarantine_id=?
            """, arguments: [id])
        let total: Int = sizes?["total"] ?? 0
        guard (sizes?["missing"] as Int? ?? 0) == 0, total <= limit,
              (row["raw_bytes"] as Data).count <= limit - total else { return nil }
        let assets = try Row.fetchAll(db, sql: """
            SELECT field,bytes,digest FROM usr.quarantine_asset WHERE quarantine_id=? ORDER BY field
            """, arguments: [id]).map { Attachment(field: $0["field"], bytes: $0["bytes"], digest: $0["digest"]) }
        let packet = Packet(row, attachments: assets)
        return packet.valid ? packet : nil
    }

    private static func material(_ packet: Packet) throws -> Material? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attachment = try encoder.encode(packet)
        guard attachment.count <= ReadingSyncEngineAdapter.attachmentLimit else { return nil }
        let header = String(decoding: try encoder.encode(Header(v: 1, packetSHA: DataIdentity.sha(attachment))), as: UTF8.self)
        return .init(payload: header, book: packet.book, attachment: attachment)
    }

    /// Turn an original quarantine member into a regular sendable member.
    /// The FK still ties it to the original evidence, including across restarts.
    static func stageInitial(_ db: Database, quarantineID: Int64, refreshing: Bool = false) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT q.* FROM usr.quarantined_record q JOIN usr.cloud_initial_member m ON m.quarantine_id=q.quarantine_id
            WHERE q.partition=0 AND q.quarantine_id=? AND (m.record_type='' OR (? AND m.record_type=?))
            """, arguments: [quarantineID,refreshing,type]) else { return }
        guard let packet = try packet(db, row: row), let material = try material(packet) else {
            if let name = row["cloud_isolation_name"] as String? {
                try CloudTransportRows.withdrawSave(db, key(name))
            }
            return
        }
        try db.execute(sql: "UPDATE usr.quarantined_record SET cloud_isolation_name=? WHERE quarantine_id=?",
                       arguments: [packet.name,quarantineID])
        try db.execute(sql: """
            UPDATE usr.cloud_initial_member SET record_type=?,record_name=?,business_id=?,blocked_reason=NULL
             WHERE quarantine_id=? AND record_type IN ('',?)
            """, arguments: [type,packet.name,packet.name,quarantineID,type])
        try CloudTransportRows.enqueueSave(db, key(packet.name), businessID: packet.name,
                                           digest: DataIdentity.sha(Data(material.payload.utf8)))
    }

    static func gatherBlockedFact(_ db: Database, id: String) throws {
        let evidence = try Row.fetchAll(db, sql: """
            SELECT q.quarantine_id,q.raw_bytes,q.raw_format FROM usr.quarantined_record q
            WHERE q.partition=0 AND q.record_id=? AND q.source_type IN (\(ReadingFactRows.quarantineFactTypes))
            ORDER BY q.quarantine_id
            """, arguments: [id])
        guard let first = evidence.first, let witness = try ReadingFactSettlement.initialIsolationWitness(db, id: id) else { return }
        for row in evidence {
            let quarantine: Int64 = row["quarantine_id"]
            try db.execute(sql: """
                INSERT OR IGNORE INTO usr.cloud_initial_member(record_type,record_name,business_id,blocked_reason,quarantine_id)
                SELECT '',CAST(?1 AS TEXT),?2,'unrepresented',?1
                WHERE NOT EXISTS(SELECT 1 FROM usr.cloud_initial_member WHERE quarantine_id=?1)
                """, arguments: [quarantine,id])
        }
        if !evidence.contains(where: { ($0["raw_format"] as String) == "typed-reading-fact-v1" && ($0["raw_bytes"] as Data) == witness }) {
            let quarantine: Int64 = first["quarantine_id"]
            try db.execute(sql: """
                INSERT INTO usr.quarantine_asset(quarantine_id,field,bytes,digest,missing_reason)
                VALUES(?,?,?,?,NULL) ON CONFLICT(quarantine_id,field) DO NOTHING
                """, arguments: [quarantine,originalFactField,witness,DataIdentity.sha(witness)])
            if db.changesCount > 0 { try stageInitial(db, quarantineID: quarantine, refreshing: true) }
        }
    }

    static func coveredBlockedFact(_ db: Database, id: String) throws -> Bool {
        guard let witness = try ReadingFactSettlement.initialIsolationWitness(db, id: id) else { return false }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(
                SELECT 1 FROM usr.quarantined_record q JOIN usr.cloud_initial_member m USING (quarantine_id)
                WHERE q.partition=0 AND q.record_id=?1 AND q.source_type IN (\(ReadingFactRows.quarantineFactTypes))
                  AND m.record_type=?2 AND m.confirmed=1
                  AND ((q.raw_format='typed-reading-fact-v1' AND q.raw_bytes=?3) OR EXISTS(
                    SELECT 1 FROM usr.quarantine_asset a WHERE a.quarantine_id=q.quarantine_id
                      AND a.field=?4 AND a.bytes=?3))
            )
            """, arguments: [id,type,witness,originalFactField]) == true
    }

    static func current(_ db: Database, name: String) throws -> Material? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM usr.quarantined_record WHERE partition=0 AND cloud_isolation_name=?
            """, arguments: [name]), let packet = try packet(db, row: row), packet.name == name else { return nil }
        return try material(packet)
    }

    /// Missing or unreadable SDK asset is not an intentional missing marker.
    /// The journal will not advance past a packet it could not capture.
    enum Failure: Error { case attachmentNotCaptured }

    static func receive(_ db: Database, _ record: CloudInboxRows.Record, changed: inout ReadingHistoryRows.Changed) throws {
        let key = key(record.name)
        if try CloudTransportRows.deletionPending(db, key) { return }
        guard let payload = record.payload,
              let header = try? JSONDecoder().decode(Header.self, from: Data(payload.utf8)), header.v == 1,
              let captured = record.assets.first(where: { $0.field == "attachment" })
        else { throw UserSyncCompatibilityError() }
        guard let asset = captured.bytes else { throw Failure.attachmentNotCaptured }
        guard asset.count <= ReadingSyncEngineAdapter.attachmentLimit, DataIdentity.sha(asset) == header.packetSHA,
              let packet = try? JSONDecoder().decode(Packet.self, from: asset), packet.valid,
              record.id == packet.name, record.name == packet.name, record.logical == packet.book
        else { throw UserSyncCompatibilityError() }

        try db.execute(sql: """
            INSERT INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,mark_id,
                logical_key,session_id,device_id,schema_version,raw_format,raw_bytes,digest,reason,completeness,cloud_isolation_name)
            VALUES(0,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(partition,source,source_id,source_type,record_id,digest,reason)
              DO UPDATE SET cloud_isolation_name=excluded.cloud_isolation_name
            """, arguments: [packet.source,packet.sourceID,packet.sourceType,packet.id,packet.book,packet.mark,packet.logical,
                             packet.session,packet.device,packet.schema,packet.format,packet.bytes,packet.digest,packet.reason,
                             packet.completeness,packet.name])
        guard let quarantine = try Int64.fetchOne(db, sql: "SELECT quarantine_id FROM usr.quarantined_record WHERE cloud_isolation_name=?",
                                                  arguments: [packet.name]) else { throw DataV2Error.migrationNotVerified }
        for asset in packet.attachments {
            try db.execute(sql: """
                INSERT INTO usr.quarantine_asset(quarantine_id,field,bytes,digest,missing_reason) VALUES(?,?,?,?,NULL)
                ON CONFLICT(quarantine_id,field) DO UPDATE SET bytes=excluded.bytes,digest=excluded.digest,missing_reason=NULL
                """, arguments: [quarantine,asset.field,asset.bytes,asset.digest])
        }
        try CloudTransportRows.recordPresent(db, key, businessID: packet.name, systemFields: record.systemFields)
        if let book = packet.book { try CloudTransportRows.rememberCompactedBook(db, key, businessID: packet.name, book: book) }
        try settle(db, type: packet.sourceType, id: packet.id, book: packet.book, mark: packet.mark, logical: packet.logical,
                   session: packet.session, changed: &changed)
    }

    static func delete(_ db: Database, name: String, changed: inout ReadingHistoryRows.Changed) throws {
        if let row = try Row.fetchOne(db, sql: """
            SELECT source_type,record_id,book_key,mark_id,logical_key,session_id FROM usr.quarantined_record
            WHERE partition=0 AND cloud_isolation_name=?
            """, arguments: [name]) {
            try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE partition=0 AND cloud_isolation_name=?", arguments: [name])
            try settle(db, type: row["source_type"], id: row["record_id"], book: row["book_key"], mark: row["mark_id"],
                       logical: row["logical_key"], session: row["session_id"], changed: &changed)
        }
        try CloudTransportRows.applyPeerDeletion(db, key(name))
    }

    static func queueBookDelete(_ db: Database, book: String) throws {
        let names = try String.fetchAll(db, sql: """
            SELECT cloud_isolation_name FROM usr.quarantined_record
              WHERE partition=0 AND book_key=? AND cloud_isolation_name IS NOT NULL
            UNION SELECT record_name FROM usr.cloud_record_state WHERE zone=? AND record_type=? AND book_key=?
            """, arguments: [book,ReadingHistoryTransport.zone,type,book])
        for name in names { try queueRemoval(db, name: name) }
    }

    static func queueRemoval(_ db: Database, name: String) throws {
        try CloudTransportRows.enqueueBookDelete(db, key(name), businessID: name)
        // The same transaction is about to delete the local quarantine row.
        // An offered envelope's DELETE still belongs to the original cut.
        try db.execute(sql: """
            UPDATE usr.cloud_initial_member SET quarantine_id=NULL
            WHERE (record_type,record_name)=(?,?) AND confirmed=0
            """, arguments: [type,name])
    }

    private static func settle(_ db: Database, type: String, id: String, book: String?, mark: String?, logical: String?, session: String?,
                               changed: inout ReadingHistoryRows.Changed) throws {
        if let logical, let key = try? UserValueRows.Key(logical) { try key.settle(db) }
        if ["ReadingFact","reading_fact"].contains(type) { changed.facts.insert(id) }
        else if ["ReadingSegment","reading_segment"].contains(type) { changed.segments.insert(id) }
        else if ["StatisticsClear","statistics_clear"].contains(type) {
            // The original scope is preserved. Re-settle only the affected
            // published reading rows; don't install a guessed clear value.
            changed.clearFacts.formUnion(try ReadingFactSettlement.affectedIDs(db, partition: 0, book: book, session: session))
            changed.clearSegments.formUnion(try ReadingSegmentRows.affected(db, partition: 0, book: book))
        } else if let book {
            if ["AnnotationOperation","annotation_candidate"].contains(type) {
                try CausalCloudRows.settle(db, .annotation, book: book, mark: mark)
            } else if ["UserPosition","ReadingPosition","position_candidate"].contains(type) {
                try ReadingPositionRows.settleCurrent(db, book: book)
            } else if logical == nil {
                try CurrentUserRows.settleMetadata(db, book: book)
            }
        }
    }
}
