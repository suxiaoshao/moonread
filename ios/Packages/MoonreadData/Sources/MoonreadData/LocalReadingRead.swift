import GRDB
import MoonreadDataTypes

public enum LocalReadingRead {
    public static func preferredFile(_ db: Database, book: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT file_id FROM usr.local_preferred_file WHERE book_key=?",
                            arguments: [DataIdentity.canonical(book)])
    }
}
