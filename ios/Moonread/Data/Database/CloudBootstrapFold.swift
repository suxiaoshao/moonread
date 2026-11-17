import Foundation
import GRDB

/// One-time formal-account fold. The caller owns the account writer and the exact
/// covered input. No input from a previous ordinary checkpoint is admissible here.
enum CloudBootstrapFold {
    static let heldSource = "bootstrap-held"
    private typealias Domain = UpgradeOrigins.Domain
    private typealias Key = UpgradeOrigins.Key
    private typealias Version = UpgradeOrigins.Version

    private struct LocalVersion {
        let key: Key
        let row: Row
        let children: [(String, [Row])]
        let evidence: Version
        let source: UpgradeOrigins.Provenance
        var book: String? { evidence.book }
        var mark: String? { evidence.mark }

        var fixed: FixedValueCloudRows.Family? {
            guard row.hasColumn("logical_key"), let logical = row["logical_key"] as String?,
                  let key = try? UserValueRows.Key(logical) else { return nil }
            return .init(key.kind)
        }
        var causal: CausalCloudRows.Family? {
            switch key.domain {
            case .annotation: .annotation
            case .position: .position
            default: nil
            }
        }
        var history: ReadingHistoryTransport.RecordType? {
            switch key.domain {
            case .fact: .fact
            case .segment: .segment
            case .clear: .clear
            default: nil
            }
        }
        var wire: CloudTransportRows.Key? {
            if let fixed { return FixedValueCloudRows.key(fixed, id: key.id) }
            if let causal { return CausalCloudRows.key(causal, id: key.id) }
            if let history { return ReadingHistoryTransport.key(history, id: key.id) }
            return nil
        }

        func captureAsset(_ db: Database, quarantine: Int64) throws {
            // A held edit keeps its original evidence, including any cover it
            // references. Neither the isolated edit nor its bytes may be sent.
            if key.domain == .cover, let asset = row["asset_id"] as String? {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO usr.quarantine_asset(quarantine_id,field,bytes,digest,missing_reason)
                    SELECT ?,'attachment',bytes,CASE WHEN bytes IS NOT NULL THEN expected_sha END,
                           CASE WHEN bytes IS NULL THEN availability END
                    FROM usr.cover_asset WHERE asset_id=?
                    """, arguments: [quarantine,asset])
            }
            if key.domain == .isolation {
                for (_, rows) in children {
                    for attachment in rows {
                        try CloudBootstrapFold.insert(db, table: "quarantine_asset", row: attachment,
                                                      replacing: ["quarantine_id": quarantine.databaseValue])
                    }
                }
            }
        }
    }

    private enum Admission: Int {
        case admit, hold, drop
        func requiring(_ other: Self) -> Self { rawValue >= other.rawValue ? self : other }
    }

    // Partition 1 never enters the cloud fold. v1.6 also wrote some
    // alias clears into its formal store; these remain local until resolved.
    private static func formalScope(_ domain: Domain) -> String {
        let formal = "partition=0"
        guard domain == .clear || domain == .isolation else { return formal }
        return formal + " AND (book_key IS NULL OR substr(book_key,1,8)<>'pending:')"
    }

    static func apply(_ db: Database, scope: DataScope) throws {
        var changed = ReadingHistoryRows.Changed()
        changed.facts = try ReadingFactSettlement.affectedIDs(db)
        changed.segments = try ReadingSegmentRows.affected(db)
        let local = try captureLocal(db)
        let seedBooks = Set(try String.fetchAll(db, sql: "SELECT DISTINCT book_key FROM usr.upgrade_seed WHERE book_key IS NOT NULL"))
        let bookDeletes = try String.fetchAll(db, sql: "SELECT book_key FROM usr.upgrade_book_deletion ORDER BY book_key")
        let deleted = Set(bookDeletes)
        let possibleAssets = try String.fetchAll(db, sql: "SELECT DISTINCT asset_id FROM usr.cover_candidate WHERE partition=0 AND asset_id IS NOT NULL")
        // Local transport state was built against a different baseline. Do not
        // replay its pre-ACK compactions, sends or guessed server change tags.
        try db.execute(sql: """
            DELETE FROM usr.cloud_outbox WHERE zone=:zone;
            DELETE FROM usr.cloud_record_state WHERE zone=:zone;
            """, arguments: ["zone": ReadingHistoryTransport.zone])
        for domain in Domain.allCases {
            try db.execute(sql: "DELETE FROM usr.\(domain.rawValue) WHERE \(formalScope(domain))")
        }
        let records = try Row.fetchCursor(db, sql: "SELECT data FROM usr.cloud_bootstrap_record WHERE data IS NOT NULL ORDER BY record_type,record_name")
        let decoder = PropertyListDecoder()
        while let row = try records.next() {
            try Task.checkCancellation()
            let record = try decoder.decode(CloudInboxRows.Record.self, from: row["data"])
            try CloudInboxRows.stage(db, records: [record], deletions: [], scope: scope, changed: &changed, completeBaseline: true)
        }

        let typedBooks = try confirmedBooks(db)
        let uncertainBooks = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT book_key FROM usr.quarantined_record WHERE partition=0 AND book_key IS NOT NULL
            """))
        let decisions = try local.map {
            try admission(db, $0, seedBooks: seedBooks, present: typedBooks, uncertain: uncertainBooks,
                          deleted: deleted)
        }
        var groups: [String: Admission] = [:]
        for (value, decision) in zip(local, decisions) {
            if case .local(let lineage) = value.source {
                for group in lineage.groups { groups[group] = groups[group, default: .admit].requiring(decision) }
            }
        }
        // A merge can share a surviving op with another merge. Propagate a
        // failed dependency through the entire linked component.
        var updated = true
        while updated {
            try Task.checkCancellation()
            updated = false
            for value in local {
                guard case .local(let lineage) = value.source, lineage.groups.count > 1 else { continue }
                let strictest = lineage.groups.reduce(Admission.admit) { $0.requiring(groups[$1, default: .admit]) }
                for group in lineage.groups where groups[group] != strictest {
                    groups[group] = strictest
                    updated = true
                }
            }
        }

