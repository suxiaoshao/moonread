import GRDB

/// Device-only decisions in the active user file. Callers compose these
/// statements with the opened/position write in the same transaction.
enum LocalReadingRows {
    struct Resume: Equatable, Sendable {
        let offset: UInt64
        let token: String?
    }

    static func hidden(_ db: Database, book: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM usr.local_hidden_book WHERE book_key=?)",
                          arguments: [DataIdentity.canonical(book)]) == true
    }

    static func setHidden(_ db: Database, book: String, hidden: Bool) throws {
        let key = DataIdentity.canonical(book)
        if hidden {
            try db.execute(sql: "INSERT OR IGNORE INTO usr.local_hidden_book VALUES(?)", arguments: [key])
        } else {
            try db.execute(sql: "DELETE FROM usr.local_hidden_book WHERE book_key=?", arguments: [key])
        }
    }

    static func preferredFile(_ db: Database, book: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT file_id FROM usr.local_preferred_file WHERE book_key=?",
                            arguments: [DataIdentity.canonical(book)])
    }

    static func setPreferredFile(_ db: Database, book: String, file: String) throws {
        try db.execute(sql: """
            INSERT INTO usr.local_preferred_file(book_key,file_id) VALUES(?,?)
            ON CONFLICT(book_key) DO UPDATE SET file_id=excluded.file_id
            """, arguments: [DataIdentity.canonical(book),file])
    }

    static func resume(_ db: Database, book: String) throws -> Resume? {
        guard let row = try Row.fetchOne(db, sql: "SELECT offset,last_local_write_token FROM usr.local_resume WHERE book_key=?",
                                         arguments: [DataIdentity.canonical(book)]) else { return nil }
        guard let offset = UInt64(row["offset"] as String) else { throw DataV2Error.incompatibleSource("local resume offset") }
        return Resume(offset: offset, token: row["last_local_write_token"])
    }

    static func setResume(_ db: Database, book: String, offset: UInt64, token: String?) throws {
        try db.execute(sql: """
            INSERT INTO usr.local_resume(book_key,last_local_write_token,offset) VALUES(?,?,?)
            ON CONFLICT(book_key) DO UPDATE SET last_local_write_token=excluded.last_local_write_token,offset=excluded.offset
            """, arguments: [DataIdentity.canonical(book),token,DataIdentity.unsigned(offset)])
    }

    static func promote(_ db: Database, from pending: String, to formal: String) throws {
        let old = DataIdentity.canonical(pending)
        guard old != DataIdentity.canonical(formal) else { return }
        if let file = try preferredFile(db, book: pending) {
            try setPreferredFile(db, book: formal, file: file)
            try db.execute(sql: "DELETE FROM usr.local_preferred_file WHERE book_key=?", arguments: [old])
        }
        if try hidden(db, book: pending) {
            try setHidden(db, book: formal, hidden: true)
            try setHidden(db, book: pending, hidden: false)
        }
    }
}
