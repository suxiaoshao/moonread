import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB

/// Position and opened are independent facts. Device view state commits with
/// the corresponding fact, on one usr transaction.
public enum ReadingPositionRows {
    public struct Position: Sendable {
        public let value: PositionValue
        public let updated: Int64
        public let token: String
        public let device: String?

        public init(value: PositionValue, updated: Int64, token: String, device: String? = nil) {
            self.value = value
            self.updated = updated
            self.token = token
            self.device = device
        }
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
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=? AND logical_key=?)
            """, arguments: [partition,logicalKey]) == true else { throw UserSyncCompatibilityError() }
        // candidateType is a fixed domain table, never a caller-supplied name.
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM usr.\(domain.candidateType)
                WHERE partition=? AND book_key=? AND schema_version<>1)
            """, arguments: [partition,DataIdentity.canonical(book)]) == true else {
            throw UserSyncCompatibilityError(reason: .newerFormat)
        }
    }

    private static let positionColumns = """
        book_key,offset,updated_ms,token,device_id,source_kind,relative_path,file_name,byte_size,decoding
        """

    /// Reconcile exactly one confirmed business key. A blocked domain may
    /// not provide a winner, but cannot erase the other independent domain.
    static func settleCurrent(_ db: Database, book: String) throws {
        let key = DataIdentity.canonical(book)
        func positionReadable(_ partition: Int) throws -> Bool {
            do {
                try requireReadable(db, domain: .position, book: key, partition: partition)
                return true
            } catch is UserSyncCompatibilityError { return false }
        }
        func readableWinner(_ row: Row?) -> Row? {
            guard let row, (try? decodedPosition(row)) != nil else { return nil }
            return row
        }
        let formalReadable = try positionReadable(0)
        let formal = try formalReadable ? latestPositionRow(db, key: key, partition: 0) : nil
        if let winner = readableWinner(formal) {
            try db.execute(sql: """
                INSERT INTO usr.formal_position_current(book_key,position_id) VALUES(?,?)
                ON CONFLICT(book_key) DO UPDATE SET position_id=excluded.position_id
                WHERE position_id IS NOT excluded.position_id
                """, arguments: [key,winner["record_id"] as String])
        } else {
            try db.execute(sql: "DELETE FROM usr.formal_position_current WHERE book_key=?", arguments: [key])
        }

        let position: Row?
        if formalReadable, try positionReadable(1) {
            let pending = try latestPositionRow(db, key: key, partition: 1)
            // Validate only after choosing the shared winner, as before. An
            // undecodable leading row must not promote an older candidate.
            position = readableWinner(CurrentUserRows.winner([formal,pending].compactMap { $0 }))
        } else {
            position = nil
        }
        // Unlike position, an unreadable opened key only suppresses that
        // store's opened value. The other store's value still participates.
        func openedWinner() throws -> Row? {
            var candidates: [Row] = []
            for partition in [0,1] {
                do { try requireReadable(db, domain: .opened, book: key, partition: partition) }
                catch is UserSyncCompatibilityError { continue }
                let rows = try Row.fetchAll(db, sql: """
                    SELECT partition,record_id,updated_ms,token,opened_ms FROM usr.opened_candidate
                    WHERE partition=?1 AND book_key=?2 AND updated_ms=(SELECT max(updated_ms) FROM usr.opened_candidate
                        WHERE partition=?1 AND book_key=?2)
                    ORDER BY record_id
                    """, arguments: [partition,key])
                if let row = CurrentUserRows.winner(rows), !(row["token"] as String).isEmpty { candidates.append(row) }
            }
            return CurrentUserRows.winner(candidates)
        }
        let opened = try openedWinner()
        let updated: Int64? = position?["updated_ms"], openedAt: Int64? = opened?["opened_ms"]
        guard let recent = openedAt ?? updated else {
            try db.execute(sql: "DELETE FROM usr.reading_current WHERE book_key=?", arguments: [key])
            return
        }
        try db.execute(sql: """
            INSERT INTO usr.reading_current VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(book_key) DO UPDATE SET position_partition=excluded.position_partition,position_id=excluded.position_id,
                position_updated_ms=excluded.position_updated_ms,opened_partition=excluded.opened_partition,
                opened_id=excluded.opened_id,opened_ms=excluded.opened_ms,recent_ms=excluded.recent_ms
            WHERE position_partition IS NOT excluded.position_partition OR position_id IS NOT excluded.position_id
                OR position_updated_ms IS NOT excluded.position_updated_ms OR opened_partition IS NOT excluded.opened_partition
                OR opened_id IS NOT excluded.opened_id OR opened_ms IS NOT excluded.opened_ms
            """, arguments: [key,position?["partition"] as Int?,position?["record_id"] as String?,updated,
                             opened?["partition"] as Int?,opened?["record_id"] as String?,openedAt,recent])
    }

    public static func position(_ db: Database, book: String, partition: Int) throws -> Position? {
        try requireReadable(db, domain: .position, book: book, partition: partition)
        return try latestPositionRow(db, key: DataIdentity.canonical(book), partition: partition).map(decodedPosition)
    }

    private static func latestPositionRow(_ db: Database, key: String, partition: Int) throws -> Row? {
        // Only the latest time can win. Compare equal-time tokens with the
        // published Swift ordering, not a locale or SQL collation.
        let rows = try Row.fetchAll(db, sql: """
            SELECT partition,record_id,\(positionColumns)
            FROM usr.position_candidate
            WHERE partition=?1 AND book_key=?2 AND updated_ms=(
                SELECT MAX(updated_ms) FROM usr.position_candidate WHERE partition=?1 AND book_key=?2
            )
            ORDER BY record_id
            """, arguments: [partition,key])
        return CurrentUserRows.winner(rows)
    }

    public struct RestorationPosition: Sendable, Equatable {
        public let contentKey: String
        public let token: String
        public let updated: Int64
        public let hint: PositionSourceHint?
    }

    /// Cache recovery still uses formal, readable positions, ranked by
    /// their position clock (not opened). Hide before taking its fixed budget.
    static func restorationPositions(_ db: Database, scope: DataScope, limit: Int) throws -> [RestorationPosition] {
        try Row.fetchAll(db, sql: """
            WITH aliases AS MATERIALIZED (\(ReadingIdentitySQL.verifiedReadingAliasPairsSQL)),
                 hidden AS (\(ReadingIdentitySQL.hiddenReadingKeysSQL))
            SELECT p.book_key,p.offset,p.updated_ms,p.token,p.device_id,p.source_kind,
                   p.relative_path,p.file_name,p.byte_size,p.decoding
            FROM usr.reading_current r JOIN usr.position_candidate p
                ON p.partition=r.position_partition AND p.record_id=r.position_id
            WHERE r.position_partition=0
              AND length(r.book_key)=64 AND r.book_key NOT GLOB '*[^0-9a-f]*'
              AND NOT EXISTS(SELECT 1 FROM hidden h WHERE h.book_key=r.book_key)
            ORDER BY r.position_updated_ms DESC,r.book_key DESC LIMIT ?2
            """, arguments: [scope.key,max(0,limit)]).map { row in
                let position = try decodedPosition(row)
                return .init(contentKey: position.value.content_key, token: position.token,
                             updated: position.updated, hint: position.value.source_hint)
            }
    }

    static func decodedPosition(_ row: Row) throws -> Position {
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
        guard source?.hasValidShape ?? true else { throw UserSyncCompatibilityError() }
        return .init(value: .init(content_key: row["book_key"], offset: offset, source_hint: source),
                     updated: row["updated_ms"], token: token, device: row["device_id"])
    }

    private static func nextTime(_ now: Int64, after previous: Int64?) throws -> Int64 {
        let previous = previous ?? 0
        guard previous < Int64.max else { throw UserSyncCompatibilityError() }
        return max(now, previous + 1)
    }

    static func recordPosition(_ db: Database, book: String, offset: UInt64, hint: PositionSourceHint?, file: String?,
                               device: String, now: Int64, token: String, scope: DataScope = .local) throws -> Position {
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let part = try partition(for: book)
        let previous = try position(db, book: book, partition: part)
        let source = hint ?? previous?.value.source_hint
        guard source?.hasValidShape ?? true else { throw UserSyncCompatibilityError() }
        let saved = Position(value: .init(content_key: book, offset: offset, source_hint: source),
                             updated: try nextTime(now, after: previous?.updated), token: token, device: device)
        let bases = try previous.map { position in
            try UpgradeOrigins.baseline(db, of: .init(partition: part, domain: .position,
                                                       id: recordID(book: book, token: position.token)))
        } ?? []
        try replacePosition(db, with: saved, book: book, partition: part, queueForSync: part == 0 && scope != .local)
        try recordUpgradePosition(db, saved, book: book, partition: part, bases: bases)
        try recordLocalOpen(db, book: book, file: file)
        if part == 0 { try LocalReadingRows.setResume(db, book: book, offset: offset, token: token) }
        try settleCurrent(db, book: book)
        return saved
    }

    private static func replacePosition(_ db: Database, with position: Position, book: String, partition: Int,
                                        queueForSync: Bool, restoringBackup: Bool = false) throws {
        let predecessors = queueForSync ? try String.fetchAll(db, sql: """
            SELECT record_id FROM usr.position_candidate WHERE partition=0 AND book_key=?
            """, arguments: [book]) : []
        let id = recordID(book: book, token: position.token)
        try insertPosition(db, position, book: book, partition: partition)
        try db.execute(sql: "DELETE FROM usr.position_candidate WHERE partition=? AND book_key=? AND record_id<>?",
                       arguments: [partition,DataIdentity.canonical(book),id])
        if queueForSync {
            try CausalCloudRows.enqueueReplacement(db, .position, id: id, predecessors: predecessors, restoringBackup: restoringBackup)
        }
    }

    public static func recordID(book: String, token: String) -> String { DataIdentity.id("position", [book,token]) }

    private static func insertPosition(_ db: Database, _ position: Position, book: String, partition: Int) throws {
        let id = recordID(book: book, token: position.token)
        let key = DataIdentity.canonical(book), hint = position.value.source_hint
        let byteSize = hint?.byte_size.flatMap { Int64(exactly: $0) }
        try db.execute(sql: """
            INSERT INTO usr.position_candidate
                (partition,record_id,schema_version,book_key,updated_ms,token,offset,device_id,
                 source_kind,relative_path,file_name,byte_size,decoding)
            VALUES (?,?,1,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [partition,id,key,position.updated,position.token,DataIdentity.unsigned(position.value.offset),position.device,
                             hint?.source_kind.rawValue,hint?.relative_path,hint?.file_name,byteSize,hint?.decoding])
    }

    static func requireFormalPositionReadable(_ db: Database, book: String) throws {
        try requireReadable(db, domain: .position, book: book, partition: 0)
    }

    /// Independent received token evidence must survive a different token's
    /// arrival or deletion. A remote callback never writes the device baseline.
    static func mergeCloudPosition(_ db: Database, book: String, value: Position) throws {
        let id = recordID(book: book, token: value.token)
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM usr.position_candidate WHERE partition=0 AND record_id=?", arguments: [id]) {
            guard (row["schema_version"] as Int) == 1 else { throw UserSyncCompatibilityError() }
            let old = try decodedPosition(row)
            guard old.value == value.value, old.updated == value.updated,
                  (old.device == nil || value.device == nil || old.device == value.device) else { throw ReadingDataError.invalid }
        } else {
            try insertPosition(db, value, book: book, partition: 0)
        }
        try settleCurrent(db, book: book)
    }

    static func assessBackup(_ db: Database, book: String, incoming: Position) throws -> BackupDisposition {
        let old = try position(db, book: book, partition: 0)
        let sameToken = try Row.fetchAll(db, sql: """
            SELECT \(positionColumns) FROM usr.position_candidate WHERE partition=0 AND book_key=? AND token=?
            """, arguments: [book,incoming.token])
        for row in sameToken {
            let existing = try decodedPosition(row)
            guard existing.updated == incoming.updated, existing.value.offset == incoming.value.offset,
                  existing.value.source_hint == incoming.value.source_hint else { throw ReadingDataError.invalid }
        }
        if old?.token == incoming.token { return .same }
        if let old, (old.updated,old.token) > (incoming.updated,incoming.token) { return .keepLocal }
        return .restore
    }

    public static func mergeBackup(_ db: Database, book: String, incoming: Position, queueForSync: Bool = false) throws {
        guard try assessBackup(db, book: book, incoming: incoming) == .restore else { return }
        try replacePosition(db, with: incoming, book: book, partition: 0, queueForSync: queueForSync, restoringBackup: true)
        try recordUpgradePosition(db, incoming, book: book, partition: 0, bases: [])
        try settleCurrent(db, book: book)
    }

    private static func recordUpgradePosition(_ db: Database, _ position: Position, book: String, partition: Int,
                                              bases: Set<UpgradeOrigins.Seed>) throws {
        guard try UpgradeOrigins.phase(db) != nil else { return }
        let id = recordID(book: book, token: position.token)
        try UpgradeOrigins.record(db, .init(partition: partition, domain: .position, id: id), as: .local, bases: bases)
        // The dependency points to the durable seed, not to an intermediate
        // local token whose raw data was just compacted.
        try db.execute(sql: """
            DELETE FROM usr.upgrade_local_version WHERE partition=? AND domain=? AND book_key=? AND record_id<>?
            """, arguments: [partition, UpgradeOrigins.Domain.position.rawValue, DataIdentity.canonical(book), id])
    }

    static func recordOpened(_ db: Database, book: String, openedAt: Int64, file: String?, device: String, now: Int64, token: String,
                             scope: DataScope = .local) throws {
        guard !token.isEmpty else { throw UserSyncCompatibilityError() }
        let part = try partition(for: book)
        let key = DataIdentity.canonical(book)
        try requireReadable(db, domain: .opened, book: book, partition: part)
        let latest = try Int64.fetchOne(db, sql: "SELECT MAX(updated_ms) FROM usr.opened_candidate WHERE partition=? AND book_key=?",
                                        arguments: [part,key])
        let updated = try nextTime(now, after: latest)
        let syncID: String? = if part == 0 && scope != .local {
            try String.fetchOne(db, sql: "SELECT record_id FROM usr.opened_candidate WHERE partition=0 AND book_key=? AND device_id=?",
                                arguments: [key,DataIdentity.canonical(device)]) ??
                UserValueRows.recordID(logical: "opened/" + key, device: device)
        } else { nil }
        let prior = try syncID.flatMap { try FixedValueCloudRows.currentDigest(db, .opened, id: $0) }
        let id = try putOpened(db, book: book, partition: part, device: device,
                               openedAt: openedAt, updated: updated, token: token)
        try UpgradeOrigins.record(db, .init(partition: part, domain: .opened, id: id), as: .local)
        if let syncID { try FixedValueCloudRows.enqueueLocalEdit(db, .opened, id: syncID, previousDigest: prior) }
        try recordLocalOpen(db, book: book, file: file)
        try settleCurrent(db, book: book)
    }

    private static func putOpened(_ db: Database, book: String, partition: Int, device: String,
                                  openedAt: Int64, updated: Int64, token: String) throws -> String {
        let logicalKey = "opened/" + book, key = DataIdentity.canonical(book)
        let id = DataIdentity.id("value", [logicalKey,device])
        guard let savedID = try String.fetchOne(db, sql: """
            INSERT INTO usr.opened_candidate
                (partition,record_id,schema_version,book_key,logical_key,device_id,updated_ms,token,opened_ms)
            VALUES (?,?,1,?,?,?,?,?,?)
            ON CONFLICT(partition,book_key,device_id) DO UPDATE SET
                updated_ms=excluded.updated_ms,token=excluded.token,opened_ms=excluded.opened_ms
            RETURNING record_id
            """, arguments: [partition,id,key,logicalKey,DataIdentity.canonical(device),updated,token,openedAt]) else {
            throw DataV2Error.migrationNotVerified
        }
        return savedID
    }

    static func requirePromotionReadable(_ db: Database, book: String, partition: Int) throws {
        try requireReadable(db, domain: .position, book: book, partition: partition)
        try requireReadable(db, domain: .opened, book: book, partition: partition)
    }

    static func requireFormalOpenedReadable(_ db: Database, book: String) throws {
        try requireReadable(db, domain: .opened, book: book, partition: 0)
    }

    static func promote(_ db: Database, from pending: String, to formal: String, scope: DataScope) throws {
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
        if let candidate = source.max(by: older) {
            let present = target.max(by: older)
            let sourceKey = UpgradeOrigins.Key(partition: 1, domain: .position, id: recordID(book: pending, token: candidate.token))
            let targetKey = UpgradeOrigins.Key(partition: 0, domain: .position, id: recordID(book: formal, token: candidate.token))
            if present.map({ older($0,candidate) }) ?? true {
                try replacePosition(db, with: candidate, book: formal, partition: 0, queueForSync: false)
                try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, sourceKey), to: targetKey)
                if scope != .local {
                    try CausalCloudRows.enqueueReplacement(db, .position, id: targetKey.id,
                        predecessors: target.map { recordID(book: formal, token: $0.token) })
                }
            } else if present?.token == candidate.token {
                try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, sourceKey), to: targetKey, equivalent: true)
            }
        }

        struct Opened {
            let id: String
            let device: String
            let updated: Int64
            let token: String
            let time: Int64
        }
        func opened(_ book: String, _ part: Int) throws -> [Opened] {
            try Row.fetchAll(db, sql: """
                SELECT record_id,device_id,updated_ms,token,opened_ms FROM usr.opened_candidate
                WHERE partition=? AND book_key=? ORDER BY record_id
                """, arguments: [part,DataIdentity.canonical(book)]).map { row in
                    let token: String = row["token"]
                    guard !token.isEmpty else { throw UserSyncCompatibilityError() }
                    return .init(id: row["record_id"], device: row["device_id"], updated: row["updated_ms"], token: token, time: row["opened_ms"])
                }
        }
        if let winner = try opened(pending, 1).max(by: { ($0.updated,$0.token) < ($1.updated,$1.token) }) {
            let existing = try opened(formal, 0)
            let matching = existing.filter { $0.token == winner.token }
            guard matching.allSatisfy({ $0.updated == winner.updated && $0.time == winner.time })
            else { throw UserSyncCompatibilityError() }
            let slot = "pending-promotion" // The published pending-opened merge slot.
            let previous = existing.first { $0.device == slot }
            let sourceKey = UpgradeOrigins.Key(partition: 1, domain: .opened, id: winner.id)
            if let same = matching.first {
                try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, sourceKey),
                    to: .init(partition: 0, domain: .opened, id: same.id), equivalent: true)
            } else if previous.map({ ($0.updated,$0.token) < (winner.updated,winner.token) }) ?? true {
                let prior = try previous.flatMap { try FixedValueCloudRows.currentDigest(db, .opened, id: $0.id) }
                let id = try putOpened(db, book: formal, partition: 0, device: slot,
                                       openedAt: winner.time, updated: winner.updated, token: winner.token)
                try UpgradeOrigins.carry(db, UpgradeOrigins.provenance(db, sourceKey),
                    to: .init(partition: 0, domain: .opened, id: id))
                if scope != .local { try FixedValueCloudRows.enqueueLocalEdit(db, .opened, id: id, previousDigest: prior) }
            }
        }
    }

    private static func recordLocalOpen(_ db: Database, book: String, file: String?) throws {
        if let file { try LocalReadingRows.setPreferredFile(db, book: book, file: file) }
        try LocalReadingRows.setHidden(db, book: book, hidden: false)
    }
}

extension ReaderIndex {
    public func writeReadingOpened(bookID: String, openedAt: Int64, file: String?, device: String, now: Int64, token: String) throws {
        try session.writeUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: bookID, scope: lease.scope.key)
            try ReadingPositionRows.recordOpened(db, book: body.sha, openedAt: openedAt, file: file, device: device, now: now, token: token,
                                                scope: lease.scope)
        }
    }

    public func writeReadingPosition(bookID: String, offset: UInt64, hint: PositionSourceHint?, file: String?, device: String,
                              now: Int64, token: String) throws {
        try session.writeUsers(lease) { db in
            let body = try IndexedBookBody.fetch(db, id: bookID, scope: lease.scope.key)
            let offset = min(offset, body.bytes)
            let normalized: UInt64
            if body.bytes == 0 { normalized = 0 }
            else {
                let chunk = try IndexedBookBody.chunk(db, id: body.id, at: offset)
                normalized = try Self.scalarOffset(chunk, at: offset, forward: false)
            }
            _ = try ReadingPositionRows.recordPosition(db, book: body.sha, offset: normalized, hint: hint, file: file,
                                                        device: device, now: now, token: token, scope: lease.scope)
        }
    }

    static func scalarOffset(_ chunk: TextChunk, at offset: UInt64, forward: Bool) throws -> UInt64 {
        guard chunk.startUtf8 <= offset, offset <= chunk.endUtf8 else { throw ReaderError.InvalidRange }
        let bytes = chunk.text.utf8
        var cursor = bytes.index(bytes.startIndex, offsetBy: Int(offset - chunk.startUtf8))
        while cursor != bytes.endIndex && bytes[cursor] & 0xc0 == 0x80 {
            if forward { bytes.formIndex(after: &cursor) } else { bytes.formIndex(before: &cursor) }
        }
        return chunk.startUtf8 + UInt64(bytes.distance(from: bytes.startIndex, to: cursor))
    }


}


extension ReaderIndex {
    public func recentRestorationPositions(limit: Int) throws -> [ReadingPositionRows.RestorationPosition] {
        try session.readUsers(lease) { try ReadingPositionRows.restorationPositions($0, scope: self.lease.scope, limit: limit) }
    }
}
