import GRDB

/// Both point and directory reads join only the already settled correction.
enum ReaderChapterRead {
    typealias Point = MoonreadQueries.ChapterAtQuery.Data
    typealias Structure = MoonreadQueries.ChapterStructureQuery.Data
    typealias Entry = Structure.ChapterStructure.Entry

    enum Bound {
        case atOrBefore, before, after

        var comparison: String {
            switch self {
            case .atOrBefore: "<="
            case .before: "<"
            case .after: ">"
            }
        }
        var order: String { self == .after ? "ASC" : "DESC" }
    }

    /// Expressions are internal SQL references, never bound user input.
    /// Keep the top-1 in each arm: point reads need not load the directory.
    static func headingSQL(body: String, key: String, offset: String, bound: Bound = .atOrBefore) -> String {
        let order = "ORDER BY start \(bound.order) LIMIT 1"
        return """
            SELECT start,title,level FROM (
                SELECT * FROM (
                    \(detected(body: body, key: key,
                        where: "AND ch.start_utf8 \(bound.comparison) \(offset)")) \(order)
                )
                UNION ALL
                SELECT * FROM (
                    \(manual(body: body, key: key,
                        where: "AND ov.offset \(bound.comparison) printf('%020lld',\(offset))")) \(order)
                )
            ) \(order)
            """
    }

    private static func detected(body: String, key: String, where range: String = "") -> String {
        """
            SELECT ch.start_utf8 AS start,coalesce(co.title,ch.title) AS title,coalesce(co.level,ch.level) AS level,
                   ch.start_char_count,ch.body_char_count
            FROM main.import_chapters ch
            LEFT JOIN usr.chapter_override_current ov ON ov.book_key=\(key) AND ov.offset=printf('%020lld',ch.start_utf8)
            LEFT JOIN usr.chapter_override_candidate co ON co.partition=ov.source_partition AND co.record_id=ov.candidate_id
            WHERE ch.book_id=\(body) AND coalesce(co.excluded,0)=0 \(range)
            """
    }

    private static func manual(body: String, key: String, where range: String = "") -> String {
        """
            SELECT CAST(ov.offset AS INTEGER) AS start,co.title,co.level,NULL AS start_char_count,NULL AS body_char_count
            FROM usr.chapter_override_current ov JOIN usr.chapter_override_candidate co
                ON co.partition=ov.source_partition AND co.record_id=ov.candidate_id
            WHERE \(body) IS NOT NULL AND ov.book_key=\(key) AND co.excluded=0 \(range)
              AND NOT EXISTS(SELECT 1 FROM main.import_chapters ch
                  WHERE ch.book_id=\(body) AND ch.start_utf8=CAST(ov.offset AS INTEGER))
            """
    }

    static func fetchPoint(_ db: Database, body: ReaderIndex.Body, offset: UInt64, bound: Bound = .atOrBefore) throws -> Point {
        let row = try Row.fetchOne(db, sql: headingSQL(body: "?1", key: "?2", offset: "?3", bound: bound),
                                   arguments: [body.id, body.sha, Int64(clamping: offset)])
        return try .init(chapterAt: row.map { row in
            let value = try heading(row)
            return .init(start: String(value.startUtf8), title: value.title, level: Int(value.level))
        })
    }

    static func point(_ db: Database, body: ReaderIndex.Body, offset: UInt64, bound: Bound = .atOrBefore) throws -> ChapterInfo? {
        try fetchPoint(db, body: body, offset: offset, bound: bound).chapterAt.map {
            try chapter(start: $0.start, title: $0.title, level: $0.level)
        }
    }

    private static func heading(_ row: Row) throws -> ChapterInfo {
        guard let start = UInt64(exactly: row["start"] as Int64),
              let level = UInt32(exactly: row["level"] as Int64) else { throw ReaderError.InvalidRange }
        return .init(title: row["title"], startUtf8: start, level: level)
    }

    private static func chapter(start: String, title: String, level: Int) throws -> ChapterInfo {
        guard let start = UInt64(start), let level = UInt32(exactly: level) else { throw ReaderError.InvalidRange }
        return .init(title: title, startUtf8: start, level: level)
    }

