import Foundation
import GRDB

/// Position and opened are independent facts. Device view state commits with
/// the corresponding fact, on one usr transaction.
enum ReadingPositionRows {
    struct Position: Sendable {
        let value: PositionValue
        let updated: Int64
        let token: String
        let device: String?
    }

    static func partition(for key: String) throws -> Int {
        if case .pending = try parseReadingKey(value: key) { return 1 }
        return 0
    }

    private enum Domain: String {
        case position, opened
        var candidateType: String {
            switch self {
            case .position: "position_candidate"
            case .opened: "opened_candidate"
            }
        }
    }

    private static func requireReadable(_ db: Database, domain: Domain, book: String, partition: Int) throws {
        let logicalKey = DataIdentity.canonical("\(domain.rawValue)/\(book)")
        // Relational quarantine may only carry a domain table and a book
        // (position_candidate has no logical_key column).
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.quarantined_record
                WHERE partition=? AND (logical_key=? OR (source_type=? AND book_key=?)))
            """, arguments: [partition,logicalKey,domain.candidateType,DataIdentity.canonical(book)]) == true else {
            throw UserSyncCompatibilityError()
        }
        // candidateType is a fixed domain table, never a caller-supplied name.
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.\(domain.candidateType)
                WHERE partition=? AND book_key=? AND schema_version<>1)
            """, arguments: [partition,DataIdentity.canonical(book)]) == true else {
            throw UserSyncCompatibilityError(reason: .newerFormat)
        }
    }

    private static let positionColumns = """
        original_book_key,offset,updated_ms,token,device_id,source_kind,relative_path,file_name,byte_size,decoding
        """

    static func position(_ db: Database, book: String, partition: Int) throws -> Position? {
        try requireReadable(db, domain: .position, book: book, partition: partition)
        // Only the latest time can win. Compare equal-time tokens with the
        // published Swift ordering, not a locale or SQL collation.
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(positionColumns)
            FROM usr.position_candidate
            WHERE partition=?1 AND book_key=?2 AND updated_ms=(
                SELECT MAX(updated_ms) FROM usr.position_candidate WHERE partition=?1 AND book_key=?2
            )
            ORDER BY record_id
            """, arguments: [partition,DataIdentity.canonical(book)])
        guard let row = rows.max(by: { ($0["token"] as String) < ($1["token"] as String) }) else { return nil }
        return try decodedPosition(row)
    }

    private static func decodedPosition(_ row: Row) throws -> Position {
        guard let offset = UInt64(row["offset"] as String) else { throw UserSyncCompatibilityError() }
        let token: String = row["token"]
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let source: PositionSourceHint?
        if let kind = row["source_kind"] as String? {
            guard let kind = PositionSourceHint.Kind(rawValue: kind), let path = row["relative_path"] as String?,
                  let filename = row["file_name"] as String?, let decoding = row["decoding"] as String?
            else { throw UserSyncCompatibilityError() }
            let bytes = (row["byte_size"] as Int64?).flatMap { UInt64(exactly: $0) }
            source = .init(source_kind: kind, relative_path: path, file_name: filename, byte_size: bytes, decoding: decoding)
        } else {
            source = nil
        }
        guard source?.isValid ?? true else { throw UserSyncCompatibilityError() }
        return .init(value: .init(content_key: row["original_book_key"], offset: offset, source_hint: source),
                     updated: row["updated_ms"], token: token, device: row["device_id"])
    }

    private static func nextTime(_ now: Int64, after previous: Int64?) throws -> Int64 {
        let previous = previous ?? 0
        guard previous < Int64.max else { throw UserSyncCompatibilityError() }
        return max(now, previous + 1)
    }

    static func recordPosition(_ db: Database, book: String, offset: UInt64, hint: PositionSourceHint?, file: String?,
                               device: String, now: Int64, token: String) throws -> Position {
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let part = try partition(for: book)
        let previous = try position(db, book: book, partition: part)
        let source = hint ?? previous?.value.source_hint
        guard source?.isValid ?? true else { throw UserSyncCompatibilityError() }
        let saved = Position(value: .init(content_key: book, offset: offset, source_hint: source),
                             updated: try nextTime(now, after: previous?.updated), token: token, device: device)
        try replacePosition(db, with: saved, book: book, partition: part)
        try recordLocalOpen(db, book: book, file: file)
        if part == 0 { try LocalReadingRows.setResume(db, book: book, offset: offset, token: token) }
        return saved
    }

    private static func replacePosition(_ db: Database, with position: Position, book: String, partition: Int) throws {
        let id = DataIdentity.id("position", [book,position.token])
        let key = DataIdentity.canonical(book), hint = position.value.source_hint
        let byteSize = hint?.byte_size.flatMap { Int64(exactly: $0) }
        try db.execute(sql: """
            INSERT INTO usr.position_candidate
                (partition,record_id,schema_version,book_key,original_book_key,updated_ms,token,offset,device_id,
                 source_kind,relative_path,file_name,byte_size,decoding)
            VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [partition,id,key,book,position.updated,position.token,DataIdentity.unsigned(position.value.offset),position.device,
                             hint?.source_kind.rawValue,hint?.relative_path,hint?.file_name,byteSize,hint?.decoding])
        try db.execute(sql: "DELETE FROM usr.position_candidate WHERE partition=? AND book_key=? AND record_id<>?",
                       arguments: [partition,key,id])
    }

    static func recordOpened(_ db: Database, book: String, openedAt: Int64, file: String?, device: String, now: Int64, token: String) throws {
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let part = try partition(for: book)
        let key = DataIdentity.canonical(book)
        try requireReadable(db, domain: .opened, book: book, partition: part)
        let latest = try Int64.fetchOne(db, sql: "SELECT MAX(updated_ms) FROM usr.opened_candidate WHERE partition=? AND book_key=?",
                                        arguments: [part,key])
        let updated = try nextTime(now, after: latest)
        try putOpened(db, book: book, partition: part, device: device, openedAt: openedAt, updated: updated, token: token)
        try recordLocalOpen(db, book: book, file: file)
    }

    private static func putOpened(_ db: Database, book: String, partition: Int, device: String,
                                  openedAt: Int64, updated: Int64, token: String) throws {
        let logicalKey = "opened/" + book, key = DataIdentity.canonical(book)
        let id = DataIdentity.id("value", [logicalKey,device])
        try db.execute(sql: """
            INSERT INTO usr.opened_candidate
                (partition,record_id,schema_version,book_key,logical_key,device_id,original_device_id,updated_ms,token,opened_ms)
            VALUES (?,?,1,?,?,?,?,?,?,?)
            ON CONFLICT(partition,book_key,device_id) DO UPDATE SET
                updated_ms=excluded.updated_ms,token=excluded.token,opened_ms=excluded.opened_ms
            """, arguments: [partition,id,key,logicalKey,DataIdentity.canonical(device),device,updated,token,openedAt])
    }

    static func requirePromotionReadable(_ db: Database, book: String, partition: Int) throws {
        try requireReadable(db, domain: .position, book: book, partition: partition)
        try requireReadable(db, domain: .opened, book: book, partition: partition)
    }

    static func promote(_ db: Database, from pending: String, to formal: String) throws {
        try requirePromotionReadable(db, book: pending, partition: 1)
        try requirePromotionReadable(db, book: formal, partition: 0)
        func positions(_ book: String, _ part: Int) throws -> [Position] {
            try Row.fetchAll(db, sql: """
                SELECT \(positionColumns) FROM usr.position_candidate WHERE partition=? AND book_key=? ORDER BY record_id
                """, arguments: [part,DataIdentity.canonical(book)]).map(decodedPosition)
        }
        let source = try positions(pending, 1), target = try positions(formal, 0)
        var sameToken: [String: Position] = [:]
        for value in target + source {
            if let prior = sameToken[value.token] {
                guard prior.updated == value.updated, prior.value.offset == value.value.offset,
                      prior.value.source_hint == value.value.source_hint else { throw UserSyncCompatibilityError() }
            } else { sameToken[value.token] = value }
        }
        func older(_ a: Position, _ b: Position) -> Bool { (a.updated,a.token) < (b.updated,b.token) }
        if let candidate = source.max(by: older), target.max(by: older).map({ older($0,candidate) }) ?? true {
            try replacePosition(db, with: candidate, book: formal, partition: 0)
        }

        struct Opened {
            let device: String
            let updated: Int64
            let token: String
            let time: Int64
        }
        func opened(_ book: String, _ part: Int) throws -> [Opened] {
            try Row.fetchAll(db, sql: """
                SELECT device_id,updated_ms,token,opened_ms FROM usr.opened_candidate
                WHERE partition=? AND book_key=? ORDER BY record_id
                """, arguments: [part,DataIdentity.canonical(book)]).map { row in
                    let token: String = row["token"]
                    guard !token.isEmpty else { throw UserSyncCompatibilityError() }
                    return .init(device: row["device_id"], updated: row["updated_ms"], token: token, time: row["opened_ms"])
                }
        }
        if let winner = try opened(pending, 1).max(by: { ($0.updated,$0.token) < ($1.updated,$1.token) }) {
            let existing = try opened(formal, 0)
            let matching = existing.filter { $0.token == winner.token }
            guard matching.allSatisfy({ $0.updated == winner.updated && $0.time == winner.time })
            else { throw UserSyncCompatibilityError() }
            let slot = "pending-promotion" // The published pending-opened merge slot.
            let previous = existing.first { $0.device == slot }
            if matching.isEmpty, previous.map({ ($0.updated,$0.token) < (winner.updated,winner.token) }) ?? true {
                try putOpened(db, book: formal, partition: 0, device: slot,
                              openedAt: winner.time, updated: winner.updated, token: winner.token)
            }
        }
    }

    private static func recordLocalOpen(_ db: Database, book: String, file: String?) throws {
        if let file { try LocalReadingRows.setPreferredFile(db, book: book, file: file) }
        try LocalReadingRows.setHidden(db, book: book, hidden: false)
    }
}