        for book in bookDeletes {
            try ReaderIndex.queueFormalBookDeletion(db, book: book, scope: scope)
            for domain in Domain.allCases where ownsBook(domain) {
                try db.execute(sql: "DELETE FROM usr.\(domain.rawValue) WHERE partition=0 AND book_key=?", arguments: [book])
            }
        }

        var outgoing: [(LocalVersion, String?)] = []
        for (value, proposed) in zip(local, decisions) {
            try Task.checkCancellation()
            var decision = proposed
            if case .local(let lineage) = value.source {
                for group in lineage.groups { decision = decision.requiring(groups[group, default: .admit]) }
            }
            switch decision {
            case .drop: continue
            case .hold: try hold(db, value)
            case .admit:
                if let accepted = try merge(db, value) { outgoing.append((value, accepted.previous)) }
            }
        }
        try CurrentUserRows.settleImported(db)
        changed.facts.formUnion(try ReadingFactSettlement.affectedIDs(db))
        changed.segments.formUnion(try ReadingSegmentRows.affected(db))
        try changed.settle(db, scope: scope)
        try db.execute(sql: """
            DELETE FROM usr.local_resume WHERE substr(book_key,1,8)<>'pending:' AND last_local_write_token IS NOT NULL
              AND NOT EXISTS(SELECT 1 FROM usr.position_candidate p WHERE p.book_key=local_resume.book_key
                AND p.token=local_resume.last_local_write_token AND p.offset=local_resume.offset)
            """)
        for (value, previous) in outgoing {
            if let fixed = value.fixed {
                try FixedValueCloudRows.enqueueLocalEdit(db, fixed, id: value.key.id, previousDigest: previous)
            } else if let causal = value.causal, let material = try CausalCloudRows.material(db, causal, id: value.key.id) {
                // No predecessor is removed just because it had an intent
                // before the fold. The cloud's heads/parallel branches stay.
                try CloudTransportRows.enqueueSave(db, CausalCloudRows.key(causal, id: value.key.id),
                                                   businessID: value.key.id, digest: material.digest)
            } else if let history = value.history, let wire = try ReadingHistoryTransport.currentWire(db, type: history, id: value.key.id) {
                try CloudTransportRows.enqueueSave(db, ReadingHistoryTransport.key(history, id: value.key.id),
                                                   businessID: value.key.id, digest: DataIdentity.sha(Data(wire.utf8)))
            }
        }
        try ReadingHistoryTransport.withdrawBlockedFacts(db, ids: changed.facts)
        if try UserValueRows.canReclaimCoverAssets(db) {
            for asset in possibleAssets { try UserValueRows.removeUnreferencedCover(db, id: asset) }
        }
    }