    static func inRange(_ db: Database, body: ReaderIndex.Body, range: SourceSpan) throws -> [ChapterInfo] {
        try Row.fetchAll(db, sql: """
            \(detected(body: "?1", key: "?2", where: "AND ch.start_utf8>=?3 AND ch.start_utf8<?4"))
            UNION ALL
            \(manual(body: "?1", key: "?2", where: "AND ov.offset>=printf('%020lld',?3) AND ov.offset<printf('%020lld',?4)"))
            ORDER BY start
            """, arguments: [body.id, body.sha, range.startUtf8, range.endUtf8]).map(heading)
    }

    static func fetchStructure(_ db: Database, body: ReaderIndex.Body) throws -> Structure {
        // A completed alias uses its canonical body's index and completeness.
        let complete = try Bool.fetchOne(db, sql: """
            SELECT NOT EXISTS(SELECT 1 FROM main.import_jobs WHERE book_id=? AND phase<>'complete')
            """, arguments: [body.id]) == true
        let total = try UInt64.fetchOne(db, sql: """
            SELECT end_char_count FROM main.chunks WHERE book_id=? ORDER BY chunk_index DESC LIMIT 1
            """, arguments: [body.id]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            \(detected(body: "?1", key: "?2"))
            UNION ALL \(manual(body: "?1", key: "?2"))
            ORDER BY start
            """, arguments: [body.id, body.sha])
        let headings = try rows.map { row -> (ChapterInfo, UInt64, UInt64) in
            let info = try heading(row)
            if let start: UInt64 = row["start_char_count"], let end: UInt64 = row["body_char_count"] {
                // A title/level correction does not change the actual source line.
                return (info, start, end)
            }
            let counts = try ReaderIndex.chapterCorrectionCounts(db, body: body, offset: info.startUtf8)
            return (info, counts.start, counts.body)
        }
        var parent: ChapterInfo?
        let items: [Entry] = try headings.enumerated().map { index, value in
            let (info, _, bodyStart) = value
            let hasNext = index + 1 < headings.count
            let end = hasNext ? headings[index + 1].1 : total
            guard end >= bodyStart else { throw ReaderError.InvalidRange }
            if info.level == 0 { parent = nil }
            let result = Entry(heading: .init(start: String(info.startUtf8), title: info.title, level: Int(info.level)),
                               wordCount: String(end - bodyStart), countComplete: hasNext || complete,
                               parentStart: parent.map { String($0.startUtf8) }, parentTitle: parent?.title)
            if info.level == 0 { parent = info }
            return result
        }
        return .init(chapterStructure: .init(complete: complete, entries: items))
    }

    static func outline(_ result: Structure) throws -> ChapterOutline {
        let value = result.chapterStructure
        return try .init(items: value.entries.map { item in
            let info = try chapter(start: item.heading.start, title: item.heading.title, level: item.heading.level)
            guard let words = UInt64(item.wordCount) else { throw ReaderError.InvalidRange }
            return .init(startUtf8: info.startUtf8, title: info.title, wordCount: words, countComplete: item.countComplete,
                         level: info.level, parentUtf8: item.parentStart.flatMap(UInt64.init), parentTitle: item.parentTitle,
                         coveredCharacters: nil)
        }, isComplete: value.complete)
    }
}

extension ReaderIndex {
    func readerChapter(_ id: String, offset: UInt64, adjacent: Bool? = nil) throws -> ChapterInfo? {
        try session.readUsers(lease) { db in
            let body = try Self.body(db, id: id, scope: self.lease.scope.key)
            let current = try ReaderChapterRead.point(db, body: body, offset: offset)
            guard let adjacent else { return current }
            return try ReaderChapterRead.point(db, body: body, offset: current?.startUtf8 ?? 0,
                                               bound: adjacent ? .after : .before)
        }
    }

    func readerChapterStructure(_ id: String) throws -> ChapterOutline {
        let value = try session.readUsers(lease) { db in
            let body = try Self.body(db, id: id, scope: self.lease.scope.key)
            return try ReaderChapterRead.fetchStructure(db, body: body)
        }
        return try ReaderChapterRead.outline(value)
    }
}
