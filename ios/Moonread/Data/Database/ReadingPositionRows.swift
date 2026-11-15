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
    }

    static func position(_ db: Database, book: String, partition: Int) throws -> Position? {
        try requireReadable(db, domain: .position, book: book, partition: partition)
        let key = DataIdentity.canonical(book)
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.position_candidate WHERE partition=? AND book_key=? AND schema_version<>1)
            """, arguments: [partition,key]) == true else { throw UserSyncCompatibilityError(reason: .newerFormat) }
        // Only the latest time can win. Compare equal-time tokens with the
        // published Swift ordering, not a locale or SQL collation.
        let rows = try Row.fetchAll(db, sql: """
            SELECT original_book_key,offset,updated_ms,token,device_id,source_kind,relative_path,file_name,byte_size,decoding
            FROM usr.position_candidate
            WHERE partition=?1 AND book_key=?2 AND updated_ms=(
                SELECT MAX(updated_ms) FROM usr.position_candidate WHERE partition=?1 AND book_key=?2
            )
            ORDER BY record_id
            """, arguments: [partition,key])
        guard let row = rows.max(by: { ($0["token"] as String) < ($1["token"] as String) }) else { return nil }
        guard let offset = UInt64(row["offset"] as String) else { throw UserSyncCompatibilityError() }
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
        return .init(value: .init(content_key: row["original_book_key"], offset: offset, source_hint: source),
                     updated: row["updated_ms"], token: row["token"], device: row["device_id"])
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
        let updated = try nextTime(now, after: previous?.updated)
        let id = DataIdentity.id("position", [book,token])
        let key = DataIdentity.canonical(book)
        let byteSize = source?.byte_size.flatMap { Int64(exactly: $0) }
        try db.execute(sql: """
            INSERT INTO usr.position_candidate
                (partition,record_id,schema_version,book_key,original_book_key,updated_ms,token,offset,device_id,
                 source_kind,relative_path,file_name,byte_size,decoding)
            VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [part,id,key,book,updated,token,DataIdentity.unsigned(offset),device,
                             source?.source_kind.rawValue,source?.relative_path,source?.file_name,byteSize,source?.decoding])
        try db.execute(sql: "DELETE FROM usr.position_candidate WHERE partition=? AND book_key=? AND record_id<>?",
                       arguments: [part,key,id])
        try recordLocalOpen(db, book: book, file: file)
        if part == 0 { try LocalReadingRows.setResume(db, book: book, offset: offset, token: token) }
        return .init(value: .init(content_key: book, offset: offset, source_hint: source),
                     updated: updated, token: token, device: device)
    }

    static func recordOpened(_ db: Database, book: String, openedAt: Int64, file: String?, device: String, now: Int64, token: String) throws {
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let part = try partition(for: book)
        let logicalKey = "opened/" + book
        let key = DataIdentity.canonical(book)
        try requireReadable(db, domain: .opened, book: book, partition: part)
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.opened_candidate WHERE partition=? AND book_key=? AND schema_version<>1)
            """, arguments: [part,key]) == true else { throw UserSyncCompatibilityError(reason: .newerFormat) }
        let latest = try Int64.fetchOne(db, sql: "SELECT MAX(updated_ms) FROM usr.opened_candidate WHERE partition=? AND book_key=?",
                                        arguments: [part,key])
        let updated = try nextTime(now, after: latest)
        let id = DataIdentity.id("value", [logicalKey,device])
        try db.execute(sql: """
            INSERT INTO usr.opened_candidate
                (partition,record_id,schema_version,book_key,logical_key,device_id,original_device_id,updated_ms,token,opened_ms)
            VALUES (?,?,1,?,?,?,?,?,?,?)
            ON CONFLICT(partition,book_key,device_id) DO UPDATE SET
                updated_ms=excluded.updated_ms,token=excluded.token,opened_ms=excluded.opened_ms
            """, arguments: [part,id,key,logicalKey,DataIdentity.canonical(device),device,updated,token,openedAt])
        try recordLocalOpen(db, book: book, file: file)
    }

    private static func recordLocalOpen(_ db: Database, book: String, file: String?) throws {
        if let file { try LocalReadingRows.setPreferredFile(db, book: book, file: file) }
        try LocalReadingRows.setHidden(db, book: book, hidden: false)
    }
}
