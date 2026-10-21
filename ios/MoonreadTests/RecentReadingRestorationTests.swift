import XCTest
import SwiftData
import CryptoKit
@testable import Moonread

private actor RestorationGate {
    let entered: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() async { if !released { await withCheckedContinuation { continuation = $0; entered.fulfill() } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor RestorationReads {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}
extension ReaderService {
    func restorationFixture(active: Bool, beforeRead: (@Sendable (String) async -> Void)? = nil,
                            beforeCommit: (@Sendable () async -> Void)? = nil) {
        recentRestorationActive = active
        recentRestorationBeforeRead = beforeRead; recentRestorationBeforeCommit = beforeCommit
    }
    func restorationFixtureWasCancelled() -> Bool { recentRestorationWork?.isCancelled == true }
    func stopRestorationFixtureFollowUp() { recentRestorationRequested = false }
}

@MainActor final class RecentReadingRestorationTests: XCTestCase {
    private struct Fixture {
        let root: URL, directory: URL
        let core: ReaderCore, service: ReaderService
        let store: UserDataStore, pending: UserDataStore
        let suite: String
        func clean() { UserDefaults.standard.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(_ files: [String: Data] = [:]) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        func makeStore() throws -> UserDataStore {
            let schema = UserDataStore.schema
            return UserDataStore(modelContainer: try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]))
        }
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("cache").path)
        let store = try makeStore(), pending = try makeStore(), suite = "RecentRestore-" + UUID().uuidString
        let service = ReaderService(core: core, libraryDirectory: directory, sourceDefaultsSuite: suite,
            userStoreFactory: { name, _ in name == "pending-users.store" ? pending : store })
        await service.restorationFixture(active: false)
        try core.saveLibraryShelf(id: "builtin", name: "Synthetic library", bookmark: directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), location: "local", builtin: true)
        return Fixture(root: root, directory: directory, core: core, service: service, store: store, pending: pending, suite: suite)
    }
    private func scan(_ f: Fixture) async throws {
        let files = try ReaderService.libraryDirectoryItems(f.directory)
        try await f.service.applyLibraryScan("builtin", root: f.directory, items: files, observe: false)
    }
    private func hint(_ path: String, size: UInt64?, decoding: String = "auto") -> PositionSourceHint {
        .init(source_kind: .managedLocal, relative_path: path, file_name: (path as NSString).lastPathComponent, byte_size: size, decoding: decoding)
    }
    private func position(_ f: Fixture, key: String, hint: PositionSourceHint?, time: Int64 = 123456, offset: UInt64 = 12, token: String = "original") async throws {
        let value = PositionValue(content_key: key, offset: offset, source_hint: hint)
        let stored = StoredValue(updated: time, token: token, value: try UserSyncJSON.encode(value))
        try await f.store.receiveSyncFixture("position", key: key, payload: UserSyncJSON.encode(stored, envelope: true))
    }
    private func snapshot(_ store: UserDataStore) async throws -> [[String]] {
        var result: [[String]] = []
        for kind in ["position", "value", "mark", "fact", "clear"] { result.append(try await store.syncFixturePayloads(kind)) }
        return result
    }
    private func restore(_ f: Fixture, retry: Bool = false) async {
        await f.service.restorationFixture(active: true)
        await f.service.scheduleRecentRestoration(retry: retry)
        await f.service.waitForRecentRestoration()
    }
    private func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func testAutomaticIndexContinuesWithAnotherShelfRequestedWhileRunning() async throws {
        let f = try await fixture(["first.txt": Data("第一話 星港\n原创首册。\n".utf8)]); defer { f.clean() }
        try await scan(f)
        let other = f.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("第二話 月台\n原创次册。\n".utf8).write(to: other.appendingPathComponent("second.txt"))
        let secondID = try await f.service.registerLibraryShelf(other)
        try await f.service.applyLibraryScan(secondID, root: other, items: ReaderService.libraryDirectoryItems(other), observe: false)
        let entered = expectation(description: "foreground keeps first shelf pending"), release = RestorationGate(entered)
        let foreground = Task { try await f.service.withForegroundOpening { await release.wait() } }
        await fulfillment(of: [entered], timeout: 3)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
        let controller = FullIndexController(defaults: defaults, service: f.service, registerTasks: false)
        controller.start("builtin", includeCloud: false, userInitiated: false)
        XCTAssertTrue(controller.running)
        controller.start(secondID, includeCloud: false, userInitiated: false)
        let saved = try XCTUnwrap(defaults.data(forKey: "Moonread.fullIndex.request.v1"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual((request["queued"] as? [[String: Any]])?.first?["shelf"] as? String, secondID)
        await release.release(); try await foreground.value
        await controller.waitForCompletion()
        XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
        XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: secondID).isEmpty)
        XCTAssertEqual(controller.shelfID, secondID)
    }

    func testIndexedOnlyRecentHideAndDetailsUseContentSHA() async throws {
        let text = "第一話 星港\n只用于验证索引身份的原创正文。\n"
        let f = try await fixture(["indexed.txt": Data(text.utf8)]); defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.pendingIdentityFiles(shelfId: "builtin").first)
        let identity = try SourceIdentityProbe().identify(filePath: f.directory.appendingPathComponent(file.relativePath).path, decoding: file.decoding)
        XCTAssertTrue(try f.core.publishSourceIdentity(file: file, identity: identity))
        try await position(f, key: identity.contentSha256, hint: nil, offset: identity.utf8Bytes / 2)
        let base = try await f.service.details(sha: identity.contentSha256).metadata
        var edited = base; edited.author = "原创作者"; edited.tags = ["星港"]
        try await f.service.saveMetadata(base: base, edited: edited)
        let cold = try await f.service.recentLibrary(cold: true)
        let warm = try await f.service.recentLibrary()
        XCTAssertEqual(cold.map(\.readingKey), [identity.contentSha256])
        XCTAssertEqual(warm.map(\.readingKey), [identity.contentSha256])
        let entry = try XCTUnwrap(warm.first)
        XCTAssertNil(entry.bookId)
        let model = BookInformationModel(service: f.service)
        await model.load(StatisticsRoute(key: entry.readingKey, bookID: entry.bookId, title: entry.title, fileID: entry.id))
        XCTAssertNil(model.error)
        XCTAssertEqual(model.entry?.positionUtf8, identity.utf8Bytes / 2)
        XCTAssertEqual(model.details?.metadata.tags, ["星港"])
        XCTAssertEqual(model.details?.metadata.author, "原创作者")
        try await f.service.hideRecent(try XCTUnwrap(entry.readingKey))
        let hidden = try await f.service.recentLibrary()
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId)
    }

    func testIndexAutomaticallyContinuesAfterOpeningFails() async throws {
        let f = try await fixture(["sample.txt": Data("第一話 星港\n用于失败恢复验证的原创正文。\n".utf8)]); defer { f.clean() }
        try await scan(f)
        let entered = expectation(description: "opening holds gate"), release = RestorationGate(entered)
        let failed = Task {
            try await f.service.withForegroundOpening {
                await release.wait()
                try await f.service.prepareSourceFile(SourceFile(id: "missing-file", shelfID: "builtin", relativePath: "missing.txt"))
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        let controller = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
        controller.start("builtin", includeCloud: false, userInitiated: false)
        await release.release()
        do { try await failed.value; XCTFail("opening missing file should fail") } catch { }
        await controller.waitForCompletion()
        XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
        let idle = await f.service.identityMayRun(); XCTAssertTrue(idle)
    }

    func testIndexWaitsThroughoutForegroundOpening() async throws {
        let f = try await fixture(["sample.txt": Data("第一話 星港\n用于阅读闸门验证的原创正文。\n".utf8)]); defer { f.clean() }
        try await scan(f)
        let entered = expectation(description: "opening holds gate"), release = RestorationGate(entered)
        let opened = Task { try await f.service.withForegroundOpening { await release.wait() } }
        await fulfillment(of: [entered], timeout: 3)
        let controller = FullIndexController(defaults: try XCTUnwrap(UserDefaults(suiteName: f.suite)), service: f.service, registerTasks: false)
        controller.start("builtin", includeCloud: false, userInitiated: false)
        // Let the real runner reach the gate; no source identity may be published.
        let waiting = NSPredicate { _, _ in controller.message == String(localized: "阅读结束后继续建立索引", table: "FullIndex") }
        await fulfillment(of: [expectation(for: waiting, evaluatedWith: nil)], timeout: 3)
        XCTAssertEqual(try f.core.pendingIdentityFiles(shelfId: "builtin").count, 1)
        await release.release(); try await opened.value
        await controller.waitForCompletion()
        XCTAssertTrue(try f.core.pendingIdentityFiles(shelfId: "builtin").isEmpty)
    }

    func testExplicitHintShapeNullableFieldsAndPendingTransferPreserveOriginalClock() async throws {
        let f = try await fixture(); defer { f.clean() }
        let h = hint("原创/样本.txt", size: nil, decoding: "UTF-8")
        let value = PositionValue(content_key: "pending:sample", offset: 12, source_hint: h)
        let json = try UserSyncJSON.encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertTrue((object["source_hint"] as? [String: Any])?["byte_size"] is NSNull)
        let empty = try UserSyncJSON.encode(PositionValue(content_key: "sha", offset: 0))
        XCTAssertTrue(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(empty.utf8)) as? [String: Any])["source_hint"] is NSNull)
        let encoded = try UserSyncJSON.encode(StoredValue(updated: 123, token: "keep-token", value: json), envelope: true)
        try await f.pending.receiveSyncFixture("position", key: "pending:sample", payload: encoded)
        let transfer = try await f.pending.exportPending(key: "pending:sample")
        try await f.store.importPending(transfer, from: "pending:sample", to: "sha")
        let rows = try await f.store.recentRestorationPositions(limit: 10)
        XCTAssertEqual(rows.first?.hint, h); XCTAssertEqual(rows.first?.updated, 123); XCTAssertEqual(rows.first?.token, "keep-token")
        for mutation in ["missingHint", "missingSize", "unknown", "escape", "absolute", "name", "encoding", "kind", "type", "size"] {
            var bad = object, nested = try XCTUnwrap(object["source_hint"] as? [String: Any])
            switch mutation {
            case "missingHint": bad.removeValue(forKey: "source_hint")
            case "missingSize": nested.removeValue(forKey: "byte_size")
            case "unknown": nested["future"] = true
            case "escape": nested["relative_path"] = "../样本.txt"
            case "absolute": nested["relative_path"] = "/原创/样本.txt"
            case "name": nested["file_name"] = "other.txt"
            case "encoding": nested["decoding"] = "x-user-defined"
            case "kind": nested["source_kind"] = "future"
            case "type": nested["byte_size"] = "12"
            default: nested["byte_size"] = UInt64.max
            }
            if mutation != "missingHint" { bad["source_hint"] = nested }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: bad), as: UTF8.self)
            XCTAssertThrowsError(try UserSyncJSON.decode(PositionValue.self, text, as: UserSyncJSON.position), mutation)
        }
        // Build 2's missing field is explicitly unsupported; never rewrite it.
        let legacy = try UserSyncJSON.encode(StoredValue(updated: 999, token: "old", value: "{\"content_key\":\"legacy\",\"offset\":12}"), envelope: true)
        try await f.store.receiveSyncFixture("position", key: "legacy", payload: legacy)
        let before = try await snapshot(f.store)
        await restore(f)
        let after = try await snapshot(f.store); XCTAssertEqual(before, after)
        let compatible = try await f.store.recentRestorationPositions(limit: 10)
        XCTAssertFalse(compatible.contains { $0.contentKey == "legacy" })
    }

    func testBothArrivalOrdersRestoreRecentTimeAndPositionWithoutUserDataWrites() async throws {
        let text = "第一章 原创样本\n月色安静地落在窗沿，读者可以回到原来的阅读位置。\n"
        for positionFirst in [true, false] {
            let f = try await fixture(["目录/恢复.txt": Data(text.utf8)]); defer { f.clean() }
            let key = sha(text), h = hint("目录/恢复.txt", size: UInt64(text.utf8.count))
            if !positionFirst {
                try await scan(f)
                await restore(f)
                XCTAssertNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
            }
            try await position(f, key: key, hint: h)
            let before = try await snapshot(f.store), pendingBefore = try await snapshot(f.pending)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: f.suite))
            let preferences = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("Moonread.") }
            if positionFirst {
                await restore(f)
                XCTAssertTrue(try f.core.sourceFileSnapshots(fileId: nil).isEmpty)
                try await scan(f)
            } else {
                await f.service.receivedUserImport()
            }
            await f.service.waitForRecentRestoration()
            let files = try f.core.sourceFileSnapshots(fileId: nil)
            XCTAssertNotNil(files.first?.bookId)
            let recent = try await f.service.recentLibrary(10, cold: true)
            XCTAssertEqual(recent.count, 1); XCTAssertEqual(recent.first?.lastRead, 123456); XCTAssertEqual(recent.first?.positionUtf8, 12)
            let after = try await snapshot(f.store), pendingAfter = try await snapshot(f.pending)
            XCTAssertEqual(before, after); XCTAssertEqual(pendingBefore, pendingAfter)
            XCTAssertTrue(NSDictionary(dictionary: defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("Moonread.") }).isEqual(to: preferences))
            XCTAssertEqual(try Data(contentsOf: f.directory.appendingPathComponent("目录/恢复.txt")), Data(text.utf8))
        }
    }

    func testWrongSameNameAndSizeIsNotLinkedAndFailuresDoNotLoop() async throws {
        let text = "Original sample A\n", wrong = "Original sample B\n"
        let f = try await fixture(["old/sample.txt": Data(wrong.utf8)]); defer { f.clean() }
        try await scan(f)
        let reads = RestorationReads()
        await f.service.restorationFixture(active: true, beforeRead: { await reads.record($0) })
        let key = sha(text)
        try await position(f, key: key, hint: hint("moved/sample.txt", size: UInt64(text.utf8.count)))
        await f.service.scheduleRecentRestoration(); await f.service.waitForRecentRestoration()
        XCTAssertNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
        XCTAssertThrowsError(try f.core.textIdForSha(sha: key))
        for _ in 0..<3 { await f.service.scheduleRecentRestoration(); await f.service.waitForRecentRestoration() }
        let failures = await reads.ids; XCTAssertEqual(failures.count, 1)
        try Data(text.utf8).write(to: f.directory.appendingPathComponent("old/sample.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: f.directory.appendingPathComponent("old/sample.txt").path)
        try await scan(f); await f.service.waitForRecentRestoration()
        XCTAssertNotNil(try f.core.sourceFileSnapshots(fileId: nil).first?.bookId)
        let retried = await reads.ids; XCTAssertEqual(retried.count, 2)
    }

    func testManagedHintsMatchOnlyBuiltinAcrossLocalAndCloudLocations() {
        func candidate(_ id: String, builtin: Bool, location: String) -> RecentRestorationPolicy.Candidate {
            .init(file: .init(id: id, shelfId: id, relativePath: "sample.txt", size: 20, modified: 1, needsDownload: false, bookId: nil, decoding: "auto"),
                  shelf: .init(id: id, name: "Synthetic", bookmark: Data(), location: location, builtin: builtin, error: nil, bookCount: 0))
        }
        let external = (0..<4).map { candidate("external-\($0)", builtin: false, location: "local") }
        for kind: PositionSourceHint.Kind in [.managedLocal, .managedICloud] {
            for location in ["local", "icloud"] {
                var h = hint("sample.txt", size: 20); h.source_kind = kind
                let builtin = candidate("builtin", builtin: true, location: location)
                XCTAssertEqual(RecentRestorationPolicy.candidates(hint: h, files: external + [builtin]).map { $0.file.id }, ["builtin"], "\(kind) → \(location)")
            }
        }
        var externalHint = hint("sample.txt", size: 20); externalHint.source_kind = .external
        let builtin = candidate("builtin", builtin: true, location: "local")
        XCTAssertEqual(RecentRestorationPolicy.candidates(hint: externalHint, files: [builtin, external[0]]).map { $0.file.id }, [external[0].file.id])
    }

    func testLocalHintCanAdmitUniqueBuiltinCloudDownloadDespiteExternalPaths() {
        func candidate(_ id: String, builtin: Bool) -> RecentRestorationPolicy.Candidate {
            .init(file: .init(id: id, shelfId: id, relativePath: "sample.txt", size: 20, modified: 1, needsDownload: true, bookId: nil, decoding: "auto"),
                  shelf: .init(id: id, name: "Synthetic", bookmark: Data(), location: "icloud", builtin: builtin, error: nil, bookCount: 0))
        }
        let builtin = candidate("builtin", builtin: true)
        let all = [builtin] + (0..<4).map { candidate("external-\($0)", builtin: false) }
        let h = hint("sample.txt", size: 20)
        XCTAssertTrue(RecentRestorationPolicy.canAutomaticallyDownload(hint: h, candidate: builtin, files: all))
        XCTAssertEqual(RecentRestorationPolicy.candidates(hint: h, files: all).map { $0.file.id }, ["builtin"])
    }

    func testPolicyBoundsAmbiguityDownloadSizeAndManualDecoding() {
        func candidate(_ id: String, path: String = "sample.txt", remote: Bool = true, policy: String = "auto", shelfID: String = "builtin", size: UInt64 = 20) -> RecentRestorationPolicy.Candidate {
            .init(file: .init(id: id, shelfId: shelfID, relativePath: path, size: size, modified: 1, needsDownload: remote, bookId: nil, decoding: policy),
                  shelf: .init(id: shelfID, name: "Synthetic", bookmark: Data(), location: "icloud", builtin: shelfID == "builtin", error: nil, bookCount: 0))
        }
        let one = candidate("one")
        var h = hint("sample.txt", size: 20); h.source_kind = .managedICloud
        XCTAssertEqual(RecentRestorationPolicy.candidates(hint: h, files: [one]).map { $0.file.id }, ["one"])
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [one, candidate("two")]).isEmpty)
        h.byte_size = nil; XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [one]).isEmpty)
        h.byte_size = RecentRestorationPolicy.automaticDownloadByteLimit + 1
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [one]).isEmpty)
        h.byte_size = RecentRestorationPolicy.automaticDownloadByteLimit
        XCTAssertEqual(RecentRestorationPolicy.candidates(hint: h, files: [one]).count, 1)
        h.byte_size = 20
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [candidate("grown", size: RecentRestorationPolicy.automaticDownloadByteLimit + 1)]).isEmpty)
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [candidate("manual", remote: false, policy: "Big5")]).isEmpty)
        let many = (0..<4).map { candidate("\($0)", remote: false) }
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: many).isEmpty)
        h.relative_path = "moved/sample.txt"; h.byte_size = nil
        XCTAssertTrue(RecentRestorationPolicy.candidates(hint: h, files: [candidate("local", remote: false)]).isEmpty)
    }

    func testOnlyTenNewestKeysAndCoalescedRequestsReadAdmittedFiles() async throws {
        let f = try await fixture(Dictionary(uniqueKeysWithValues: (0..<12).map { ("sample-\($0).txt", Data("Original sample \($0)\n".utf8)) })); defer { f.clean() }
        try await scan(f)
        for i in 0..<12 {
            let text = "Original sample \(i)\n"
            try await position(f, key: sha(text), hint: hint("sample-\(i).txt", size: UInt64(text.utf8.count)), time: Int64(i + 1))
        }
        // Hidden positions must not consume one of the ten visible slots.
        UserDefaults(suiteName: f.suite)?.set([sha("Original sample 11\n")], forKey: "Moonread.hiddenRecent")
        let reads = RestorationReads()
        await f.service.restorationFixture(active: true, beforeRead: { await reads.record($0) })
        for _ in 0..<3 { await f.service.scheduleRecentRestoration() }
        await f.service.waitForRecentRestoration()
        let files = try f.core.sourceFileSnapshots(fileId: nil)
        XCTAssertEqual(files.filter { $0.bookId != nil }.count, 10)
        XCTAssertNil(files.first { $0.relativePath == "sample-0.txt" }?.bookId)
        XCTAssertNil(files.first { $0.relativePath == "sample-11.txt" }?.bookId)
        XCTAssertNotNil(files.first { $0.relativePath == "sample-1.txt" }?.bookId)
        let admitted = await reads.ids
        XCTAssertEqual(admitted.count, 10); XCTAssertEqual(Set(admitted).count, 10)
    }

    func testUniqueCloudPlaceholdersAdmitOnlyEligibleRecentCandidatesSerially() async throws {
        let text = "Original cloud sample\n"
        let f = try await fixture(["small.txt": Data(text.utf8), "large.txt": Data((text + "large").utf8), "unrelated.txt": Data("Unrelated".utf8)])
        defer { f.clean() }
        let bookmark = try f.directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try f.core.saveLibraryShelf(id: "builtin", name: "Synthetic cloud", bookmark: bookmark, location: "icloud", builtin: true)
        var indexed = try ReaderService.libraryDirectoryItems(f.directory)
        for i in indexed.indices { indexed[i].needsDownload = true }
        try await f.service.applyLibraryScan("builtin", root: f.directory, items: indexed, observe: false)
        var h = hint("small.txt", size: UInt64(text.utf8.count)); h.source_kind = .managedICloud
        try await position(f, key: sha(text), hint: h, time: 10)
        var big = hint("large.txt", size: RecentRestorationPolicy.automaticDownloadByteLimit + 1); big.source_kind = .managedICloud
        try await position(f, key: sha(text + "large"), hint: big, time: 9)
        let entered = expectation(description: "one admitted source only"), gate = RestorationGate(entered), reads = RestorationReads()
        await f.service.restorationFixture(active: true, beforeRead: { id in await reads.record(id); await gate.wait() })
        await f.service.scheduleRecentRestoration()
        await fulfillment(of: [entered], timeout: 5)
        for _ in 0..<3 { await f.service.scheduleRecentRestoration() }
        let pendingReads = await reads.ids; XCTAssertEqual(pendingReads.count, 1)
        await gate.release(); await f.service.waitForRecentRestoration()
        let allReads = await reads.ids
        let files = try f.core.sourceFileSnapshots(fileId: nil)
        XCTAssertEqual(allReads, [try XCTUnwrap(files.first { $0.relativePath == "small.txt" }?.id)])
        XCTAssertNotNil(files.first { $0.relativePath == "small.txt" }?.bookId)
        XCTAssertNil(files.first { $0.relativePath == "large.txt" }?.bookId)
        XCTAssertNil(files.first { $0.relativePath == "unrelated.txt" }?.bookId)
        // These are local files with injected cloud metadata: admission and real
        // prepare are covered, not the system's network download itself.
    }

    func testLateCompletionRejectsReplacementRemovalRootChangeHideAndCancellation() async throws {
        for mutation in ["replace", "remove", "root", "hide", "background", "encoding", "token", "unsupported"] {
            let text = "Original story A\n"
            let f = try await fixture(["sample.txt": Data(text.utf8)]); defer { f.clean() }
            try await scan(f)
            let key = sha(text)
            try await position(f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)))
            let entered = expectation(description: "prepared but not linked: " + mutation), gate = RestorationGate(entered)
            await f.service.restorationFixture(active: true, beforeCommit: { await gate.wait() })
            await f.service.scheduleRecentRestoration()
            await fulfillment(of: [entered], timeout: 5)
            let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
            switch mutation {
            case "replace":
                try Data("Replacement data\n".utf8).write(to: f.directory.appendingPathComponent("sample.txt"))
                try await scan(f)
            case "remove":
                try FileManager.default.removeItem(at: f.directory.appendingPathComponent("sample.txt"))
                try await scan(f)
            case "root":
                let other = f.root.appendingPathComponent("other")
                try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
                try f.core.saveLibraryShelf(id: "builtin", name: "Other", bookmark: other.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), location: "local", builtin: true)
            case "hide": try await f.service.hideRecent(f.core.textIdForSha(sha: key))
            case "encoding": try f.core.setSourceDecoding(fileId: file.id, decoding: "UTF-8")
            case "token": try await position(f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)), time: 999999, token: "new-position")
            case "unsupported": try await f.store.receiveSyncFixture("position", key: key, payload: "{\"v\":2,\"updated\":999999,\"token\":\"future\",\"value\":\"future\"}")
            default: await f.service.pauseImports()
            }
            let before = try await snapshot(f.store)
            // Inspect the old response alone, without a new reconciliation pass.
            // Keep active=true except for the background case: disabling every
            // case here would mask broken root/token/encoding guards.
            await f.service.stopRestorationFixtureFollowUp()
            await gate.release(); await f.service.waitForRecentRestoration()
            XCTAssertNil(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId, mutation)
            let after = try await snapshot(f.store); XCTAssertEqual(before, after, mutation)
            await f.service.restorationFixture(active: false)
        }
    }

    func testForegroundOpenCancelsAdmittedRecoveryWithoutAnOrphan() async throws {
        let text = "Original chapter\nOriginal text for a foreground open.\n"
        let f = try await fixture(["sample.txt": Data(text.utf8)]); defer { f.clean() }
        try await scan(f)
        let key = sha(text)
        try await position(f, key: key, hint: hint("sample.txt", size: UInt64(text.utf8.count)))
        let entered = expectation(description: "background admitted, source not yet read"), gate = RestorationGate(entered)
        await f.service.restorationFixture(active: true, beforeRead: { _ in await gate.wait() })
        await f.service.scheduleRecentRestoration()
        await fulfillment(of: [entered], timeout: 5)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        let before = try await snapshot(f.store)
        let source = SourceFile(id: file.id, shelfID: "builtin", relativePath: file.relativePath)
        try await f.service.prepareSourceFile(source)
        let cancelledBeforeOpen = await f.service.restorationFixtureWasCancelled()
        XCTAssertTrue(cancelledBeforeOpen, "Foreground materialization must cancel recovery before opening a lease")
        let lease = try await f.service.openSourceFile(source)
        try await f.service.waitForImportFinish(lease.id)
        await f.service.stopRestorationFixtureFollowUp()
        await gate.release(); await f.service.waitForRecentRestoration()
        let canonical = try f.core.textIdForSha(sha: key)
        XCTAssertEqual(try f.core.sourceFileSnapshots(fileId: file.id).first?.bookId, canonical)
        let remaining = try f.core.reclaimCompletedImports(retainedBookIds: [lease.id])
        XCTAssertEqual(remaining, [lease.id], "The cancelled background task must not leave an import")
        let after = try await snapshot(f.store); XCTAssertEqual(before, after)
        await f.service.restorationFixture(active: false)
        withExtendedLifetime(lease) {}
    }

    func testRealReadingWritesTheRestoredSourceHint() async throws {
        let text = "第一章 原创\n这是用于编码与真实保存入口的原创合成正文。\n"
        let bytes = Data([0xff, 0xfe]) + Data(text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
        let f = try await fixture(["sample.txt": bytes]); defer { f.clean() }
        try await scan(f)
        let file = try XCTUnwrap(f.core.sourceFileSnapshots(fileId: nil).first)
        try await position(f, key: sha(text), hint: hint("sample.txt", size: UInt64(bytes.count), decoding: "UTF-16LE"))
        await restore(f)
        XCTAssertEqual(try f.core.sourceDecoding(fileId: file.id), "UTF-16LE")
        let lease = try await f.service.openSourceFile(.init(id: file.id, shelfID: "builtin", relativePath: "sample.txt"))
        try await f.service.waitForImportFinish(lease.id)
        try await f.service.writePosition(lease.id, offset: 20)
        let storedValue = try await f.store.value("position/" + sha(text))
        let value = try XCTUnwrap(storedValue)
        let saved = try UserSyncJSON.decode(PositionValue.self, value, as: UserSyncJSON.position)
        XCTAssertEqual(saved.source_hint?.decoding, "UTF-16LE")
        XCTAssertEqual(saved.source_hint?.relative_path, "sample.txt")
        XCTAssertEqual(saved.source_hint?.byte_size, UInt64(bytes.count))
        XCTAssertEqual(saved.offset, 20)
        await f.service.restorationFixture(active: false)
        withExtendedLifetime(lease) {}
    }
}
