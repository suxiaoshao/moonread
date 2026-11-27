import MoonreadCoreBindings

public extension BookDetails {
    var book: BookInfo? { body?.book }
    var wordCount: UInt64? { body?.wordCount }
    var chapterCount: UInt64? { body?.chapterCount }
    var currentChapter: String? { body?.currentChapter }
}

public extension BookDetailsResult {
    func requireIdentified() throws -> BookDetails {
        switch self {
        case .identified(_, let details): details
        case .unidentified, .pending: throw ReaderError.ImportBusy
        case .missing: throw ReaderError.NotFound
        }
    }
}
