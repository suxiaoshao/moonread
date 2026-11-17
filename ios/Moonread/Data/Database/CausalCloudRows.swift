import Foundation
import GRDB

/// The ID identifies a specific position token or annotation operation, not
/// a reusable device slot. Causality stays in the domain's existing columns.
enum CausalCloudRows {
    enum Family: String, CaseIterable, Sendable {
        case position = "ReadingPosition", annotation = "AnnotationOperation"

        var table: String {
            switch self {
            case .position: "position_candidate"
            case .annotation: "annotation_candidate"
            }
        }
    }

    struct Material: Sendable {
        let book: String
        let mark, device: String?
        let payload: String
        var digest: String { DataIdentity.sha(Data(payload.utf8)) }
    }

    struct Prepared: Sendable {
        let attempt: CloudTransportRows.Attempt
        let material: Material?
        let systemFields: Data?
    }

    static func key(_ family: Family, id: String) -> CloudTransportRows.Key {
        .init(zone: ReadingHistoryTransport.zone, type: family.rawValue,
              name: family.rawValue + "-" + DataIdentity.id("causal-record", [family.rawValue,id]))
    }

    static func material(_ db: Database, _ family: Family, id: String) throws -> Material? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM usr.\(family.table) WHERE partition=0 AND record_id=? AND schema_version=1
            """, arguments: [id]) else { return nil }
        let book: String = row["book_key"]
        guard (try? parseSha256(value: book)) == book else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch family {
        case .position:
            do { try ReadingPositionRows.requireFormalPositionReadable(db, book: book) }
            catch is UserSyncCompatibilityError { return nil }
            let value = try ReadingPositionRows.decodedPosition(row)
            let body = try String(decoding: encoder.encode(value.value), as: UTF8.self)
            let envelope = try encoder.encode(StoredValue(updated: value.updated, token: value.token, value: body))
            return .init(book: book, mark: nil, device: value.device,
                         payload: try UserSyncJSON.envelope(String(decoding: envelope, as: UTF8.self)))
        case .annotation:
            let mark: String = row["mark_id"]
            let view = try AnnotationRows.snapshot(db, key: book, markID: mark, partition: 0, reducing: false)
            guard !view.unknownMarks, !view.blocked.contains(mark),
                  let value = view.groups[mark]?.first(where: { $0.id == id }) else { return nil }
            return .init(book: book, mark: mark, device: nil,
                         payload: try UserSyncJSON.envelope(String(decoding: encoder.encode(value), as: UTF8.self)))
        }
    }

    static func enqueueReplacement(_ db: Database, _ family: Family, id: String, predecessors: [String]) throws {
        guard let value = try material(db, family, id: id) else { throw DataV2Error.migrationNotVerified }
        let key = key(family, id: id)
        try CloudTransportRows.enqueueSave(db, key, businessID: id, digest: value.digest)
        guard let saved = try CloudTransportRows.pending(db, key), saved.intent == .save(digest: value.digest)
        else { throw DataV2Error.migrationNotVerified }
        for prior in predecessors where prior != id {
            let predecessor = self.key(family, id: prior)
            try CloudTransportRows.rememberCompactedBook(db, predecessor, businessID: prior, book: value.book)
            try CloudTransportRows.compactAfterSave(db, predecessor: predecessor, id: prior, successor: saved)
        }
    }

    static func prepare(_ db: Database, _ family: Family, id: String) throws -> Prepared? {
        let key = key(family, id: id)
        guard let attempt = try CloudTransportRows.pending(db, key), attempt.businessID == id else { return nil }
        let payload: Material?
        switch attempt.intent {
        case .save(let digest):
            guard try !CloudTransportRows.awaitingVerification(db, key),
                  let found = try material(db, family, id: id), found.digest == digest else { return nil }
            payload = found
        case .delete:
            guard try !CloudTransportRows.deletionAwaitingSuccessor(db, key) else { return nil }
            payload = nil
        }
        let systemFields = try payload == nil ? nil : CloudTransportRows.systemFields(db, key)
        return .init(attempt: attempt, material: payload, systemFields: systemFields)
    }

    private static func validate(_ family: Family, name: String, id: String, book: String, mark: String?) throws {
        guard (try? parseSha256(value: book)) == book, key(family, id: id).name == name,
              !id.isEmpty, DataIdentity.canonical(id) == id else { throw UserSyncCompatibilityError() }
        if family == .annotation {
            guard let mark, !mark.isEmpty, DataIdentity.canonical(mark) == mark else { throw UserSyncCompatibilityError() }
        }
    }

    static func ingest(_ db: Database, _ family: Family, record: CloudInboxRows.Record, id: String, book: String) throws {
        try validate(family, name: record.name, id: id, book: book, mark: record.mark)
        let key = key(family, id: id)
        if try CloudTransportRows.deletionPending(db, key) { return }
        guard let body = record.payload else { throw UserSyncCompatibilityError() }
        try removeIsolation(db, family, name: record.name)
        switch family {
        case .position:
            let head = try UserSyncJSON.storedValue(body, key: "position/" + book)
            let value = try JSONDecoder().decode(PositionValue.self, from: Data(head.value.utf8))
            guard recordID(book: book, token: head.token) == id else { throw UserSyncCompatibilityError() }
            if let hint = value.source_hint {
                guard hint.isValid, try normalizeSourceDecoding(decoding: hint.decoding) == hint.decoding
                else { throw UserSyncCompatibilityError() }
            }
            try ReadingPositionRows.mergeCloudPosition(db, book: book,
                value: .init(value: value, updated: head.updated, token: head.token, device: record.device.map(DataIdentity.canonical)))
        case .annotation:
            let value = try UserSyncJSON.annotation(body, id: id)
            guard let mark = record.mark, !value.ancestors.contains(id),
                  value.ancestors.allSatisfy({ !$0.isEmpty && DataIdentity.canonical($0) == $0 }),
                  value.relatedMarks.allSatisfy({ !$0.isEmpty && DataIdentity.canonical($0) == $0 })
            else { throw UserSyncCompatibilityError() }
            if let content = value.content {
                guard content.start <= content.end, value.bookmark ? content.start == content.end : content.start < content.end
                else { throw UserSyncCompatibilityError() }
            }
            try AnnotationRows.mergeCloudCandidate(db, book: book, mark: mark, value: value)
        }
        try CloudTransportRows.recordPresent(db, key, businessID: id, systemFields: record.systemFields)
    }

    private static func recordID(book: String, token: String) -> String {
        ReadingPositionRows.recordID(book: book, token: token)
    }

    static func delete(_ db: Database, _ family: Family, name: String) throws {
        let key = CloudTransportRows.Key(zone: ReadingHistoryTransport.zone, type: family.rawValue, name: name)
        let id = try CloudTransportRows.businessID(db, key)
        let trusted = id.flatMap { self.key(family, id: $0).name == name ? $0 : nil }
        let row = try trusted.flatMap { id in
            try Row.fetchOne(db, sql: "SELECT * FROM usr.\(family.table) WHERE partition=0 AND record_id=?", arguments: [id])
        }
        let quarantined = try Row.fetchAll(db, sql: """
            SELECT DISTINCT book_key,mark_id FROM usr.quarantined_record
             WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=? AND book_key IS NOT NULL
            """, arguments: [family.rawValue,name])
        if let trusted {
            try db.execute(sql: "DELETE FROM usr.\(family.table) WHERE partition=0 AND record_id=?", arguments: [trusted])
        }
        try removeIsolation(db, family, name: name)
        try CloudTransportRows.applyPeerDeletion(db, key)
        let routes = quarantined + (row.map { [$0] } ?? [])
        var seen = Set<[String]>()
        for evidence in routes {
            let book: String = evidence["book_key"]
            let mark: String? = family == .annotation ? evidence["mark_id"] : nil
            if seen.insert([book,mark ?? ""]).inserted { try settle(db, family, book: book, mark: mark) }
        }
    }

    static func settle(_ db: Database, _ family: Family, book: String, mark: String?) throws {
        switch family {
        case .position: try ReadingPositionRows.settleCurrent(db, book: book)
        case .annotation:
            if let mark { try AnnotationRows.settleHeads(db, key: book, markID: mark, partition: 0) }
            else {
                let marks = try String.fetchAll(db, sql: """
                    SELECT mark_id FROM usr.annotation_candidate WHERE partition=0 AND book_key=?
                    UNION SELECT mark_id FROM usr.annotation_current_head WHERE partition=0 AND book_key=?
                    """, arguments: [book,book])
                for mark in marks { try AnnotationRows.settleHeads(db, key: book, markID: mark, partition: 0) }
            }
        }
    }

    private static func removeIsolation(_ db: Database, _ family: Family, name: String) throws {
        try db.execute(sql: "DELETE FROM usr.quarantined_record WHERE partition=0 AND source='cloud' AND source_type=? AND source_id=?",
                       arguments: [family.rawValue,name])
    }

    static func queueBookDeletion(_ db: Database, book: String) throws {
        for family in Family.allCases {
            let ids = try String.fetchAll(db, sql: """
                SELECT record_id FROM usr.\(family.table) WHERE partition=0 AND book_key=?1
                UNION SELECT business_id FROM usr.cloud_record_state WHERE book_key=?1 AND zone=?2 AND record_type=?3
                UNION SELECT s.business_id FROM usr.cloud_record_state s JOIN usr.quarantined_record q
                  ON q.source_id=s.record_name AND q.record_id=s.business_id AND q.source_type=s.record_type
                WHERE q.partition=0 AND q.source='cloud' AND q.book_key=?1 AND s.zone=?2 AND s.record_type=?3
                """, arguments: [book,ReadingHistoryTransport.zone,family.rawValue])
            for id in ids { try CloudTransportRows.enqueueBookDelete(db, key(family, id: id), businessID: id) }
        }
    }

    static func rebuild(_ db: Database) throws {
        for family in Family.allCases {
            let ids = try String.fetchAll(db, sql: "SELECT record_id FROM usr.\(family.table) WHERE partition=0 AND schema_version=1")
            for id in ids {
                guard let value = try material(db, family, id: id) else { continue }
                try CloudTransportRows.enqueueSave(db, key(family, id: id), businessID: id, digest: value.digest)
            }
        }
    }
}
