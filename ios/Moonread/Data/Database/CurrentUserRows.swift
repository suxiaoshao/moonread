import MoonreadDataTypes
import MoonreadCoreBindings
import GRDB

/// Implements the existing Swift token comparison. The domain decides which
/// candidates are eligible, and which domains can choose a winner at all.
enum CurrentUserRows {
    static let bookTables = ["reading_current", "formal_position_current", "metadata_current", "tag_current", "chapter_override_current", "annotation_current_head"]
    static let tables = bookTables + ["source_decoding_current", "palette_current", "shelf_reference_current"]

    /// Initial intake and D1 both merge evidence (including isolation) before
    /// calling this in the target transaction. Never copy another file's refs.
    static func settleImported(_ db: Database) throws {
        func keys(_ column: String, in tables: [String]) throws -> [String] {
            try String.fetchAll(db, sql: tables.map { "SELECT \(column) FROM usr.\($0)" }.joined(separator: " UNION "))
        }
        func formalKeys(_ column: String, in domain: String) throws -> [String] {
            try String.fetchAll(db, sql: """
                SELECT \(column) FROM usr.\(domain)_candidate WHERE partition=0
                UNION SELECT \(column) FROM usr.\(domain)_current
                """)
        }
        for book in try keys("book_key", in: ["position_candidate", "opened_candidate", "reading_current", "formal_position_current"]) {
            try ReadingPositionRows.settleCurrent(db, book: book)
        }
        for book in try keys("book_key", in: ["metadata_text_candidate", "cover_candidate", "tag_candidate", "metadata_current", "tag_current"]) {
            try settleMetadata(db, book: book)
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT book_key,offset FROM usr.chapter_override_candidate
            UNION SELECT book_key,offset FROM usr.chapter_override_current
            """) {
            guard let offset = UInt64(row["offset"] as String) else { throw DataV2Error.migrationNotVerified }
            try settleChapter(db, book: row["book_key"], offset: offset)
        }
        try AnnotationRows.settleImportedHeads(db)
        for rawSHA in try formalKeys("raw_sha256", in: "source_decoding") {
            try settleDecoding(db, rawSHA: rawSHA)
        }
        for id in try formalKeys("palette_id", in: "palette") {
            try settlePalette(db, id: id)
        }
        for id in try formalKeys("shelf_id", in: "shelf_reference") {
            try settleShelfReference(db, id: id)
        }
    }

    static func removeBook(_ db: Database, key: String) throws {
        for table in bookTables {
            try db.execute(sql: "DELETE FROM usr.\(table) WHERE book_key=?", arguments: [DataIdentity.canonical(key)])
        }
    }

    /// SQL comparing current refs across verified aliases uses the same Swift
    /// ordering as the per-book winner, including canonical Unicode equality.
    static let tokenCollation = DatabaseCollation("moonread_value_token") { lhs, rhs in
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    static func winner(_ rows: [Row]) -> Row? {
        rows.max {
            ($0["updated_ms"] as Int64,$0["token"] as String) < ($1["updated_ms"] as Int64,$1["token"] as String)
        }
    }

    private static func valueQuarantine(_ db: Database, book: String, keyPrefix: String) throws -> [Row] {
        try Row.fetchAll(db, sql: """
            SELECT partition,source_type,logical_key FROM usr.quarantined_record
            WHERE book_key=?1 OR (substr(logical_key,1,length(?2))=?2)
            """, arguments: [book,keyPrefix])
    }

    static func settleMetadata(_ db: Database, book: String) throws {
        let key = DataIdentity.canonical(book), prefix = "metadata/" + key + "/"
        let quarantine = try valueQuarantine(db, book: key, keyPrefix: prefix)

        func eligible(table: String, types: Set<String>) throws -> [Row] {
            let rows = try Row.fetchAll(db, sql: """
                SELECT partition,record_id,schema_version,logical_key,updated_ms,token\(table == "metadata_text_candidate" ? ",field" : table == "tag_candidate" ? ",member_key" : "")
                FROM usr.\(table) WHERE book_key=? ORDER BY partition,record_id
                """, arguments: [key])
            let blocked = Dictionary(grouping: rows.filter { ($0["schema_version"] as Int) != 1 }) { $0["partition"] as Int }
                .mapValues { Set($0.map { $0["logical_key"] as String }) }
            return rows.filter { row in
                let part: Int = row["partition"], logical: String = row["logical_key"]
                guard !(blocked[part]?.contains(logical) ?? false) else { return false }
                return !quarantine.contains { unknown in
                    guard (unknown["partition"] as Int) == part else { return false }
                    if let logicalKey = unknown["logical_key"] as String? { return logicalKey == logical }
                    return types.contains(unknown["source_type"] as String)
                }
            }
        }

        let text = try eligible(table: "metadata_text_candidate", types: ["metadata_text_candidate"])
        let covers = try eligible(table: "cover_candidate", types: ["cover_candidate"])
        let tags = try eligible(table: "tag_candidate", types: ["tag_candidate"])
        let readable = Set((text + covers + tags).map { $0["partition"] as Int })
        let chosen = readable.contains(1) ? 1 : readable.contains(0) ? 0 : nil
        let existingTags = try Row.fetchAll(db, sql: "SELECT member_key,source_partition,candidate_id FROM usr.tag_current WHERE book_key=?", arguments: [key])
        guard let part = chosen else {
            if !existingTags.isEmpty { try db.execute(sql: "DELETE FROM usr.tag_current WHERE book_key=?", arguments: [key]) }
            try db.execute(sql: "DELETE FROM usr.metadata_current WHERE book_key=?", arguments: [key])
            return
        }

        func textRef(_ field: String) -> String? {
            winner(text.filter { ($0["partition"] as Int) == part && ($0["field"] as String) == field })?["record_id"]
        }
        let cover: String? = winner(covers.filter { ($0["partition"] as Int) == part })?["record_id"]
        // Presence is based on the readable chosen object. Null fields
        // are defaults of that object; they never fall through to formal.
        try db.execute(sql: """
            INSERT INTO usr.metadata_current VALUES (?,?,?,?,?,?)
            ON CONFLICT(book_key) DO UPDATE SET source_partition=excluded.source_partition,author_id=excluded.author_id,
                synopsis_id=excluded.synopsis_id,status_id=excluded.status_id,cover_id=excluded.cover_id
            WHERE source_partition IS NOT excluded.source_partition OR author_id IS NOT excluded.author_id OR
                synopsis_id IS NOT excluded.synopsis_id OR status_id IS NOT excluded.status_id OR cover_id IS NOT excluded.cover_id
            """, arguments: [key,part,textRef("author"),textRef("synopsis"),textRef("status"),cover])
        let selectedTags = Dictionary(grouping: tags.filter { ($0["partition"] as Int) == part }) { $0["member_key"] as String }
            .compactMapValues { winner($0)?["record_id"] as String? }
        for row in existingTags {
            let member: String = row["member_key"]
            if selectedTags[member] == nil {
                try db.execute(sql: "DELETE FROM usr.tag_current WHERE book_key=? AND member_key=?", arguments: [key,member])
            }
        }
        for (member,id) in selectedTags {
            try db.execute(sql: """
                INSERT INTO usr.tag_current VALUES (?,?,?,?)
                ON CONFLICT(book_key,member_key) DO UPDATE SET source_partition=excluded.source_partition,candidate_id=excluded.candidate_id
                WHERE source_partition IS NOT excluded.source_partition OR candidate_id IS NOT excluded.candidate_id
                """, arguments: [key,member,part,id])
        }
    }

    static func settleChapter(_ db: Database, book: String, offset: UInt64) throws {
        let key = DataIdentity.canonical(book), offsetKey = DataIdentity.unsigned(offset)
        let logical = "chapter/\(key)/\(offset)"
        // The published projection applied formal corrections first and
        // overlaid the corrections emitted by pending. A retracted winner
        // or a blocked key emits no correction from its own partition.
        for partition in [1,0] {
            let blocked = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=?1 AND
                  (logical_key=?2 OR (source_type='chapter_override_candidate' AND book_key=?3 AND logical_key IS NULL))
                UNION ALL SELECT 1 FROM usr.chapter_override_candidate
                  WHERE partition=?1 AND book_key=?3 AND offset=?4 AND schema_version<>1)
                """, arguments: [partition,logical,key,offsetKey]) == true
            guard !blocked else { continue }
            let rows = try Row.fetchAll(db, sql: """
                SELECT record_id,updated_ms,token,is_retracted FROM usr.chapter_override_candidate
                WHERE partition=? AND book_key=? AND offset=? ORDER BY record_id
                """, arguments: [partition,key,offsetKey])
            guard let row = winner(rows), !(row["is_retracted"] as Bool) else { continue }
            try db.execute(sql: """
                INSERT INTO usr.chapter_override_current VALUES (?,?,?,?)
                ON CONFLICT(book_key,offset) DO UPDATE SET source_partition=excluded.source_partition,candidate_id=excluded.candidate_id
                WHERE source_partition IS NOT excluded.source_partition OR candidate_id IS NOT excluded.candidate_id
                """, arguments: [key,offsetKey,partition,row["record_id"] as String])
            return
        }
        try db.execute(sql: "DELETE FROM usr.chapter_override_current WHERE book_key=? AND offset=?", arguments: [key,offsetKey])
    }

    static func settleDecoding(_ db: Database, rawSHA: String) throws {
        _ = try parseSha256(value: rawSHA)
        try settleGlobalValue(db, domain: .decoding, key: rawSHA)
    }
    static func settlePalette(_ db: Database, id: String) throws {
        try settleGlobalValue(db, domain: .palette, key: DataIdentity.canonical(id))
    }
    static func settleShelfReference(_ db: Database, id: String) throws {
        try settleGlobalValue(db, domain: .shelfReference, key: DataIdentity.canonical(id))
    }

    private enum GlobalValue {
        case decoding, palette, shelfReference
        var contract: (name: String, key: String, prefix: String) {
            switch self {
            case .decoding: ("source_decoding","raw_sha256","source-decoding/")
            case .palette: ("palette","palette_id","palette/")
            case .shelfReference: ("shelf_reference","shelf_id","shelf-reference/")
            }
        }
    }

    private static func settleGlobalValue(_ db: Database, domain: GlobalValue, key: String) throws {
        let (name,column,prefix) = domain.contract
        // Global settings have always been read from the formal store.
        let rows: [Row]
        switch domain {
        case .shelfReference:
            // Shelf descriptions are independent hints; skip only the
            // unreadable record, leaving its readable siblings eligible.
            rows = try Row.fetchAll(db, sql: """
                SELECT record_id,updated_ms,token FROM usr.shelf_reference_candidate
                WHERE partition=0 AND shelf_id=? AND schema_version=1 AND reference_version=1
                ORDER BY record_id
                """, arguments: [key])
        case .decoding, .palette:
            let blocked = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM usr.quarantined_record WHERE partition=0 AND logical_key=?1
                    UNION ALL SELECT 1 FROM usr.\(name)_candidate WHERE partition=0 AND \(column)=?2 AND schema_version<>1)
                """, arguments: [prefix + key,key]) == true
            rows = blocked ? [] : try Row.fetchAll(db, sql: """
                SELECT record_id,updated_ms,token FROM usr.\(name)_candidate
                WHERE partition=0 AND \(column)=? ORDER BY record_id
                """, arguments: [key])
        }
        guard let row = winner(rows) else {
            try db.execute(sql: "DELETE FROM usr.\(name)_current WHERE \(column)=?", arguments: [key])
            return
        }
        try db.execute(sql: """
            INSERT INTO usr.\(name)_current VALUES (?,0,?)
            ON CONFLICT(\(column)) DO UPDATE SET source_partition=excluded.source_partition,candidate_id=excluded.candidate_id
            WHERE source_partition IS NOT excluded.source_partition OR candidate_id IS NOT excluded.candidate_id
            """, arguments: [key,row["record_id"] as String])
    }
}
