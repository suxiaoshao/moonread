import CryptoKit
import Foundation
import GRDB

/// Records content provenance only while the one-time upgrade is unresolved.
/// This is neither a business store nor an outbox. Callers tag the winning
/// write inside their existing usr transaction, never a derived current row.
enum UpgradeOrigins {
    enum Phase: String {
        case unresolved, unverifiedTrial
    }

    enum Domain: String, CaseIterable {
        case metadata = "metadata_text_candidate", tag = "tag_candidate", cover = "cover_candidate"
        case position = "position_candidate", opened = "opened_candidate", chapter = "chapter_override_candidate"
        case annotation = "annotation_candidate", fact = "reading_fact", segment = "reading_segment", clear = "statistics_clear"
        case decoding = "source_decoding_candidate", palette = "palette_candidate", shelf = "shelf_reference_candidate"
        case isolation = "quarantined_record"

        var idColumn: String {
            switch self {
            case .fact: "fact_id"
            case .segment: "segment_id"
            case .isolation: "quarantine_id"
            default: "record_id"
            }
        }

        var relations: [(table: String, parent: String, order: String)] {
            switch self {
            case .annotation: [("annotation_ancestor","candidate_id","ancestor_id"),
                               ("annotation_related_mark","candidate_id","related_mark_id")]
            case .clear: [("statistics_clear_id","clear_id","fact_id"), ("statistics_clear_segment","clear_id","segment_id")]
            case .palette: [("palette_color","candidate_id","contrast_kind,color_role")]
            default: []
            }
        }
    }

    struct Key: Hashable {
        let partition: Int
        let domain: Domain
        let id: String

        var arguments: StatementArguments { [partition, domain.rawValue, id] }
    }

    enum Write {
        case seed(batch: String)
        case local
        /// Derived isolation preserves the origin of the evidence it copies.
        case inherited(Key)
    }

    struct Seed: Hashable {
        let batch: String
        let key: Key
    }

    private static let phaseKey = "upgrade-origin-phase"

    static func phase(_ db: Database) throws -> Phase? {
        guard let value = try String.fetchOne(db, sql: """
            SELECT value FROM usr.local_data_state WHERE state_key=?
            """, arguments: [phaseKey]) else { return nil }
        guard let phase = Phase(rawValue: value) else { throw DataV2Error.migrationNotVerified }
        return phase
    }

