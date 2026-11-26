import MoonreadCoreBindings
import CryptoKit
import Foundation
import GRDB

/// Records content provenance only while the one-time upgrade is unresolved.
/// This is neither a business store nor an outbox. Callers tag the winning
/// write inside their existing usr transaction, never a derived current row.
enum UpgradeOrigins {
    enum Phase: String {
        case unresolved
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

    struct Lineage {
        var bases = Set<Seed>()
        var groups = Set<String>()
    }

    enum Provenance {
        case seed(Set<Seed>)
        case local(Lineage)
        case unknown
    }

    enum Store: String {
        case users = "usr"
        case frozenLocal = "move_source"
    }

    private static let phaseKey = "upgrade-origin-phase"

    static func phase(_ db: Database, in store: Store = .users) throws -> Phase? {
        guard let value = try String.fetchOne(db, sql: """
            SELECT value FROM \(store.rawValue).local_data_state WHERE state_key=?
            """, arguments: [phaseKey]) else { return nil }
        guard let phase = Phase(rawValue: value) else { throw DataV2Error.migrationNotVerified }
        return phase
    }

    static func begin(_ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO usr.local_data_state VALUES (?,?)",
                       arguments: [phaseKey, Phase.unresolved.rawValue])
    }

    /// A replacement winner may be another installation. The known formal
    /// state before the loss is its comparison baseline, not new offline
    /// edits to replay into whatever zone first wins. Existing unresolved
    /// upgrades already have provenance and must keep it.
    static func beginZoneBaseline(_ db: Database) throws {
        guard try phase(db) == nil else { return }
        try begin(db)
        let batch = "zone-recovery-" + UUID().uuidString
        for domain in Domain.allCases {
            let ids = try String.fetchCursor(db, sql: """
                SELECT CAST(\(domain.idColumn) AS TEXT) FROM usr.\(domain.rawValue) WHERE partition=0
                """)
            while let id = try ids.next() {
                try record(db, .init(partition: 0, domain: domain, id: id), as: .seed(batch: batch))
            }
        }
    }

