import XCTest
@testable import Moonread

final class LibraryQueryRulesTests: XCTestCase {
    private func candidate(_ name: String, ordinal: UInt64, folder: Bool = false, metadata: BookMetadata? = nil, recent: Int64 = 0) -> LibrarySearchCandidate {
        let entry = LibraryEntry(id: name, shelfId: "s", shelfName: "Shelf", relativePath: name, parentPath: "", name: name,
            directory: folder, size: 0, modified: 0, needsDownload: false, bookId: nil, positionUtf8: 0, byteCount: 0,
            chapterTitle: nil, childBookCount: 0, lastRead: recent, preferred: false, coverPreviews: [], metadata: metadata,
            contentSha256: metadata?.sha, readingIdentity: metadata.map { .formal(sha256: $0.sha) })
        return .init(entry: entry, naturalOrderOrdinal: ordinal, resolvedMetadata: metadata)
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
