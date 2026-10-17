import XCTest
import SQLite3
@testable import Moonread

final class AppStorePrivacyTests: XCTestCase {
    func testLocalizedAppAndContainerNamesAndEncryptionExemption() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
        for (language, name) in [("en", "Moonread"), ("zh-Hans", "月读"), ("zh-Hant", "月讀")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language))
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
            XCTAssertEqual(values["CFBundleDisplayName"], name)
            XCTAssertEqual(values["NSUbiquitousContainerName"], name)
        }
    }

    func testTraditionalChineseCatalogMatchesEnglishAndUsesTaiwanTerms() throws {
        func strings(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        }
        let en = try strings("en"), tw = try strings("zh-Hant")
        func keys(_ language: String, plain: [String: String]) throws -> Set<String> {
            var result = Set(plain.keys)
            if let path = Bundle.main.path(forResource: "Localizable", ofType: "stringsdict", inDirectory: nil, forLocalization: language) {
                let plural = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: Any])
                result.formUnion(plural.keys)
            }
            return result
        }
        XCTAssertEqual(try keys("zh-Hant", plain: tw), try keys("en", plain: en))
        for (key, expected) in [
            ("设置", "設定"), ("文件夹", "資料夾"), ("导入小说", "匯入小說"), ("拷贝", "複製"),
            ("阅读设置", "閱讀設定"), ("反馈这条回复", "回饋這則回覆"),
            ("同名项目", "同名項目"), ("选择项目", "選擇項目"),
            ("本批中有项目所在位置不支持最近删除，删除后无法恢复。", "本批中有項目所在位置不支援最近刪除，刪除後無法恢復。"),
            ("永久删除这些项目", "永久刪除這些項目")
        ] {
            XCTAssertEqual(tw[key], expected)
        }
        let pattern = try NSRegularExpression(pattern: #"%([0-9]+\$)?[-+0-9.]*([a-zA-Z@]+)"#)
        func formats(_ text: String) -> [String] { pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range(at: 2)) }.sorted() }
        for (key, value) in en { XCTAssertEqual(formats(tw[key] ?? ""), formats(value), "Format mismatch: \(key)") }
    }

    @MainActor func testReplyFeedbackContainsOnlySelectedTextAndRequestIdentity() async throws {
        let repository = try await AIRepository.open(inMemory: true)
        let row = AISessionValue(title: "Private conversation title")
        try await repository.create(row)
        let conversation = AIConversation(row)
        var connection = AIProviderPreset.all.first!.connection(); connection.name = "Selected Provider"
        let turn = "selected-turn"
        let old = AIAgentEntry(sequence: 0, turn: "other", provider: "other", model: "other-model", message: .object(["role": .string("assistant"), "content": .object(["value": .string("Do not include other replies")])]))
        let answer = AIAgentEntry(sequence: 1, turn: turn, provider: connection.id + ":fixture", model: "selected-model", message: .object(["role": .string("assistant"), "content": .object(["value": .string("Selected reply")])]), outcome: .completed)
        conversation.mergeEntries([old, answer])
        let selected = AIMessageRow(id: turn + "/actions", turnID: turn, content: .actions("Selected reply", .completed))
        let feedback = try XCTUnwrap(AIReplyFeedback(row: selected, conversation: conversation, connections: [connection]))
        XCTAssertEqual(feedback.recipient, AppLinks.supportEmail)
        XCTAssertEqual(feedback.provider, connection.name); XCTAssertEqual(feedback.model, answer.model)
        XCTAssertEqual(feedback.text, "Selected reply"); XCTAssertFalse(feedback.version.isEmpty)
        XCTAssertTrue(feedback.body.contains("Selected reply")); XCTAssertFalse(feedback.body.contains("Do not include other replies"))
        XCTAssertFalse(feedback.body.contains(row.title)); XCTAssertFalse(feedback.body.contains(connection.credentialReference))
        XCTAssertTrue(feedback.copyText.contains(AppLinks.supportEmail))
        XCTAssertNil(AIReplyFeedback(row: .init(id: "user", turnID: turn, content: .user(answer)), conversation: conversation, connections: [connection]))
    }

    func testThirdPartyNoticesAreBundledIncludingFontsAndMPL() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let paragraphs = try ThirdPartyNotices.loadParagraphs()
        XCTAssertEqual(paragraphs.map(\.text).joined(separator: "\n\n"), text)
        XCTAssertEqual(Set(paragraphs.map(\.id)).count, paragraphs.count)
        // Repeated legal paragraphs remain separate occurrences, not content identities.
        XCTAssertLessThan(Set(paragraphs.map(\.text)).count, paragraphs.count)
        XCTAssertFalse(text.contains("See THIRD_PARTY_NOTICES.md"))
        for required in ["MOONREAD THIRD-PARTY NOTICES", "Mozilla Public License Version 2.0",
                         "GUST Font License", "SIL OPEN FONT LICENSE", "KpMath-Sans.otf",
                         "Copyright (c) 2023 LobeHub", "Copyright (c) 2025 Mario Zechner"] {
            XCTAssertTrue(text.contains(required), "Missing distributed notice: \(required)")
        }
        XCTAssertEqual(ThirdPartyNotices.mplSources.count, 12)
        XCTAssertEqual(ThirdPartyNotices.mplSources.first?.url.absoluteString, "https://crates.io/crates/cssparser/0.37.0")
        for source in ThirdPartyNotices.mplSources {
            XCTAssertTrue(text.contains("Rust \(source.id)-\(source.version)"), "Source link must match the bundled release")
        }
    }

    func testAppManifestIsBundledAndDeclaresActualReasons() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let entries = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let reasons = Dictionary(uniqueKeysWithValues: entries.map { ($0["NSPrivacyAccessedAPIType"] as! String, $0["NSPrivacyAccessedAPITypeReasons"] as! [String]) })
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1", "3B52.1"])
        XCTAssertEqual(reasons["NSPrivacyAccessedAPICategorySystemBootTime"], ["35F9.1"])
        XCTAssertNil(reasons["NSPrivacyAccessedAPICategoryDiskSpace"])
    }

    func testPublicLinksSelectLanguageAndShowApprovedEmail() {
        XCTAssertEqual(AppLinks.privacy(language: "zh").absoluteString, "https://suxiaoshao.github.io/moonread/privacy/")
        XCTAssertEqual(AppLinks.support(language: "en").absoluteString, "https://suxiaoshao.github.io/moonread/en/support/")
        XCTAssertEqual(AppLinks.contact?.absoluteString, "mailto:suxiaoshao@gmail.com")
    }
    func testReleaseSettingsUseStableIdentifiersAndStoreErrorsPreserveData() {
        XCTAssertEqual(ReadingSettingsTab.allCases.map(\.rawValue), ["typography", "colors", "controls"])
        XCTAssertNil(ReadingSettingsTab(rawValue: "排版"))
        XCTAssertFalse(ReaderMessages.error(ReaderError.IncompatibleStore).contains("重新安装"))
        XCTAssertEqual(ReaderMessages.error(ReaderError.StoreTooNew(version: 21, current: 20)), String(localized: "数据由更新版本的月读创建，请更新应用后再打开。"))
    }

    func testSystemSQLiteWALForeignKeysReturningAndConcurrentRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("system.sqlite").path
        var writer: OpaquePointer?, reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_open(path, &reader), SQLITE_OK)
        defer { sqlite3_close(reader); sqlite3_close(writer) }
        print("System SQLite: \(String(cString: sqlite3_libversion()))")
        func execute(_ sql: String, on db: OpaquePointer?) -> Int32 { sqlite3_exec(db, sql, nil, nil, nil) }
        XCTAssertEqual(execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id)); INSERT INTO parent VALUES(1) RETURNING id;", on: writer), SQLITE_OK)
        XCTAssertEqual(execute("INSERT INTO child VALUES(2)", on: writer), SQLITE_CONSTRAINT)
        XCTAssertEqual(execute("BEGIN; INSERT INTO child VALUES(1);", on: writer), SQLITE_OK)
        XCTAssertEqual(execute("SELECT * FROM parent", on: reader), SQLITE_OK)
        XCTAssertEqual(execute("COMMIT", on: writer), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + "-wal"))
    }
}
