import GRDB
import MoonreadCoreBindings

public enum FormalMetadataRead {
    private static let formalMetadataBarrierSQL: String = {
        let scopedTables = ["metadata_text_candidate", "tag_candidate", "cover_candidate"]
        let typed = scopedTables.map { "SELECT book_key FROM usr.\($0) WHERE partition=0 AND schema_version<>1 AND book_key IN wanted" }
        let raw = """
            SELECT wanted.value FROM wanted JOIN usr.quarantined_record q
              ON (q.book_key=wanted.value OR q.book_key IS NULL)
              AND (substr(q.logical_key,1,length(wanted.value)+10)='metadata/'||wanted.value||'/'
                  OR (q.logical_key IS NULL AND q.book_key=wanted.value AND
                    q.source_type IN ('metadata_text_candidate','tag_candidate','cover_candidate')))
            WHERE q.partition=0
            """
        return ([raw] + typed).joined(separator: " UNION ")
    }()

    public static func formalMetadataBarriers(_ db: Database, keys: String) throws -> Set<String> {
        try Set(String.fetchAll(db, sql: """
            WITH wanted AS (SELECT value FROM json_each(?))
            \(formalMetadataBarrierSQL)
            """, arguments: [keys]))
    }

    public static func hasFormalMetadataBarrier(_ db: Database, keysSQL: String, arguments: StatementArguments) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            WITH wanted(value) AS (\(keysSQL))
            SELECT EXISTS(\(formalMetadataBarrierSQL))
            """, arguments: arguments) == true
    }

    public static func hasFormalMetadataBarrier(_ db: Database, key: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            WITH wanted(value) AS (SELECT ?)
            SELECT EXISTS(\(formalMetadataBarrierSQL))
            """, arguments: [key]) == true
    }
}

public enum BookStatusRead {
    public static func resolve(stored: String?, hasPosition: Bool) -> BookReadingStatus {
        switch stored {
        case nil, "Unread": hasPosition ? .reading : .unread
        case "Reading": .reading
        case "Finished": .finished
        case "Paused": .paused
        case .some(let value): .other(value: value)
        }
    }
}
