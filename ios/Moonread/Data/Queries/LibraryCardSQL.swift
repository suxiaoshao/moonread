import MoonreadCoreBindings

/// Fixed card reads share current position, alias, chapter and metadata
/// rules. Callers supply only their file scope and whether card fields are
/// needed. Bind parameters and predicate fragments are internal SQL constants.
enum LibraryCardSQL {
    /// Use verified identities and body links to narrow before resolving the
    /// record; the caller rechecks the effective SHA after resolving.
    static let recordFileIDs = """
        SELECT file_id AS id FROM main.valid_indexed_identities WHERE content_sha256=?1
        UNION SELECT f.id FROM main.books b JOIN main.library_files f ON f.book_id=b.id
          WHERE b.content_sha256=?1 AND f.directory=0
        UNION SELECT f.id FROM main.books b JOIN main.import_jobs j ON j.canonical_id=b.id
          JOIN main.library_files f ON f.book_id=j.book_id
          WHERE b.content_sha256=?1 AND f.directory=0
        """

    static func preferredOrder(_ candidate: String, file: String) -> String {
        "coalesce(\(candidate)=\(file),0) DESC,\(file)"
    }

    static func fileIdentities(scopeParameter: String, includeNames: Bool) -> String {
        """
        files AS MATERIALIZED (
            SELECT f.id\(includeNames ? ",f.name,f.modified" : ""),
                   coalesce(i.content_sha256,b.content_sha256) AS book_key,
                   CASE WHEN i.content_sha256 IS NULL OR i.content_sha256=b.content_sha256 THEN b.id END AS body_id
            FROM display_books d JOIN main.library_files f ON f.id=d.id
            LEFT JOIN main.valid_indexed_identities i ON i.file_id=f.id
            LEFT JOIN main.import_jobs j ON j.book_id=f.book_id
            LEFT JOIN main.books b ON b.id=coalesce(j.canonical_id,f.book_id)
                AND (b.content_sha256 NOT LIKE 'pending:%' OR j.pending_owner=\(scopeParameter))
        ), identity_keys AS MATERIALIZED (
            SELECT DISTINCT book_key FROM files WHERE book_key IS NOT NULL
        )
        """
    }

    static func currentFiles(scopeParameter: String, includeCardPosition: Bool) -> String {
        fileIdentities(scopeParameter: scopeParameter, includeNames: includeCardPosition)
            + ", " + currentPositions(scopeParameter: scopeParameter, includeCardPosition: includeCardPosition)
    }

    /// The caller declares identity_keys(book_key) for the fixed scope.
    static func currentPositions(scopeParameter: String, includeCardPosition: Bool) -> String {
        """
        aliases AS MATERIALIZED (
            \(ReaderIndex.verifiedReadingAliasPairs(scopeParameter: scopeParameter))
            AND b.content_sha256 IN (SELECT book_key FROM identity_keys)
        ), position_sources(book_key,raw_key) AS MATERIALIZED (
            SELECT book_key,book_key FROM identity_keys
            UNION ALL SELECT book_key,alias FROM aliases
        ), blocked_sources AS (
            SELECT substr(logical_key,10) AS k FROM usr.quarantined_record
                WHERE logical_key IN (SELECT 'position/'||raw_key FROM position_sources)
            UNION SELECT book_key FROM usr.quarantined_record
                WHERE source_type='position_candidate' AND book_key IN (SELECT raw_key FROM position_sources)
            UNION SELECT book_key FROM usr.position_candidate
                WHERE schema_version<>1 AND book_key IN (SELECT raw_key FROM position_sources)
        ), blocked AS MATERIALIZED (
            SELECT DISTINCT s.book_key FROM position_sources s JOIN blocked_sources b ON b.k=s.raw_key
        ), ranks AS (
            SELECT s.book_key,r.position_updated_ms\(includeCardPosition ? ",s.raw_key,p.offset" : ""),
                row_number() OVER (PARTITION BY s.book_key
                    ORDER BY r.position_updated_ms DESC,p.token COLLATE moonread_value_token DESC,r.position_partition,s.raw_key) AS ord
            FROM position_sources s JOIN usr.reading_current r ON r.book_key=s.raw_key
            JOIN usr.position_candidate p ON p.partition=r.position_partition AND p.record_id=r.position_id
            WHERE NOT EXISTS(SELECT 1 FROM blocked b WHERE b.book_key=s.book_key)
        ), positions AS MATERIALIZED (
            SELECT book_key,position_updated_ms\(includeCardPosition ? ",raw_key,offset" : "") FROM ranks WHERE ord=1
        )
        """
    }

    static let columns = """
        p.offset AS position,coalesce(l.bytes,body.byte_count,0) AS byte_count,
               coalesce(coalesce(pref.file_id,source_pref.file_id)=c.id,0) AS preferred,
               CASE WHEN p.offset IS NOT NULL THEN
                   (SELECT title FROM (\(ReaderChapterRead.headingSQL(
                        body: "f.body_id", key: "f.book_key", offset: "CAST(p.offset AS INTEGER)"))))
               END AS chapter_title,
               coalesce(m.source_partition=1 OR author.record_id IS NOT NULL OR cover.record_id IS NOT NULL,0) AS has_card_metadata,
               author.value_text AS author,asset.legacy_cover_id AS cover_id,cover.sha256 AS cover_sha,
               cover.format AS cover_format,cover.width AS cover_width,cover.height AS cover_height
        """

    static func joins(onlyWhen condition: String? = nil) -> String {
        let detailPredicate = condition.map { $0 + " AND " } ?? ""
        return """
        LEFT JOIN main.books body ON \(detailPredicate)body.id=f.body_id
        LEFT JOIN lengths l ON \(detailPredicate)l.content_sha256=f.book_key
        LEFT JOIN positions p ON \(detailPredicate)p.book_key=f.book_key
        LEFT JOIN usr.local_preferred_file pref ON \(detailPredicate)pref.book_key=p.book_key
        LEFT JOIN usr.local_preferred_file source_pref ON \(detailPredicate)source_pref.book_key=p.raw_key
        LEFT JOIN usr.metadata_current m ON m.book_key=f.book_key
        LEFT JOIN usr.metadata_text_candidate author ON author.partition=m.source_partition AND author.record_id=m.author_id
        LEFT JOIN usr.cover_candidate cover ON cover.partition=m.source_partition AND cover.record_id=m.cover_id
        LEFT JOIN usr.cover_asset asset ON asset.asset_id=cover.asset_id
        """
    }
}