    static func finish(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM usr.upgrade_local_version;
            DELETE FROM usr.upgrade_seed;
            DELETE FROM usr.upgrade_book_deletion;
            DELETE FROM usr.upgrade_pending_book;
            DELETE FROM usr.local_data_state WHERE state_key=?;
            """, arguments: [phaseKey])
    }

    static func copyFromFrozenLocal(_ db: Database) throws {
        guard try phase(db, in: .frozenLocal) == .unresolved else { return }
        try begin(db)
        // The seed anchor may no longer have a raw row, but a surviving
        // edit can still depend on it. Copy anchors before any live version.
        guard try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM move_source.upgrade_seed s JOIN usr.upgrade_seed d
              ON (d.batch_id,d.partition,d.domain,d.record_id)=(s.batch_id,s.partition,s.domain,s.record_id)
              WHERE d.digest IS NOT s.digest OR d.book_key IS NOT s.book_key OR d.mark_id IS NOT s.mark_id)
            """) == true else { throw DataV2Error.conflictingLocalData("upgrade seed evidence") }
        try db.execute(sql: """
            INSERT OR IGNORE INTO usr.upgrade_seed SELECT * FROM move_source.upgrade_seed;
            INSERT OR IGNORE INTO usr.upgrade_book_deletion SELECT * FROM move_source.upgrade_book_deletion;
            """)
        let aliases = try Row.fetchCursor(db, sql: "SELECT pending_key,formal_key FROM move_source.upgrade_pending_book")
        while let row = try aliases.next() {
            try notePromotion(db, from: row["pending_key"], to: row["formal_key"])
        }
    }

    static func clearFrozenLocal(_ db: Database) throws {
        guard try phase(db, in: .frozenLocal) != nil else { return }
        try db.execute(sql: """
            DELETE FROM move_source.upgrade_local_version;
            DELETE FROM move_source.upgrade_seed;
            DELETE FROM move_source.upgrade_book_deletion;
            DELETE FROM move_source.upgrade_pending_book;
            UPDATE move_source.local_data_state SET value=? WHERE state_key=?;
            """, arguments: [Phase.unresolved.rawValue,phaseKey])
    }

    static func notePromotion(_ db: Database, from pending: String, to formal: String) throws {
        guard try phase(db) != nil else { return }
        if let previous = try String.fetchOne(db, sql: "SELECT formal_key FROM usr.upgrade_pending_book WHERE pending_key=?",
                                              arguments: [pending]) {
            guard previous == formal else { throw DataV2Error.conflictingLocalData("upgrade alias evidence") }
            return
        }
        try db.execute(sql: "INSERT INTO usr.upgrade_pending_book VALUES (?,?)", arguments: [pending,formal])
    }

    static func sameVersion(_ db: Database, frozen: Key, destination: Key) throws -> Bool {
        try version(db, frozen, in: .frozenLocal).digest == version(db, destination).digest
    }

    /// The INSERT and this call must be consecutive. The SQLite row ID is
    /// used only to find the just-inserted row, never as provenance identity.
    static func recordInsertedIsolation(_ db: Database, partition: Int, as write: Write) throws {
        guard db.changesCount > 0 else { return }
        try record(db, .init(partition: partition, domain: .isolation, id: String(db.lastInsertedRowID)), as: write)
    }

    static func record(_ db: Database, _ key: Key, as write: Write, bases: Set<Seed> = [], groups: Set<String> = []) throws {
        guard try phase(db) != nil else { return }
        let evidence = try version(db, key)
        let destination = evidence.storageKey(for: key)
        switch write {
        case .seed(let batch):
            try putSeed(db, destination, batch: batch, evidence: evidence)
        case .local:
            try putLocal(db, destination, evidence: evidence, lineage: .init(bases: bases, groups: groups))
        case .inherited(let prior):
            let original = try version(db, prior)
            let source = original.storageKey(for: prior)
            if try isLocal(db, source, digest: original.digest) {
                try putLocal(db, destination, evidence: evidence, lineage: try localLineage(db, source))
            } else {
                for seed in try seeds(db, source, digest: original.digest) {
                    try putSeed(db, destination, batch: seed.batch, evidence: evidence)
                }
            }
        }
    }

    static func baseline(_ db: Database, of key: Key) throws -> Set<Seed> {
        switch try provenance(db, key) {
        case .seed(let seeds): return seeds
        case .local(let lineage): return lineage.bases
        case .unknown: return []
        }
    }

    static func provenance(_ db: Database, _ key: Key, in store: Store = .users) throws -> Provenance {
        guard try phase(db, in: store) != nil else { return .unknown }
        let current = try version(db, key, in: store)
        let reference = current.storageKey(for: key)
        if try isLocal(db, reference, digest: current.digest, in: store) {
            return .local(try localLineage(db, reference, in: store))
        }
        let matches = try seeds(db, reference, digest: current.digest, in: store)
        return matches.isEmpty ? .unknown : .seed(matches)
    }

    /// Used on an accepted rewrite or move, with the source's classification
    /// captured before its bytes could be replaced. D1 copies original seed
    /// anchors before transferring rows that depend on them.
    static func carry(_ db: Database, _ origin: Provenance, to key: Key, equivalent: Bool = false) throws {
        guard try phase(db) != nil else { return }
        let evidence = try version(db, key)
        let target = evidence.storageKey(for: key)
        switch origin {
        case .seed(let matches):
            for seed in matches { try putSeed(db, target, batch: seed.batch, evidence: evidence) }
        case .local(var lineage):
            if equivalent, try isLocal(db, target, digest: evidence.digest) {
                let existing = try localLineage(db, target)
                lineage.bases.formUnion(existing.bases); lineage.groups.formUnion(existing.groups)
            }
            try putLocal(db, target, evidence: evidence, lineage: lineage)
        case .unknown:
            break
        }
    }

    /// Ancestor IDs are copied by the domain reducer, including those whose
    /// raw content has since been compacted. Limit evidence to this book.
    static func annotationLineage(_ db: Database, partition: Int, book: String, ancestors: Set<String>) throws -> Lineage {
        guard !ancestors.isEmpty, try phase(db) != nil else { return .init() }
        var result = Lineage()
        for id in ancestors {
            let key = Key(partition: partition, domain: .annotation, id: DataIdentity.canonical(id))
            let seeds = try String.fetchAll(db, sql: """
                SELECT batch_id FROM usr.upgrade_seed
                WHERE partition=? AND domain=? AND record_id=? AND book_key=?
                """, arguments: key.arguments + [book])
            result.bases.formUnion(seeds.map { Seed(batch: $0, key: key) })
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.upgrade_local_version
                  WHERE partition=? AND domain=? AND record_id=? AND book_key=?)
                """, arguments: key.arguments + [book]) == true else { continue }
            let inherited = try localLineage(db, key)
            result.bases.formUnion(inherited.bases); result.groups.formUnion(inherited.groups)
        }
        return result
    }

    /// Range of a confirmed local whole-book delete. It is local-only until
    /// the bootstrap fold can apply it to a complete new-zone baseline.
    static func recordBookDeletion(_ db: Database, formal: [String], erased: Set<String>) throws {
        guard try phase(db) != nil else { return }
        for book in formal {
            try db.execute(sql: "INSERT OR IGNORE INTO usr.upgrade_book_deletion VALUES (?)", arguments: [book])
        }
        // Remove pre-delete local versions. The original import baselines
        // remain; a later explicit edit records a new surviving local version.
        for book in erased {
            try db.execute(sql: "DELETE FROM usr.upgrade_local_version WHERE book_key=?", arguments: [book])
        }
    }

    private static func seeds(_ db: Database, _ key: Key, digest: String, in store: Store = .users) throws -> Set<Seed> {
        let batches = try String.fetchAll(db, sql: """
            SELECT batch_id FROM \(store.rawValue).upgrade_seed
            WHERE partition=? AND domain=? AND record_id=? AND digest=?
            """, arguments: key.arguments + [digest])
        return Set(batches.map { Seed(batch: $0, key: key) })
    }

    private static func isLocal(_ db: Database, _ key: Key, digest: String, in store: Store = .users) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM \(store.rawValue).upgrade_local_version
                WHERE partition=? AND domain=? AND record_id=? AND digest=?)
            """, arguments: key.arguments + [digest]) == true
    }

    private static func localLineage(_ db: Database, _ key: Key, in store: Store = .users) throws -> Lineage {
        let rows = try Row.fetchAll(db, sql: """
            SELECT seed_batch,seed_partition,seed_domain,seed_record FROM \(store.rawValue).upgrade_local_seed
            WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments)
        let bases = try Set(rows.map { row in
            guard let domain = Domain(rawValue: row["seed_domain"]) else { throw DataV2Error.migrationNotVerified }
            return Seed(batch: row["seed_batch"],
                        key: .init(partition: row["seed_partition"], domain: domain, id: row["seed_record"]))
        })
        let groups = try Set(String.fetchAll(db, sql: """
            SELECT group_id FROM \(store.rawValue).upgrade_local_group WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments))
        return .init(bases: bases, groups: groups)
    }

    private static func putSeed(_ db: Database, _ key: Key, batch: String, evidence: Version) throws {
        try db.execute(sql: """
            INSERT INTO usr.upgrade_seed(batch_id,partition,domain,record_id,digest,book_key,mark_id)
            VALUES(?,?,?,?,?,?,?) ON CONFLICT(batch_id,partition,domain,record_id) DO UPDATE SET
                digest=excluded.digest,book_key=excluded.book_key,mark_id=excluded.mark_id
            """, arguments: [batch] + key.arguments + [evidence.digest,evidence.book,evidence.mark])
    }

    private static func putLocal(_ db: Database, _ key: Key, evidence: Version, lineage: Lineage) throws {
        try db.execute(sql: """
            INSERT INTO usr.upgrade_local_version(partition,domain,record_id,digest,book_key,mark_id)
            VALUES(?,?,?,?,?,?) ON CONFLICT(partition,domain,record_id) DO UPDATE SET
                digest=excluded.digest,book_key=excluded.book_key,mark_id=excluded.mark_id
            """, arguments: key.arguments + [evidence.digest,evidence.book,evidence.mark])
        try db.execute(sql: """
            DELETE FROM usr.upgrade_local_seed WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments)
        for seed in lineage.bases {
            try db.execute(sql: "INSERT INTO usr.upgrade_local_seed VALUES (?,?,?,?,?,?,?)",
                           arguments: key.arguments + [seed.batch] + seed.key.arguments)
        }
        try db.execute(sql: """
            DELETE FROM usr.upgrade_local_group WHERE partition=? AND domain=? AND record_id=?
            """, arguments: key.arguments)
        for group in lineage.groups {
            try db.execute(sql: "INSERT INTO usr.upgrade_local_group VALUES (?,?,?,?)", arguments: key.arguments + [group])
        }
    }

    struct Version {
        let digest: String
        let book: String?
        let mark: String?

        func storageKey(for key: Key) -> Key {
            key.domain == .isolation ? .init(partition: key.partition, domain: .isolation, id: digest) : key
        }
    }

    static func version(_ db: Database, _ key: Key, in store: Store = .users) throws -> Version {
        let domain = key.domain
        guard let row = try Row.fetchOne(db, sql: """
            SELECT * FROM \(store.rawValue).\(domain.rawValue) WHERE partition=? AND \(domain.idColumn)=?
            """, arguments: [key.partition,key.id]) else { throw DataV2Error.migrationNotVerified }
        var digest = Digest()
        digest.add("upgrade-version-v1")
        digest.add(domain.rawValue)
        digest.add(row, ignoring: ["local_unsealed_owner","quarantine_id","completeness"])
        for relation in domain.relations {
            let rows = try Row.fetchCursor(db, sql: """
                SELECT * FROM \(store.rawValue).\(relation.table) WHERE partition=? AND \(relation.parent)=? ORDER BY \(relation.order)
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

    static func seedVersion(_ db: Database, _ seed: Seed) throws -> Version? {
        try Row.fetchOne(db, sql: """
            SELECT digest,book_key,mark_id FROM usr.upgrade_seed
            WHERE batch_id=? AND partition=? AND domain=? AND record_id=?
            """, arguments: [seed.batch] + seed.key.arguments)
            .map { .init(digest: $0["digest"], book: $0["book_key"], mark: $0["mark_id"]) }
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