    static func begin(_ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [phaseKey, Phase.unresolved.rawValue])
    }

    /// Earlier trial versions sometimes already imported and then edited the
    /// same ID. Preserve the current authority, but give it no claim about
    /// what part originated in the released store.
    static func retainUnverifiedTrial(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO usr.local_data_state
            SELECT ?,? WHERE EXISTS(SELECT 1 FROM usr.local_data_state
               WHERE state_key IN ('legacy-user-import','last-completed-local-move'))
            """, arguments: [phaseKey, Phase.unverifiedTrial.rawValue])
    }

    static func record(_ db: Database, _ key: Key, as write: Write, bases: Set<Seed> = []) throws {
        guard try phase(db) != nil else { return }
        let evidence = try version(db, key)
        switch write {
        case .seed(let batch):
            try putSeed(db, key, batch: batch, evidence: evidence)
        case .local:
            try putLocal(db, key, evidence: evidence, bases: bases)
        case .inherited(let prior):
            let original = try version(db, prior)
            let known = try seeds(db, prior, digest: original.digest)
            if try isLocal(db, prior, digest: original.digest) {
                try putLocal(db, key, evidence: evidence, bases: try dependencies(db, prior))
            } else {
                for seed in known { try putSeed(db, key, batch: seed.batch, evidence: evidence) }
            }
        }
    }

    static func baseline(_ db: Database, of key: Key) throws -> Set<Seed> {
        guard try phase(db) != nil else { return [] }
        let current = try version(db, key)
        if try isLocal(db, key, digest: current.digest) { return try dependencies(db, key) }
        return try seeds(db, key, digest: current.digest)
    }

    private static func seeds(_ db: Database, _ key: Key, digest: String) throws -> Set<Seed> {
        let batches = try String.fetchAll(db, sql: """
            SELECT batch_id FROM usr.upgrade_seed
            WHERE partition=? AND domain=? AND record_id=? AND digest=?
            """, arguments: key.arguments + [digest])
        return Set(batches.map { Seed(batch: $0, key: key) })
    }

    private static func isLocal(_ db: Database, _ key: Key, digest: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM usr.upgrade_local_version
                WHERE partition=? AND domain=? AND record_id=? AND digest=?)
            """, arguments: key.arguments + [digest]) == true
    }

    private static func dependencies(_ db: Database, _ key: Key) throws -> Set<Seed> {
        let rows = try Row.fetchAll(db, sql: """
            SELECT seed_batch,seed_partition,seed_domain,seed_record FROM usr.upgrade_local_seed
            WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments)
        return try Set(rows.map { row in
            guard let domain = Domain(rawValue: row["seed_domain"]) else { throw DataV2Error.migrationNotVerified }
            return Seed(batch: row["seed_batch"],
                        key: .init(partition: row["seed_partition"], domain: domain, id: row["seed_record"]))
        })
    }

    private static func putSeed(_ db: Database, _ key: Key, batch: String, evidence: Version) throws {
        try db.execute(sql: """
            INSERT INTO usr.upgrade_seed(batch_id,partition,domain,record_id,digest,book_key,mark_id)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(batch_id,partition,domain,record_id) DO UPDATE SET
                digest=excluded.digest,book_key=excluded.book_key,mark_id=excluded.mark_id
            """, arguments: [batch] + key.arguments + [evidence.digest,evidence.book,evidence.mark])
    }

    private static func putLocal(_ db: Database, _ key: Key, evidence: Version, bases: Set<Seed>) throws {
        try db.execute(sql: """
            INSERT INTO usr.upgrade_local_version(partition,domain,record_id,digest,book_key,mark_id)
            VALUES(?,?,?,?,?,?) ON CONFLICT(partition,domain,record_id) DO UPDATE SET
                digest=excluded.digest,book_key=excluded.book_key,mark_id=excluded.mark_id
            """, arguments: key.arguments + [evidence.digest,evidence.book,evidence.mark])
        try db.execute(sql: """
            DELETE FROM usr.upgrade_local_seed WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments)
        for seed in bases {
            try db.execute(sql: "INSERT INTO usr.upgrade_local_seed VALUES (?,?,?,?,?,?,?)",
                           arguments: key.arguments + [seed.batch] + seed.key.arguments)
        }
    }

    private struct Version {
        let digest: String
        let book: String?
        let mark: String?
    }

    private static func version(_ db: Database, _ key: Key) throws -> Version {
        let domain = key.domain
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM usr.\(domain.rawValue) WHERE partition=? AND \(domain.idColumn)=?
            """, arguments: [key.partition,key.id]) else { throw DataV2Error.migrationNotVerified }
        var digest = Digest()
        digest.add("upgrade-version-v1")
        digest.add(domain.rawValue)
        digest.add(row, ignoring: ["local_unsealed_owner","quarantine_id","completeness"])
        for relation in domain.relations {
            let rows = try Row.fetchCursor(db, sql: """
                SELECT * FROM usr.\(relation.table) WHERE partition=? AND \(relation.parent)=? ORDER BY \(relation.order)
                """, arguments: [key.partition,key.id])
            digest.add(relation.table)
            while let row = try rows.next() { digest.add(row) }
            digest.add("end-relation")
        }
        // Cover identity and SHA are in the candidate. Availability and
        // attachment repair are not a new edit of that candidate.
        let book: String? = row.hasColumn("book_key") ? row["book_key"] : nil
        let mark: String? = row.hasColumn("mark_id") ? row["mark_id"] : nil
        return .init(digest: digest.finalize(), book: book, mark: mark)
    }

    private struct Digest {
        private var state = SHA256()

        mutating func add(_ row: Row, ignoring: Set<String> = []) {
            add("row")
            for (name, value) in row.filter({ !ignoring.contains($0.0) }).sorted(by: { $0.0 < $1.0 }) {
                add(name)
                switch value.storage {
                case .null: add("null")
                case .int64(let value): add("integer"); add(String(value))
                case .double(let value): add("real"); add(String(value.bitPattern))
                case .string(let value): add("text"); add(value)
                case .blob(let value): add("blob"); add(value)
                }
            }
            add("end-row")
        }

        mutating func add(_ string: String) { add(Data(string.utf8)) }

        private mutating func add(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { state.update(bufferPointer: $0) }
            state.update(data: bytes)
        }

        func finalize() -> String {
            let hex = Array("0123456789abcdef".utf8)
            return String(decoding: state.finalize().flatMap { [hex[Int($0 >> 4)], hex[Int($0 & 15)]] }, as: UTF8.self)
        }
    }
}