    private static func captureLocal(_ db: Database) throws -> [LocalVersion] {
        var local: [LocalVersion] = []
        for domain in Domain.allCases {
            let rows = try Row.fetchCursor(db, sql: "SELECT * FROM usr.\(domain.rawValue) WHERE \(formalScope(domain))")
            while let row = try rows.next() {
                try Task.checkCancellation()
                let id = domain == .isolation ? String(row[domain.idColumn] as Int64) : row[domain.idColumn] as String
                let key = Key(partition: 0, domain: domain, id: id)
                let source = try UpgradeOrigins.provenance(db, key)
                if case .seed = source { continue }
                let evidence = try UpgradeOrigins.version(db, key)
                var children: [(String,[Row])] = []
                for relation in domain.relations {
                    children.append((relation.table, try Row.fetchAll(db, sql: """
                        SELECT * FROM usr.\(relation.table) WHERE partition=0 AND \(relation.parent)=? ORDER BY \(relation.order)
                        """, arguments: [id])))
                }
                if domain == .isolation {
                    children.append(("quarantine_asset", try Row.fetchAll(db, sql: """
                        SELECT * FROM usr.quarantine_asset WHERE quarantine_id=?
                        """, arguments: [Int64(id)])))
                }
                local.append(.init(key: key, row: row.copy(), children: children, evidence: evidence, source: source))
            }
        }
        return local
    }

    private static func ownsBook(_ domain: Domain) -> Bool {
        domain != .decoding && domain != .palette && domain != .shelf
    }

    private static func confirmedBooks(_ db: Database) throws -> Set<String> {
        let sql = Domain.allCases.filter { ownsBook($0) && $0 != .isolation }.map {
            "SELECT book_key FROM usr.\($0.rawValue) WHERE partition=0 AND book_key IS NOT NULL"
        }.joined(separator: " UNION ")
        return Set(try String.fetchAll(db, sql: sql))
    }

    private static func current(_ db: Database, key: Key) throws -> Row? {
        try Row.fetchOne(db, sql: "SELECT * FROM usr.\(key.domain.rawValue) WHERE partition=? AND \(key.domain.idColumn)=?",
                         arguments: [key.partition,key.id])
    }

