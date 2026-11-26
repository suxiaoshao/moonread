
public enum ReadingIdentitySQL {
    public static let completedReadingIdentitySQL = completedReadingIdentityClause(scopeParameter: "?")

    private static func completedReadingIdentityClause(scopeParameter: String) -> String {
        """
        FROM main.import_jobs j JOIN main.books b ON b.id=COALESCE(j.canonical_id,j.book_id)
        WHERE j.pending_owner=\(scopeParameter) AND j.phase='complete' AND j.purpose='reading'
          AND b.byte_count>0 AND b.chunk_count>0
          AND (j.final_sha IS NULL OR j.final_sha=b.content_sha256)
          AND EXISTS(SELECT 1 FROM main.chunks c WHERE c.book_id=b.id AND c.chunk_index=0 AND c.end_utf8>c.start_utf8)
        """
    }

    public static let verifiedReadingAliasPairsSQL = verifiedReadingAliasPairs(scopeParameter: "?")

    public static func verifiedReadingAliasPairs(scopeParameter: String) -> String {
        """
        SELECT 'pending:'||j.book_id AS alias,b.content_sha256 AS book_key
        \(completedReadingIdentityClause(scopeParameter: scopeParameter))
        AND length(b.content_sha256)=64 AND b.content_sha256 NOT GLOB '*[^0-9a-f]*'
        """
    }

    // Both recents and cache restoration hide a formal book if any verified
    // alias is locally hidden. The caller supplies the scope-bound aliases CTE.
    public static let hiddenReadingKeysSQL = """
        SELECT coalesce(a.book_key,h.book_key) AS book_key
        FROM usr.local_hidden_book h LEFT JOIN aliases a ON a.alias=h.book_key
        """
}
