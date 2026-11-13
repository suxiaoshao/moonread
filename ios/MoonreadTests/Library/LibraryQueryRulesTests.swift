import XCTest
@testable import Moonread

final class LibraryQueryRulesTests: XCTestCase {
    func testEnglishCountResourcesSelectSingularAndIndependentPluralArguments() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let english = try XCTUnwrap(Bundle(path: path))
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(String(localized: "\(UInt64(0)) 本小说", bundle: english, locale: locale), "0 books")
        XCTAssertEqual(String(localized: "\(UInt64(1)) 本小说", bundle: english, locale: locale), "1 book")
        XCTAssertEqual(String(localized: "\(UInt64(2)) 本小说", bundle: english, locale: locale), "2 books")
        XCTAssertEqual(String(localized: "\(UInt64(1)) 个阅读日", bundle: english, locale: locale), "1 reading day")
        XCTAssertEqual(String(localized: "\(UInt64(2)) 个阅读日", bundle: english, locale: locale), "2 reading days")
        XCTAssertEqual(String(localized: "\(Int64(1)) 个阅读日 · \(Int64(2)) 本书", bundle: english, locale: locale), "1 reading day · 2 books")
        XCTAssertEqual(String(localized: "\(UInt64(1)) 字 · \(UInt64(2)) 章", bundle: english, locale: locale), "1 character · 2 chapters")
        XCTAssertEqual(String(localized: "\(UInt64(2)) 字 · \(UInt64(1)) 章", bundle: english, locale: locale), "2 characters · 1 chapter")
        XCTAssertEqual(String(localized: "\(Int64(1)) 本", table: "DataManagement", bundle: english, locale: locale), "1 book")
        XCTAssertEqual(String(localized: "删除 \(Int64(2)) 本", table: "DataManagement", bundle: english, locale: locale), "Delete 2 books")
        XCTAssertEqual(String(localized: "\(Int64(1)) 项需要处理", table: "DataManagement", bundle: english, locale: locale), "1 item needs attention")
        XCTAssertEqual(String(localized: "包含 \(Int64(1)) 本小说的阅读数据，其中 \(Int64(1)) 本在书架上", table: "DataManagement", bundle: english, locale: locale), "Reading data for 1 book; 1 on your bookshelf.")
        XCTAssertEqual(String(localized: "已清理 \(Int64(1)) 本缓存，保留 \(Int64(2)) 本", table: "DataManagement", bundle: english, locale: locale), "Cleared cache for 1 book; kept 2")
        XCTAssertEqual(String(localized: "已索引 \(Int64(0)) / \(Int64(1)) 本", table: "FullIndex", bundle: english, locale: locale), "Indexed 0 / 1 book")
        XCTAssertEqual(String(localized: "已索引 \(Int64(1)) / \(Int64(2)) 本", table: "FullIndex", bundle: english, locale: locale), "Indexed 1 / 2 books")
        XCTAssertEqual(String(localized: "有 \(Int64(1)) 本未索引", table: "ShelfRecovery", bundle: english, locale: locale), "1 book not indexed")
        XCTAssertEqual(String(localized: "导入备份", table: "DataManagement", bundle: english, locale: locale), "Import")