    private static func admission(_ db: Database, _ version: LocalVersion, seedBooks: Set<String>, present: Set<String>,
                                  uncertain: Set<String>, deleted: Set<String>) throws -> Admission {
        // Rowid is never an isolation identity; the cloud can reuse it.
        let peer = version.key.domain == .isolation ? nil : try current(db, key: version.key)
        let peerVersion = peer == nil ? nil : try UpgradeOrigins.version(db, version.key)
        switch version.source {
        case .seed: return .drop
        case .unknown: return .hold
        case .local(let lineage):
            if let book = version.book, !present.contains(book), seedBooks.contains(book) {
                if uncertain.contains(book) { return .hold }
                return .drop
            }
            if let book = version.book, uncertain.contains(book), !present.contains(book) { return .hold }
            guard let wire = version.wire else { return .hold }
            if try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.cloud_bootstrap_record WHERE record_type=? AND record_name=? AND data IS NULL)
                """, arguments: [wire.type,wire.name]) == true { return .drop }
            if try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0
                    AND (source_type=? AND source_id=? OR (source_type=? AND record_id=?)))
                """, arguments: [wire.type,wire.name,version.key.domain.rawValue,version.key.id]) == true { return .hold }
            if let peerVersion, peerVersion.digest != version.evidence.digest {
                // Fixed slots use their existing LWW comparison. An equal
                // stamp with unequal bytes has no order; keep local evidence.
                if let peer, version.fixed != nil, peerVersion.book == version.book,
                   (peer["logical_key"] as String) == (version.row["logical_key"] as String),
                   (peer["device_id"] as String) == (version.row["device_id"] as String) {
                    let lhs = (version.row["updated_ms"] as Int64, version.row["token"] as String)
                    let rhs = (peer["updated_ms"] as Int64, peer["token"] as String)
                    if lhs == rhs { return .hold }
                } else { return .hold }
            }
            if let book = version.book, deleted.contains(book), peer != nil, version.fixed == nil { return .hold }
            if version.key.domain == .annotation {
                guard let book = version.book, let mark = version.mark else { return .hold }
                return try annotationAdmission(db, book: book, mark: mark, bases: lineage.bases)
            }
            return .admit
        }
    }

    private static func annotationAdmission(_ db: Database, book: String, mark: String,
                                            bases: Set<UpgradeOrigins.Seed>) throws -> Admission {
        let view = try AnnotationRows.snapshot(db, key: book, markID: mark, partition: 0)
        if view.unknownMarks || view.blocked.contains(mark) { return .hold }
        let anchors = bases.filter { $0.key.domain == .annotation }
        guard !anchors.isEmpty else { return .admit }
        var result = Admission.admit
        for seed in anchors {
            guard let origin = try UpgradeOrigins.seedVersion(db, seed), let anchorMark = origin.mark, let anchorBook = origin.book
            else { result = result.requiring(.hold); continue }
            if anchorBook != book {
                let promoted = try String.fetchOne(db, sql: "SELECT formal_key FROM usr.upgrade_pending_book WHERE pending_key=?",
                                                   arguments: [anchorBook])
                guard promoted == book else { result = result.requiring(.hold); continue }
            }
            // For a multi-mark operation, validate every dependency against
            // its own original mark. Do not rewrite the operation's ancestry.
            let anchorView = anchorMark == mark ? view : try AnnotationRows.snapshot(db, key: book, markID: anchorMark, partition: 0)
            if anchorView.unknownMarks || anchorView.blocked.contains(anchorMark) {
                result = result.requiring(.hold); continue
            }
            let key = Key(partition: 0, domain: .annotation, id: seed.key.id)
            let exact = try current(db, key: key).map { _ in try UpgradeOrigins.version(db, key) }
            if let exact, exact.mark != anchorMark || exact.book != book || exact.digest != origin.digest {
                result = result.requiring(.hold); continue
            }
            let live = (anchorView.groups[anchorMark] ?? []).filter { $0.content != nil && $0.mergedInto == nil }
            if !live.contains(where: { $0.ancestors.contains(seed.key.id) || (exact != nil && $0.id == seed.key.id) }) {
                result = result.requiring(.drop)
            }
        }
        return result
    }

    private struct Accepted { let previous: String? }

    private static func merge(_ db: Database, _ value: LocalVersion) throws -> Accepted? {
        let peer = try current(db, key: value.key)
        var previous: String?
        if let peer {
            if try UpgradeOrigins.version(db, value.key).digest == value.evidence.digest { return nil }
            guard let fixed = value.fixed else { throw DataV2Error.migrationNotVerified }
            let local = (value.row["updated_ms"] as Int64, value.row["token"] as String)
            let server = (peer["updated_ms"] as Int64, peer["token"] as String)
            guard local > server else { return nil }
            previous = try FixedValueCloudRows.currentDigest(db, fixed, id: value.key.id)
            try db.execute(sql: "DELETE FROM usr.\(value.key.domain.rawValue) WHERE partition=0 AND record_id=?",
                           arguments: [value.key.id])
        }
        try insert(db, table: value.key.domain.rawValue, row: value.row)
        for (table, rows) in value.children {
            for row in rows { try insert(db, table: table, row: row) }
        }
        return Accepted(previous: previous)
    }

    private static func insert(_ db: Database, table: String, row: Row,
                               replacing: [String: DatabaseValue] = [:]) throws {
        let fields = Array(row)
        try db.execute(sql: "INSERT INTO usr.\(table)(\(fields.map(\.0).joined(separator: ","))) VALUES(\(Array(repeating: "?", count: fields.count).joined(separator: ",")))",
                       arguments: StatementArguments(fields.map { replacing[$0.0] ?? $0.1 }))
    }

    private static func hold(_ db: Database, _ version: LocalVersion) throws {
        if version.key.domain == .isolation, (version.row["source"] as String) == heldSource {
            // Carry a previous local-only archive through another replacement
            // without layering a new archive around it or keeping its rowid.
            try insert(db, table: Domain.isolation.rawValue, row: version.row,
                       replacing: ["quarantine_id": .null, "cloud_isolation_name": .null])
            try version.captureAsset(db, quarantine: db.lastInsertedRowID)
            return
        }
        func fields(_ row: Row) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: row.map { name, value -> (String, Any) in
                switch value.storage {
                case .null: (name, NSNull())
                case .int64(let value): (name, ["int64": String(value)])
                case .double(let value): (name, ["float64": String(value.bitPattern)])
                case .string(let value): (name, value)
                case .blob(let value): (name, ["base64": value.base64EncodedString()])
                }
            })
        }
        var object: [String: Any] = ["row": fields(version.row)]
        for (table, rows) in version.children where table != "quarantine_asset" { object[table] = rows.map(fields) }
        if case .local(let lineage) = version.source {
            object["groups"] = lineage.groups.sorted()
            object["bases"] = lineage.bases.map { [$0.batch, String($0.key.partition), $0.key.domain.rawValue, $0.key.id] }
                .sorted { $0.lexicographicallyPrecedes($1) }
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try db.execute(sql: """
            INSERT OR IGNORE INTO usr.quarantined_record(partition,source,source_id,source_type,record_id,book_key,mark_id,
                raw_format,raw_bytes,digest,reason,completeness)
            VALUES(0,?, ?, ?, ?, ?, ?,'local-rows-v1',?,?,'bootstrap-unproven','complete')
            """, arguments: [heldSource,version.evidence.digest,"bootstrap-" + version.key.domain.rawValue,version.key.id,
                             version.book,version.mark,data,DataIdentity.sha(data)])
        if db.changesCount > 0 { try version.captureAsset(db, quarantine: db.lastInsertedRowID) }
    }
}