        // Settings/cache table ownership and missing labels must resolve from the shipped bundles.
        let labels: [(String, String, String, String)] = [
            ("DataManagement", "数据管理", "Data Management", "資料管理"),
            ("DataManagement", "清理缓存", "Clear Cache", "清除快取"),
            ("Localizable", "标签关系", "Tag Matching", "標籤關係"),
            ("Localizable", "格式", "Format", "格式"),
            ("Localizable", "使用此配色的应用槽位将恢复纸色，阅读槽位将恢复跟随应用。", "App slots using this palette will revert to Paper; reading slots will return to Follow App.", "使用此配色的應用程式槽位將恢復紙色，閱讀槽位將恢復跟隨應用程式。"),
            ("Localizable", "回到正文", "Return to Reading", "回到正文"),
            ("Localizable", "导入", "Import", "匯入"),
            ("Localizable", "好", "OK", "好"),
            ("Localizable", "下载", "Download", "下載"),
            ("Localizable", "展开", "Expand", "展開"),
            ("Localizable", "字号", "Font Size", "字級"),
            ("Localizable", "行距", "Line Spacing", "行距"),
            ("Localizable", "段间距", "Paragraph Spacing", "段落間距"),
            ("Localizable", "左右边距", "Side Margins", "左右邊界"),
            ("Localizable", "最大行宽", "Maximum Line Width", "最大行寬"),
            ("Localizable", "打开 ${target}", "Open ${target}", "開啟 ${target}"),
            ("Localizable", "显示 ${book}", "Show ${book}", "顯示 ${book}"),
            ("Localizable", "查看 ${period} 的阅读统计", "View reading statistics for ${period}", "查看 ${period} 的閱讀統計")
        ]
        for (language, identifier) in [("en", "en_US"), ("zh-Hant", "zh_TW")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for (table, key, en, hant) in labels {
                let expected = language == "en" ? en : hant
                XCTAssertEqual(String(localized: String.LocalizationValue(key), table: table, bundle: bundle, locale: Locale(identifier: identifier)), expected, "\(language) / \(table) / \(key)")
            }
        }
    }

    private func candidate(_ name: String, ordinal: UInt64, folder: Bool = false, metadata: BookMetadata? = nil, recent: Int64 = 0) -> LibrarySearchCandidate {
        let resolution: BookResolution = metadata.map {
            .resolved(record: .init(key: .formal(sha256: $0.sha), body: .absent, aliases: []))
        } ?? .unidentified(fileId: name)
        let item: Moonread.LibraryItem = folder ? .folder(row: .init(childBookCount: 0, coverPreviews: []))
            : .book(row: .init(resolution: resolution, needsDownload: false, positionUtf8: 0, byteCount: 0,
                              chapterTitle: nil, preferred: false, metadata: metadata, cardMetadata: nil))
        let entry = LibraryEntry(id: name, shelfId: "s", shelfName: "Shelf", relativePath: name, parentPath: "", name: name,
                                 size: 0, modified: 0, lastRead: recent, item: item)
        return .init(entry: entry, naturalNameOrdinal: ordinal, naturalOrderOrdinal: ordinal, resolvedMetadata: metadata, matchFields: nil)
    }
    func testReplacingBookMetadataInvalidatesNarrowCardPresentation() throws {
        var entry = candidate("fixture.txt", ordinal: 0).entry
        var row = try XCTUnwrap(entry.bookRow)
        row.cardMetadata = .init(author: "Stale card", cover: nil)
        entry.item = .book(row: row)
        let actual = BookMetadata(sha: String(repeating: "a", count: 64), author: "New full value", synopsis: "", tags: [], cover: nil, status: .unread)
        XCTAssertEqual(entry.withMetadata(actual).displayMetadata?.author, actual.author)
        XCTAssertNil(entry.withMetadata(nil).displayMetadata)
    }
    func testBookMatchingProfilesKeepTheirExistingContracts() {
        let metadata = BookMetadata(sha: String(repeating: "a", count: 64), author: "林澄", synopsis: "月港漫游", tags: ["武侠", "原创"], cover: nil, status: .paused)
        let rows = [candidate("星河书简.txt", ordinal: 3), candidate("星河外传.txt", ordinal: 4),
                    candidate("书简星河.txt", ordinal: 0), candidate("雨巷.txt", ordinal: 5, metadata: metadata),
                    candidate("txt说明.txt", ordinal: 1), candidate("星河", ordinal: 2, folder: true)]
        func names(_ spec: LibraryQueryRules.SearchSpec) -> [String] { LibraryQueryRules.filterAndRank(rows, spec: spec).map(\.name) }
        XCTAssertEqual(names(.init(profile: .library, query: " 星河 ")), ["星河书简.txt", "星河外传.txt", "书简星河.txt", "星河"])
        XCTAssertEqual(names(.init(profile: .library, query: "txt")), ["txt说明.txt"])
        XCTAssertEqual(names(.init(profile: .library, query: "林")), ["雨巷.txt"])
        XCTAssertEqual(names(.init(profile: .library, author: "林澄")), ["雨巷.txt"])
        XCTAssertTrue(names(.init(profile: .library, author: "林")).isEmpty)
        XCTAssertTrue(names(.init(profile: .library, query: "  ")).isEmpty)
        XCTAssertEqual(names(.init(profile: .library, tags: ["武侠"])), ["雨巷.txt"])
        XCTAssertTrue(names(.init(profile: .library, query: "星", author: "林澄")).isEmpty)
        XCTAssertEqual(names(.init(profile: .ai, query: "月港", author: "林", tags: ["原创", "武侠"], status: "paused")), ["雨巷.txt"])
        XCTAssertTrue(names(.init(profile: .ai, query: " 月港 ")).isEmpty)
        XCTAssertTrue(names(.init(profile: .ai, tags: ["不存在"])).isEmpty)
        XCTAssertTrue(names(.init(profile: .ai, status: "finished")).isEmpty)
        XCTAssertEqual(names(.init(profile: .ai)).count, 5, "AI empty query includes all books but no folders")
        XCTAssertEqual(names(.init(profile: .ai, nameOrder: true)), ["txt说明.txt", "书简星河.txt", "星河书简.txt", "星河外传.txt", "雨巷.txt"])
        let unicode = [candidate("café.txt", ordinal: 0), candidate("cafe\u{301}.txt", ordinal: 1), candidate("星.txt", ordinal: 2)]
        XCTAssertEqual(LibraryQueryRules.filterAndRank(unicode, spec: .init(profile: .library, query: "cafe\u{301}")).map(\.id), ["cafe\u{301}.txt"])
        XCTAssertTrue(LibraryQueryRules.filterAndRank(unicode, spec: .init(profile: .library, query: "\u{200b}星")).isEmpty)
        XCTAssertEqual(LibraryQueryRules.filterSuggestions(["月港", "星灯"], query: "月"), ["月港"])
        XCTAssertTrue(LibraryQueryRules.selectionMatches("Moonread", query: "moon"))
    }
    func testLibraryPinyinSearchSharesSystemSpellingAndKeepsQueryBoundaries() {
        let author = BookMetadata(sha: String(repeating: "a", count: 64), author: "林清", synopsis: "", tags: ["原创"], cover: nil, status: .reading)
        let incidental = BookMetadata(sha: String(repeating: "b", count: 64), author: "", synopsis: "林清", tags: ["林清"], cover: nil, status: .unread)
        let rows = [candidate("林清集.txt", ordinal: 3), candidate("读林清记.txt", ordinal: 2),
                    candidate("月光来信.txt", ordinal: 1, metadata: author, recent: 10),
                    candidate("春日.txt", ordinal: 0, metadata: incidental),
                    candidate("林清", ordinal: 4, folder: true), candidate("Clean Book.txt", ordinal: 5)]
        func names(_ spec: LibraryQueryRules.SearchSpec) -> [String] { LibraryQueryRules.filterAndRank(rows, spec: spec).map(\.name) }
        let matches = ["林清集.txt", "读林清记.txt", "月光来信.txt"]
        XCTAssertEqual(names(.init(profile: .library, query: "linqing")), matches)
        XCTAssertEqual(names(.init(profile: .library, query: " LQ ")), matches)
        XCTAssertEqual(names(.init(profile: .library, query: "linqing", tags: ["原创"])), ["月光来信.txt"])
        XCTAssertEqual(names(.init(profile: .library, query: "lq", configuration: .init(sorts: [.init(field: .recent, descending: true)]))).first, "月光来信.txt")
        XCTAssertTrue(names(.init(profile: .library, author: "linqing")).isEmpty, "Explicit author selection remains exact")
        XCTAssertTrue(names(.init(profile: .library, query: "cb")).isEmpty, "Do not add Latin-word initials")
        XCTAssertTrue(names(.init(profile: .library, query: "lqjtxt")).isEmpty, "The extension is not part of title spelling")
        XCTAssertTrue(names(.init(profile: .ai, query: "linqing")).isEmpty, "The AI matching profile is unchanged")
        XCTAssertEqual(names(.init(profile: .library, query: "林")), ["林清集.txt", "读林清记.txt", "月光来信.txt", "林清"])
        XCTAssertEqual(LibraryQueryRules.pinyinSpellings("绿野"), ["lvye", "ly"])
        let title = "重山来信", spellings = LibraryQueryRules.pinyinSpellings(title)
        let systemTerms = LibraryQueryRules.systemMetadataTerms(title: title, author: "林清", tags: [])
        for spelling in spellings {
            XCTAssertTrue(systemTerms.contains(spelling))
            XCTAssertEqual(LibraryQueryRules.filterAndRank([candidate(title + ".txt", ordinal: 0)], spec: .init(profile: .library, query: spelling)).count, 1, "Use the same system-default polyphonic reading")
        }
    }
    func testBookSearchExpressionsKeepUnknownDistinctFromAbsenceAndCompose() {
        let known = candidate("已索引.txt", ordinal: 0, metadata: .init(sha: String(repeating: "a", count: 64), author: "林澄", synopsis: "", tags: [], cover: nil, status: .unread))
        let unknown = candidate("未索引.txt", ordinal: 1)
        var future = known; future.resolvedMetadata?.status = .other(value: "Future")
        let unread = BookSearchNode(kind: .rule(.status([.unread])))
        XCTAssertEqual(LibraryQueryRules.evaluate(unread, candidate: known), .yes)
        XCTAssertEqual(LibraryQueryRules.evaluate(unread, candidate: unknown), .unknown)
        XCTAssertEqual(LibraryQueryRules.evaluate(unread, candidate: future), .unknown)
        var notRead = BookSearchNode(excluded: true, kind: .group(.all, [unread]))
        XCTAssertEqual(LibraryQueryRules.evaluate(notRead, candidate: unknown), .unknown)
        let author = BookSearchNode(kind: .rule(.author(["林澄"])))
        var either = BookSearchNode(kind: .group(.any, [author, unread]))
        XCTAssertEqual(LibraryQueryRules.evaluate(either, candidate: future), .yes, "Known true OR unknown is true")
        either.group = .all
        XCTAssertEqual(LibraryQueryRules.evaluate(either, candidate: future), .unknown)
        notRead.children = [BookSearchNode(kind: .rule(.tag(.any, [.untagged])))]
        XCTAssertEqual(LibraryQueryRules.evaluate(notRead, candidate: known), .no)
        XCTAssertEqual(LibraryQueryRules.evaluate(notRead, candidate: unknown), .unknown)
        var tags = BookSearchNode(kind: .rule(.tag(.any, [.untagged, .text("生活")])))
        XCTAssertEqual(LibraryQueryRules.evaluate(tags, candidate: known), .yes)
        tags.match = .all
        XCTAssertNotNil(tags.validation())
        tags.match = .none
        XCTAssertNil(tags.validation())
        XCTAssertEqual(LibraryQueryRules.evaluate(tags, candidate: known), .no)
        tags.values = [.text("生活")]
        XCTAssertEqual(LibraryQueryRules.evaluate(tags, candidate: known), .yes)
        XCTAssertEqual(LibraryQueryRules.evaluate(tags, candidate: unknown), .unknown)
        XCTAssertNotNil(BookSearchNode(kind: .group(.all, [BookSearchNode()])).validation(isRoot: true))
        let config = BookSearchConfiguration(root: BookSearchNode(kind: .group(.all, [unread])))
        let result = LibraryQueryRules.searchOutcome([known, unknown, future], spec: .init(profile: .library, configuration: config))
        XCTAssertEqual(result.entries.map(\.id), [known.entry.id])
        XCTAssertEqual(result.unknownCount, 2)
        let scope = BookSearchConfiguration(root: BookSearchNode(kind: .group(.all, [BookSearchNode(kind: .rule(.shelf([known.entry.shelfId])))])))
        XCTAssertEqual(LibraryQueryRules.filterAndRank([known, unknown], spec: .init(profile: .library, configuration: scope)).count, 2, "Shelf-only queries include unindexed files")
    }
    func testExplicitBookSortingOverridesMatchAndMissingValuesStayLast() {
        let meta = BookMetadata(sha: String(repeating: "a", count: 64), author: "A", synopsis: "", tags: [], cover: nil, status: .reading)
        let prefix = candidate("星河1.txt", ordinal: 0, metadata: meta, recent: 1)
        let contains = candidate("夜星河.txt", ordinal: 1, metadata: meta, recent: 10)
        let missing = candidate("星河2.txt", ordinal: 2)
        func ids(_ sorts: [BookSearchSort]) -> [String] {
            LibraryQueryRules.filterAndRank([prefix, contains, missing], spec: .init(profile: .library, query: "星河", configuration: .init(sorts: sorts))).map(\.id)
        }
        XCTAssertEqual(ids([]), [prefix.entry.id, missing.entry.id, contains.entry.id])
        XCTAssertEqual(ids([.init(field: .recent, descending: true)]), [contains.entry.id, prefix.entry.id, missing.entry.id])
        XCTAssertEqual(ids([.init(field: .recent)]), [prefix.entry.id, contains.entry.id, missing.entry.id])
        XCTAssertEqual(ids([.init(field: .author, descending: true)]).last, missing.entry.id)
        var sameName = contains; sameName.naturalNameOrdinal = prefix.naturalNameOrdinal
        let ordered = LibraryQueryRules.filterAndRank([prefix, sameName], spec: .init(profile: .library, configuration: .init(sorts: [.init(field: .name), .init(field: .recent, descending: true)])))
        XCTAssertEqual(ordered.map(\.id), [sameName.entry.id, prefix.entry.id], "Equal natural names defer to the next explicit key")
        XCTAssertEqual(LibraryQueryRules.filterAndRank([prefix, missing], spec: .init(profile: .library, configuration: .init(sorts: [.init(field: .rank)]))).count, 2)
    }
    @MainActor func testSupersededDirectoryResponseCannotReplaceNewScope() async throws {
        let request = LibraryCatalogueRequest()
        let entered = expectation(description: "old scope query started")
        let gate = RestorationGate(entered)
        let old = Task { try await request.read { await gate.wait(); return [self.candidate("old.txt", ordinal: 0).entry] } }
        await fulfillment(of: [entered], timeout: 2)
        let current = try await request.read { [self.candidate("new.txt", ordinal: 0).entry] }
        XCTAssertEqual(current?.map(\.id), ["new.txt"])
        await gate.release()
        let superseded = try await old.value
        XCTAssertNil(superseded)
    }
}
