import XCTest
import CryptoKit
import SwiftData
import SwiftUI
import UIKit
@testable import Moonread

// Inject independent records into one local actor. This exercises the business
// reduction and out-of-order arrival; it is explicitly not a CloudKit device test.
extension UserDataStore {
    func receiveSyncFixture(_ kind: String, key: String = "sha", id: String = "fixture", mark: String = "m", payload: String) throws {
        switch kind {
        case "position": modelContext.insert(UserPosition(contentKey: key, payload: payload))
        case "value": modelContext.insert(UserValue(key: key, device: id, payload: payload))
        case "mark": modelContext.insert(AnnotationOperation(id: id, contentKey: key, markID: mark, payload: payload))
        case "fact": modelContext.insert(ReadingFact(id: id, contentKey: key, payload: payload))
        case "clear": modelContext.insert(StatisticsClear(payload: payload))
        default: throw ReaderError.InvalidSettings
        }
        try modelContext.save(); invalidateProjection()
    }
    func syncFixturePayloads(_ kind: String, key: String? = nil) throws -> [String] {
        switch kind {
        case "position": return try modelContext.fetch(FetchDescriptor<UserPosition>()).filter { key == nil || $0.contentKey == key }.map(\.payload).sorted()
        case "value": return try modelContext.fetch(FetchDescriptor<UserValue>()).filter { key == nil || $0.key == key }.map(\.payload).sorted()
        case "mark": return try modelContext.fetch(FetchDescriptor<AnnotationOperation>()).filter { key == nil || $0.contentKey == key }.map(\.payload).sorted()
        case "fact": return try modelContext.fetch(FetchDescriptor<ReadingFact>()).filter { key == nil || $0.contentKey == key }.map(\.payload).sorted()
        case "clear": return try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload).sorted()
        default: return []
        }
    }
    func receiveFixture(key: String, mark: String, candidate: AnnotationCandidate) throws {
        let payload = String(decoding: try JSONEncoder().encode(candidate), as: UTF8.self)
        modelContext.insert(AnnotationOperation(id: candidate.id, contentKey: key, markID: mark, payload: payload))
        try modelContext.save()
    }
    func writerIsOnMainThread() -> Bool { Thread.isMainThread }
    func fixtureRecordCount() throws -> Int { try modelContext.fetchCount(FetchDescriptor<AnnotationOperation>()) }
}
final class UserDataTests: XCTestCase {
    private func store() throws -> UserDataStore {
        let config = ModelConfiguration(schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return UserDataStore(modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
    }
    private func content(_ note: String, start: UInt64 = 0, end: UInt64 = 9) -> AnnotationContent {
        AnnotationContent(start: start, end: end, excerpt: "正文 \(start)…\(end)", note: note)
    }
    private func candidate(_ id: String, parents: Set<String> = [], content: AnnotationContent?) -> AnnotationCandidate {
        AnnotationCandidate(id: id, ancestors: parents, content: content, created: 1, bookmark: false)
    }
    func testThreeConcurrentWholeEditsAndRangeOnlyConflictsResolveToOneResult() async throws {
        let store = try store(), key = String(repeating: "a", count: 64)
        let initial = candidate("base", content: content(""))
        let a = candidate("a", parents: ["base"], content: content("", start: 0, end: 12))
        let b = candidate("b", parents: ["base"], content: content("", start: 3, end: 15))
        let c = candidate("c", parents: ["base"], content: content("third", start: 0, end: 9))
        for value in [c, initial, a, b, a] { try await store.receiveFixture(key: key, mark: "mark", candidate: value) }
        let heads = try await store.candidates(key: key)["mark"] ?? []
        XCTAssertEqual(Set(heads.map(\.id)), ["a", "b", "c"])
        XCTAssertTrue(AnnotationReduction.conflicts(heads))
        let final = content("manual result", start: 0, end: 15)
        try await store.resolve(key: key, id: "mark", expected: heads, content: final)
        let resolved = try await store.candidates(key: key)["mark"] ?? []
        XCTAssertEqual(resolved.count, 1); XCTAssertEqual(resolved.first?.content, final)
        let recordCount = try await store.fixtureRecordCount()
        XCTAssertEqual(recordCount, 1)
        // A late old record cannot resurrect content that the resolution consumed.
        try await store.receiveFixture(key: key, mark: "mark", candidate: b)
        let late = try await store.candidates(key: key)["mark"] ?? []
        XCTAssertEqual(late.count, 1); XCTAssertEqual(late.first?.content, final)
    }
    func testOldBaselineDeleteConflictsButDeleteBasedOnNewEditWins() async throws {
        let store = try store(), key = String(repeating: "b", count: 64)
        let base = candidate("base", content: content("old"))
        let edit = candidate("edit", parents: ["base"], content: content("new"))
        let deletion = candidate("delete", parents: ["base"], content: nil)
        for value in [edit, deletion, base] { try await store.receiveFixture(key: key, mark: "mark", candidate: value) }
        let heads = try await store.candidates(key: key)["mark"] ?? []
        XCTAssertTrue(AnnotationReduction.conflicts(heads)); XCTAssertEqual(heads.count, 2)
        try await store.resolve(key: key, id: "mark", expected: heads, content: edit.content)
        let newest = try await store.candidates(key: key)["mark"] ?? []
        try await store.changeDeletion("mark", baseline: newest, deleted: true, restoring: nil)
        let deleted = try await store.candidates(key: key)["mark"] ?? []
        XCTAssertFalse(AnnotationReduction.conflicts(deleted)); XCTAssertEqual(deleted.count, 1)
        XCTAssertNil(deleted.first?.content)
    }
    func testIdenticalEditsAreNotConflictAndStaleResolutionCannotEatNewCandidate() async throws {
        let store = try store(), key = "key", same = content("same")
        let a = candidate("a", parents: ["base"], content: same), b = candidate("b", parents: ["base"], content: same)
        for value in [a, b] { try await store.receiveFixture(key: key, mark: "m", candidate: value) }
        let observed = try await store.candidates(key: key)["m"] ?? []
        XCTAssertFalse(AnnotationReduction.conflicts(observed))
        try await store.receiveFixture(key: key, mark: "m", candidate: candidate("c", parents: ["base"], content: content("new")))
        do { try await store.resolve(key: key, id: "m", expected: observed, content: same); XCTFail("stale resolution") }
        catch is UserDataConflict { }
        let remaining = try await store.candidates(key: key)["m"] ?? []
        XCTAssertEqual(remaining.count, 3)
    }
    func testUndoBasedOnDeleteRemainsConcurrentWithOfflineEdit() async throws {
        let store = try store(), old = content("old"), key = "key"
        let base = candidate("base", content: old)
        try await store.receiveFixture(key: key, mark: "m", candidate: base)
        try await store.changeDeletion("m", baseline: [base], deleted: true, restoring: nil)
        let deletion = try await store.candidates(key: key)["m"] ?? []
        try await store.receiveFixture(key: key, mark: "m", candidate: candidate("remote", parents: ["base"], content: content("remote")))
        try await store.changeDeletion("m", baseline: deletion, deleted: false, restoring: old)
        let result = try await store.candidates(key: key)["m"] ?? []
        XCTAssertEqual(result.count, 2); XCTAssertTrue(AnnotationReduction.conflicts(result))
    }
    func testExternalCoverAndAnnotationsPersistAcrossReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = ModelConfiguration(schema: UserDataStore.schema, url: root.appendingPathComponent("users.store"), cloudKitDatabase: .none)
        let bytes = Data((0..<400_000).map { UInt8($0 % 251) })
        do {
            let store = UserDataStore(modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
            try await store.saveCover(id: "cover", bytes: bytes)
            try await store.receiveFixture(key: "sha", mark: "m", candidate: candidate("one", content: content("saved")))
        }
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])?.allObjects as? [URL]) ?? []
        let external = files.filter { !$0.lastPathComponent.hasPrefix("users.store") && (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) == bytes.count }
        XCTAssertFalse(external.isEmpty, "The large cover is persisted as an adjacent binary attachment")
        let reopened = UserDataStore(modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config]))
        let restored = try await reopened.cover("cover")
        XCTAssertEqual(restored, bytes)
        let heads = try await reopened.candidates(key: "sha")["m"] ?? []
        XCTAssertEqual(heads.first?.content?.note, "saved")
        let missing = try await reopened.cover("not-downloaded")
        XCTAssertNil(missing)
    }
    func testFactsRetryOverlapPauseAndClearThenLateArrival() async throws {
        let store = try store()
        func fact(_ id: String, start: Int64, session: String = "s") throws -> (String, String, String) {
            let value: [String: Any] = ["content_key": "sha", "title": "Book", "device": id,
                "slice": ["id": id, "session_id": session, "visit_id": id, "book_id": "local", "started_ms": start,
                    "ended_ms": start + 15_000, "local_day": 20_000, "utc_offset_seconds": 0, "preview": false, "exposures": []]]
            return (id, "sha", String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
        }
        let a = try fact("a", start: 1), b = try fact("b", start: 1)
        try await store.saveFacts([a, b, a], generation: 0, current: 0, enabled: true)
        let json = try await store.projection(generation: 0, enabled: true, includeFacts: true)
        let facts = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])["facts"] as! [[String: Any]]
        XCTAssertEqual(facts.count, 2, "Independent overlapping devices both contribute; retry contributes once")
        try await store.clear(book: "sha", session: "s")
        try await store.saveFacts([try fact("offline", start: 1)], generation: 0, current: 0, enabled: true)
        try await store.saveFacts([try fact("paused", start: Int64.max - 15_001)], generation: 0, current: 1, enabled: true)
        let clearedJSON = try await store.projection(generation: 1, enabled: true, includeFacts: true)
        let cleared = (try JSONSerialization.jsonObject(with: Data(clearedJSON.utf8)) as! [String: Any])["facts"] as! [Any]
        XCTAssertTrue(cleared.isEmpty)
    }
    func testDuplicateLogicalValueCreationAndDevicePositionTiesAreDeterministic() async throws {
        let store = try store()
        try await store.put("metadata/sha/author", value: "\"First\"", device: "a")
        try await store.put("metadata/sha/author", value: "\"Second\"", device: "b")
        let author = try await store.value("metadata/sha/author")
        XCTAssertEqual(author, "\"Second\"")
    }
    func testMergedMarksAndOfflineEditResolveInTheSameBundle() async throws {
        let store = try store(), key = "sha"
        let first = candidate("base-a", content: content("first", start: 0, end: 9))
        let second = candidate("base-b", content: content("second", start: 12, end: 21))
        try await store.receiveFixture(key: key, mark: "a", candidate: first)
        try await store.receiveFixture(key: key, mark: "b", candidate: second)
        let edit = AnnotationEdit(id: "a", bookId: "book", startUtf8: 0, endUtf8: 21, excerpt: "combined", note: "first\n\nsecond", marks: [], baselines: ["a": [first], "b": [second]])
        _ = try await store.saveAnnotation(key: key, edit: edit, content: content("first\n\nsecond", start: 0, end: 21))
        try await store.receiveFixture(key: key, mark: "b", candidate: candidate("offline-b", parents: ["base-b"], content: content("offline", start: 12, end: 24)))
        let bundle = try await store.editingBundle(key: key, edit: edit)
        XCTAssertEqual(Set(bundle.keys), ["a", "b"])
        let choices = bundle.values.flatMap { $0 }.filter { $0.mergedInto == nil }
        XCTAssertEqual(choices.count, 2)
        try await store.resolveBundle(key: key, id: "a", expected: bundle, content: content("chosen", start: 0, end: 24), edit: edit)
        let after = try await store.editingBundle(key: key, edit: edit)
        XCTAssertFalse(after.values.contains(where: AnnotationReduction.conflicts))
        let groups = try await store.candidates(key: key)
        XCTAssertEqual(groups.values.flatMap { $0 }.filter { $0.content != nil }.count, 1)
    }
    func testPendingTransferIsIdempotentAndDoesNotReviveClearedFacts() async throws {
        let pending = try store(), formal = try store()
        let baseline = candidate("operation", content: content("pending note"))
        try await pending.receiveFixture(key: "pending:book", mark: "m", candidate: baseline)
        let pos = PositionValue(content_key: "pending:book", offset: 9)
        try await pending.put("position/pending:book", value: String(decoding: JSONEncoder().encode(pos), as: UTF8.self), device: "device")
        let transfer = try await pending.exportPending(key: "pending:book")
        try await formal.importPending(transfer, from: "pending:book", to: "sha")
        try await formal.importPending(transfer, from: "pending:book", to: "sha")
        let heads = try await formal.candidates(key: "sha")["m"] ?? []
        XCTAssertEqual(heads.count, 1); XCTAssertEqual(heads.first?.content?.note, "pending note")
        try await pending.removePending(key: "pending:book")
        let keys = try await pending.pendingKeys(); XCTAssertTrue(keys.isEmpty)
    }
    @MainActor func testProductionModelActorAndBatchWritesRunAwayFromMainThread() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ReaderService(core: try ReaderCore(dataDirectory: root.path))
        let store = try await service.userStore()
        let main = await store.writerIsOnMainThread(); XCTAssertFalse(main)
        var batch: [String: String] = [:]
        for i in 0..<500 { batch["metadata/sha-\(i)/author"] = "\"Author\"" }
        let start = ContinuousClock.now
        try await store.putValues(batch, device: "device")
        let elapsed = start.duration(to: .now)
        let count = try await store.allValues(prefix: "metadata/").count
        XCTAssertEqual(count, 500)
        print("SwiftData background batch: 500 fields, \(elapsed)")
    }

    func testExistingModelActorSeesACommittedUpdateFromAnotherLocalContext() async throws {
        let first = try store(), second = UserDataStore(modelContainer: first.modelContainer)
        try await first.put("metadata/sha/author", value: "\"Before\"", device: "device")
        let before = try await first.value("metadata/sha/author"); XCTAssertEqual(before, "\"Before\"")
        try await second.put("metadata/sha/author", value: "\"After\"", device: "device")
        let after = try await first.value("metadata/sha/author"); XCTAssertEqual(after, "\"After\"")
    }

    func testMergeRejectsConflictOnLaterMemberAndIncludesRangeChain() async throws {
        let store = try store(), key = "sha"
        let a = candidate("first", content: content("first", start: 0, end: 10))
        let b = candidate("second-a", content: content("A", start: 8, end: 20))
        let other = candidate("second-b", content: content("B", start: 8, end: 20))
        let c = candidate("third", content: content("third", start: 18, end: 30))
        for (mark, value) in [("first", a), ("second", b), ("second", other), ("third", c)] {
            try await store.receiveFixture(key: key, mark: mark, candidate: value)
        }
        let edit = AnnotationEdit(id: "first", bookId: "book", startUtf8: 0, endUtf8: 10, excerpt: "text", note: "first", marks: [], baselines: ["first": [a]])
        let bundle = try await store.editingBundle(key: key, edit: edit)
        XCTAssertEqual(Set(bundle.keys), ["first", "second", "third"])
        do { _ = try await store.saveAnnotation(key: key, edit: edit, content: content("ordinary")); XCTFail("Unresolved later member") }
        catch is UserDataConflict { }
        var fullEdit = edit; fullEdit.baselines = bundle
        do { _ = try await store.saveAnnotation(key: key, edit: fullEdit, content: content("ordinary")); XCTFail("Known conflicts require explicit resolution") }
        catch is UserDataConflict { }
        let untouched = try await store.candidates(key: key)
        XCTAssertEqual(Set(untouched["second", default: []].map(\.id)), ["second-a", "second-b"])
        try await store.resolveBundle(key: key, id: edit.id, expected: bundle, content: content("first\nA\nB\nthird\nmanual", start: 0, end: 30), edit: edit)
        let result = try await store.candidates(key: key).values.flatMap { $0 }.compactMap(\.content)
        XCTAssertEqual(result.count, 1); XCTAssertTrue(result[0].note.contains("B"))
    }
    func testResolutionRejectsNewMemberAndNewCandidateDuringEditing() async throws {
        let store = try store(), key = "sha"
        let a = candidate("a", content: content("A", start: 0, end: 10))
        let b = candidate("b", content: content("B", start: 0, end: 10))
        for value in [a, b] { try await store.receiveFixture(key: key, mark: "m", candidate: value) }
        let edit = AnnotationEdit(id: "m", bookId: "book", startUtf8: 0, endUtf8: 10, excerpt: "", note: "", marks: [], baselines: ["m": [a, b]])
        let initial = try await store.editingBundle(key: key, edit: edit)
        try await store.receiveFixture(key: key, mark: "new", candidate: candidate("new-member", content: content("new", start: 9, end: 18)))
        do { try await store.resolveBundle(key: key, id: "m", expected: initial, content: a.content, edit: edit); XCTFail("Missing member") }
        catch is UserDataConflict { }
        let next = try await store.editingBundle(key: key, edit: edit)
        try await store.receiveFixture(key: key, mark: "m", candidate: candidate("c", content: content("C")))
        do { try await store.resolveBundle(key: key, id: "m", expected: next, content: a.content, edit: edit); XCTFail("Missing candidate") }
        catch is UserDataConflict { }
        let remaining = try await store.candidates(key: key)
        XCTAssertEqual(remaining["m"]?.count, 3); XCTAssertEqual(remaining["new"]?.count, 1)
    }
    @MainActor private func editorFixture() async throws -> (URL, ReaderService, BookInfo, UserDataStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("book.txt")
        try String(repeating: "0123456789", count: 20).write(to: file, atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "Fixture")
        let formal = try store(), pending = try store()
        let service = ReaderService(core: core, sourceDefaultsSuite: "Review-\(root.lastPathComponent)", userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
        return (root, service, try await service.book(book.id), formal)
    }
    @MainActor func testEditorLoadsEntireMergeAndInvalidatesChoiceOnRemoteArrival() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: "Review-\(root.lastPathComponent)")?.removePersistentDomain(forName: "Review-\(root.lastPathComponent)") }
        let a = candidate("a", content: content("first", start: 0, end: 10))
        let b = candidate("b", content: content("A", start: 8, end: 20))
        let c = candidate("c", content: content("B", start: 8, end: 20))
        let d = candidate("d", content: content("third", start: 18, end: 30))
        for (mark, value) in [("a", a), ("b", b), ("b", c), ("c", d)] { try await store.receiveFixture(key: book.contentSha256, mark: mark, candidate: value) }
        let edit = try await service.prepareAnnotation(book.id, start: 0, end: 2)
        XCTAssertEqual(Set(edit.baselines.keys), ["a", "b", "c"])
        let model = NoteEditorModel(edit: edit, service: service)
        await model.loadConflicts(); XCTAssertEqual(model.conflicts.count, 4)
        await model.keepBoth(); XCTAssertTrue(model.text.contains("A")); XCTAssertTrue(model.text.contains("B"))
        try await store.receiveFixture(key: book.contentSha256, mark: "b", candidate: candidate("late", content: content("late", start: 8, end: 20)))
        await model.loadConflicts(); XCTAssertFalse(model.conflictChoice); XCTAssertEqual(model.conflicts.count, 5)
        let unresolved = await model.commit(); XCTAssertFalse(unresolved)
        await model.keepBoth(); model.text += "\nmanual"
        let saved = await model.commit(); XCTAssertTrue(saved)
        let results = try await store.candidates(key: book.contentSha256).values.flatMap { $0 }.compactMap(\.content)
        XCTAssertEqual(results.count, 1); XCTAssertTrue(results[0].note.contains("late")); XCTAssertTrue(results[0].note.contains("manual"))
        let reopened = try await service.prepareAnnotation(book.id, start: 0, end: 2)
        _ = try await service.saveNote(reopened, text: "edited after merge")
        let subsequent = try await store.candidates(key: book.contentSha256).values.flatMap { $0 }.compactMap(\.content)
        XCTAssertEqual(subsequent.count, 1); XCTAssertEqual(subsequent[0].note, "edited after merge")
    }
    @MainActor func testDeleteChoiceCloseReopenKeepAndComplete() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root); UserDefaults(suiteName: "Review-\(root.lastPathComponent)")?.removePersistentDomain(forName: "Review-\(root.lastPathComponent)") }
        let live = candidate("live", content: content("retained")), deletion = candidate("delete", content: nil)
        for value in [live, deletion] { try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: value) }
        let edit = try await service.prepareAnnotation(book.id, start: 0, end: 2)
        let model = NoteEditorModel(edit: edit, service: service)
        await model.loadConflicts(); model.choose(deletion)
        XCTAssertTrue(model.deleteChoice); XCTAssertEqual(model.text, "")
        let afterClose = try await store.candidates(key: book.contentSha256)["m"] ?? []
        XCTAssertEqual(afterClose.count, 2)
        let reopened = NoteEditorModel(edit: try await service.prepareAnnotation(book.id, start: 0, end: 2), service: service)
        await reopened.loadConflicts(); XCTAssertFalse(reopened.deleteChoice); XCTAssertFalse(reopened.conflictChoice)
        reopened.choose(live); reopened.text = "manual kept"
        let kept = await reopened.commit(); XCTAssertTrue(kept)
        let keptHeads = try await store.candidates(key: book.contentSha256)["m"] ?? []
        XCTAssertEqual(keptHeads.first?.content?.note, "manual kept")
        try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: candidate("delete-again", content: nil))
        let final = NoteEditorModel(edit: try await service.prepareAnnotation(book.id, start: 0, end: 2), service: service)
        await final.loadConflicts(); final.choose(candidate("delete-again", content: nil))
        let removed = await final.commit(); XCTAssertTrue(removed)
        let deleted = try await store.candidates(key: book.contentSha256)["m"] ?? []
        XCTAssertEqual(deleted.count, 1); XCTAssertNil(deleted.first?.content)
    }
    func testFailedFormalAndPendingInitializationRetryAndShareConcurrentWaiters() async throws {
        for pending in [false, true] {
            let probe = BootstrapProbe(store: try store())
            let service = ReaderService(userStoreFactory: { name, cloud in try await probe.make(name, cloud: cloud) })
            let first = Task { try await service.userStore(pending: pending) }
            await probe.waitUntilStarted()
            await probe.failFirst()
            if case .success = await first.result { XCTFail("Expected controlled failure") }
            async let second = service.userStore(pending: pending)
            async let third = service.userStore(pending: pending)
            let (retry, reused) = try await (second, third)
            XCTAssertTrue(retry === reused)
            let count = await probe.count; XCTAssertEqual(count, 2)
        }
    }
    func testOldFailureCannotClearReplacementOrRevertCloudConfiguration() async throws {
        let probe = BootstrapProbe(store: try store())
        let service = ReaderService(sourceDefaultsSuite: "Bootstrap-\(UUID().uuidString)", userStoreFactory: { name, cloud in try await probe.make(name, cloud: cloud) })
        let old = Task { try await service.configureUserCloud(true, account: "fixture") }
        await probe.waitUntilStarted()
        try await service.configureUserCloud(false, account: nil)
        try await service.configureUserCloud(true, account: "fixture")
        let replacement = try await service.userStore()
        await probe.failFirst()
        if case .success = await old.result { XCTFail("Expected old initialization failure") }
        let after = try await service.userStore()
        XCTAssertTrue(after === replacement)
        let cloud = await service.userCloudEnabled; XCTAssertTrue(cloud)
        let count = await probe.count; XCTAssertEqual(count, 3)
    }
    func testPendingOldFailureCannotClearReplacementInitialization() async throws {
        let probe = BootstrapProbe(store: try store())
        let service = ReaderService(userStoreFactory: { name, cloud in try await probe.make(name, cloud: cloud) })
        let old = Task { try await service.userStore(pending: true) }
        await probe.waitUntilStarted()
        await service.invalidatePendingFixture()
        let replacement = try await service.userStore(pending: true)
        await probe.failFirst()
        if case .success = await old.result { XCTFail("Expected old failure") }
        let after = try await service.userStore(pending: true)
        XCTAssertTrue(after === replacement)
        let count = await probe.count; XCTAssertEqual(count, 2)
    }

    @MainActor func testCancelledEditingDiscardsNewContentAndPreservesExistingTextAndRange() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fresh = try await service.prepareAnnotation(book.id, start: 0, end: 8)
        var session: NoteEditorModel? = NoteEditorModel(edit: fresh, service: service)
        session?.text = "unconfirmed new comment"; session?.edit.endUtf8 = 18
        session = nil // X and swipe simply release the editing session.
        let afterNew = try await store.candidates(key: book.contentSha256)
        XCTAssertTrue(afterNew.isEmpty)
        let empty = try await service.prepareAnnotation(book.id, start: 0, end: 8)
        XCTAssertEqual(empty.note, ""); XCTAssertEqual(empty.endUtf8, 8)
        let saved = try await service.saveNote(empty, text: "confirmed")
        session = NoteEditorModel(edit: try await service.prepareAnnotation(book.id, start: 0, end: 8), service: service)
        session?.text = "unconfirmed edit"; session?.edit.endUtf8 = 28
        session = nil
        let formal = try await service.mark(saved.id)
        XCTAssertEqual(formal.note, "confirmed"); XCTAssertEqual(formal.endUtf8, 8)
        let reopened = try await service.prepareAnnotation(book.id, start: 0, end: 8)
        XCTAssertEqual(reopened.note, "confirmed"); XCTAssertEqual(reopened.endUtf8, 8)
        let highlighted = try await service.annotate(book.id, start: 40, end: 48)
        let keptHighlight = try await service.mark(highlighted.id)
        XCTAssertEqual(keptHighlight.note, ""); XCTAssertEqual(keptHighlight.endUtf8, 48)
    }
    func testBusinessQueriesAlwaysIncludeCorrectionsMetadataPositionsAndFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "第一章 月\n\n甲乙丙丁\n第二章 星\n\n再次阅读\n"
        let file = root.appendingPathComponent("book.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
        let book = try core.importBook(filePath: file.path, title: "Book")
        let formal = try store(), pending = try store()
        let service = ReaderService(core: core, sourceDefaultsSuite: "Query-\(root.lastPathComponent)", userStoreFactory: { name, _ in name == "pending-users.store" ? pending : formal })
        let before = try await service.details(bookID: book.id).metadata
        var metadata = before; metadata.author = "作者"
        try await service.saveMetadata(base: before, edited: metadata)
        let details = try await service.details(bookID: book.id)
        XCTAssertEqual(details.metadata.author, "作者")
        try await service.correctChapter(book.id, offset: 0, title: "重命名", level: 1)
        let directChapter = try await service.chapter(bookID: book.id, offset: 0)
        XCTAssertEqual(directChapter?.title, "重命名")
        let firstSearch = try await service.search(book.id, query: "甲", regex: false, caseSensitive: true)
        XCTAssertEqual(try firstSearch.nextBatch().hits.first?.chapter, "重命名")
        let added = UInt64(text.prefix { $0 != "甲" }.utf8.count)
        let second = UInt64(text.distance(from: text.startIndex, to: text.range(of: "第二章")!.lowerBound))
        let secondOffset = UInt64(text.prefix(Int(second)).utf8.count)
        try await service.correctChapter(book.id, offset: added, title: "新增", level: 1)
        try await service.correctChapter(book.id, offset: secondOffset, title: "第二章 星", level: 1, excluded: true)
        let adjacent = try await service.adjacentChapter(book.id, offset: 0, forward: true)
        XCTAssertEqual(adjacent?.startUtf8, added)
        let effectiveFrame = try await service.frame(book.id, offset: secondOffset)
        XCTAssertEqual(effectiveFrame.paragraphs.first { $0.startUtf8 == secondOffset }?.kind, .body)
        let correctedDetails = try await service.details(bookID: book.id)
        XCTAssertEqual(correctedDetails.chapterCount, 2)
        let excludedSearch = try await service.search(book.id, query: "阅读", regex: false, caseSensitive: true)
        XCTAssertEqual(try excludedSearch.nextBatch().hits.first?.chapter, "新增")
        let location = try await service.location(book.id, percentage: 100)
        XCTAssertEqual(location.chapter?.title, "新增")
        try await service.savePosition(bookID: book.id, offset: added)
        let frame = try await service.frame(book.id, offset: added)
        XCTAssertEqual(frame.snapshot.book.positionUtf8, added)
        XCTAssertEqual(try core.querySnapshot(json: "{}").bookInfo(bookId: book.id).positionUtf8, 0, "Business reads never mutate a shared projection")
        try await service.restoreChapterCorrections(book.id)
        let restored = try await service.search(book.id, query: "阅读", regex: false, caseSensitive: true)
        XCTAssertEqual(try restored.nextBatch().hits.first?.chapter, "第二章 星")
        let clock = ReadingClock(bookId: book.id)
        var moment = ReadingMoment(monotonicMs: 0, unixMs: 0, utcOffsetSeconds: 0, readable: true, interaction: true, preview: false, startUtf8: added, endUtf8: added + 3)
        _ = clock.update(moment: moment)
        moment.monotonicMs = 5000; moment.unixMs = 5000; moment.readable = false
        try await service.saveReading(clock.update(moment: moment), generation: await service.statisticsPreferences().generation)
        let overview = try await service.statistics(first: 0, last: 0, book: nil)
        XCTAssertEqual(overview.books.first?.durationMs, 5000)
    }
    @MainActor func testCoverAttachmentSaveWakesSamePresentationAndHostedShelfView() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).pngData { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 120))
        }
        let cover = try await service.makeCover(png)
        let directory = await service.dataDirectoryName
        let draft = FileManager.default.temporaryDirectory.appendingPathComponent("\(directory)-CoverDrafts").appendingPathComponent("\(cover.id)-\(cover.sha256).\(cover.extension)")
        let bytes = try Data(contentsOf: draft)
        await service.discardCoverDraft(cover)
        try await store.put("metadata/\(book.contentSha256)/cover", value: String(decoding: JSONSerialization.data(withJSONObject: ["id": cover.id, "sha256": cover.sha256, "extension": cover.extension, "width": cover.width, "height": cover.height]), as: UTF8.self), device: "remote")
        let loader = CoverImageLoader { asset, pixels in try await service.coverImage(asset, pixels: pixels) }
        let subscriber = loader.subscribe(cover, pixels: 600)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LibraryBookCover(title: "文字封面", cover: cover, coverLoader: loader).frame(width: 150, height: 210))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        let waiting = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in subscriber.presentation.phase == .waiting }, object: nil)
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertNil(subscriber.presentation.image)
        let before = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let beforeAttachment = XCTAttachment(image: before); beforeAttachment.name = "cover-metadata-before-attachment"; beforeAttachment.lifetime = .keepAlways; add(beforeAttachment)
        // Real SwiftData save notification, no synthetic cloud notification.
        try await store.saveCover(id: cover.id, bytes: bytes)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in subscriber.presentation.phase == .ready }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotNil(subscriber.presentation.image)
        let displayed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            return frame.pngData() != before.pngData()
        }, object: nil)
        await fulfillment(of: [displayed], timeout: 5)
        let after = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        let afterAttachment = XCTAttachment(image: after); afterAttachment.name = "same-cover-view-after-attachment"; afterAttachment.lifetime = .keepAlways; add(afterAttachment)
        XCTAssertNotEqual(before.pngData(), after.pngData())
    }
    @MainActor func testCoverRequestsCoalesceAndCancelledOldLoadCannotPublish() async throws {
        let old = BookCoverAsset(id: UUID().uuidString, sha256: String(repeating: "a", count: 64), extension: "png", width: 1, height: 1)
        let new = BookCoverAsset(id: old.id, sha256: String(repeating: "b", count: 64), extension: "png", width: 1, height: 1)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        let probe = CoverLoadProbe(image: image)
        let loader = CoverImageLoader { cover, _ in try await probe.load(cover.id, delayed: cover.sha256 == old.sha256) }
        var one: CoverSubscription? = loader.subscribe(old, pixels: 320)
        var two: CoverSubscription? = loader.subscribe(old, pixels: 320)
        XCTAssertTrue(one?.presentation === two?.presentation)
        await probe.waitUntilStarted()
        let oldPresentation = try XCTUnwrap(one?.presentation)
        let calls = await probe.calls; XCTAssertEqual(calls, 1)
        one = nil; two = nil
        await Task.yield()
        let replacement = loader.subscribe(new, pixels: 320)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in replacement.presentation.phase == .ready }, object: nil)
        await fulfillment(of: [ready], timeout: 5)
        await probe.release()
        await Task.yield()
        XCTAssertNil(oldPresentation.image)
        XCTAssertTrue(replacement.presentation.image === image)
    }

}

private actor BootstrapProbe {
    let store: UserDataStore
    var count = 0
    private var first: CheckedContinuation<UserDataStore, Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    init(store: UserDataStore) { self.store = store }
    func make(_ name: String, cloud: Bool) async throws -> UserDataStore {
        count += 1
        if count == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                first = continuation
                for waiter in started { waiter.resume() }; started = []
            }
        }
        return store
    }
    func waitUntilStarted() async {
        if first != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func failFirst() { first?.resume(throwing: CocoaError(.fileReadUnknown)); first = nil }
}
private extension ReaderService {
    func invalidatePendingFixture() { pendingUserStoreTask = nil }
}

private actor CoverLoadProbe {
    let image: UIImage
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var calls = 0
    init(image: UIImage) { self.image = image }
    func load(_ id: String, delayed: Bool) async throws -> UIImage? {
        calls += 1
        if !delayed { return image }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            for waiter in waiters { waiter.resume() }; waiters = []
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { continuation?.resume(returning: image); continuation = nil }
}

// Policy tests with an injected identity and local in-memory store, not a CloudKit
// account-switch or two-device test. No network requests are made by this fixture.
private actor SyncAccountProbe {
    var accounts: [String?] = ["A"]
    var configurations: [Bool] = []
    var failNextCloud = false
    let store: UserDataStore
    init(_ store: UserDataStore) { self.store = store }
    func set(_ values: [String?]) { accounts = values }
    func identity() -> String? { accounts.count > 1 ? accounts.removeFirst() : accounts.first ?? nil }
    func fail() { failNextCloud = true }
    func make(_ cloud: Bool) throws -> UserDataStore {
        configurations.append(cloud)
        if cloud && failNextCloud { failNextCloud = false; throw CocoaError(.fileWriteUnknown) }
        return store
    }
}
final class CloudAccountTests: XCTestCase {
    private func fixture(available: Bool = true) throws -> (ReaderService, CloudSyncCoordinator, SyncAccountProbe, String) {
        let suite = "CloudAccount-\(UUID().uuidString)"
        let config = ModelConfiguration(schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let probe = SyncAccountProbe(UserDataStore(modelContainer: try ModelContainer(for: UserDataStore.schema, configurations: [config])))
        let service = ReaderService(sourceDefaultsSuite: suite, userStoreFactory: { _, cloud in try await probe.make(cloud) })
        let coordinator = CloudSyncCoordinator(service: service, available: available, observeEvents: false, account: { await probe.identity() })
        return (service, coordinator, probe, suite)
    }
    func testUnavailableSignOutAndExplicitOffPreserveIntentCorrectly() async throws {
        let (service, coordinator, probe, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await coordinator.setEnabled(true)
        var status = await coordinator.currentStatus(); XCTAssertTrue(status.requested); XCTAssertTrue(status.enabled)
        await probe.set([nil]); await coordinator.identityChanged()
        status = await coordinator.currentStatus(); XCTAssertTrue(status.requested); XCTAssertFalse(status.enabled)
        let requested = await service.cloudSyncRequested(); XCTAssertTrue(requested)
        await probe.set(["A"]); await coordinator.resume()
        status = await coordinator.currentStatus(); XCTAssertTrue(status.enabled)
        await coordinator.setEnabled(false); await coordinator.resume()
        status = await coordinator.currentStatus(); XCTAssertFalse(status.requested); XCTAssertFalse(status.enabled)
        let (unsupportedService, unsupported, _, unsupportedSuite) = try fixture(available: false)
        defer { UserDefaults(suiteName: unsupportedSuite)?.removePersistentDomain(forName: unsupportedSuite) }
        await unsupported.setEnabled(true)
        let unsupportedIntent = await unsupportedService.cloudSyncRequested(); XCTAssertTrue(unsupportedIntent)
        let unsupportedStatus = await unsupported.currentStatus(); XCTAssertFalse(unsupportedStatus.enabled)
    }
    @MainActor func testDifferentAccountCancelRepeatedRefreshAndConsent() async throws {
        let (service, coordinator, probe, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await coordinator.setEnabled(true)
        await probe.set(["B"]); await coordinator.identityChanged()
        let cloud = CloudStore(coordinator: coordinator)
        await cloud.updateStatus()
        XCTAssertTrue(cloud.status.requested); XCTAssertFalse(cloud.status.enabled)
        XCTAssertEqual(cloud.status.accountToConfirm, "B"); XCTAssertNil(cloud.confirmationAccount)
        cloud.requestConfirmation(); XCTAssertEqual(cloud.confirmationAccount, "B")
        cloud.confirmationAccount = nil // Cancel does not touch persistent intent or configuration.
        await coordinator.resume(); await cloud.updateStatus()
        XCTAssertNil(cloud.confirmationAccount)
        let before = await probe.configurations; XCTAssertEqual(before.filter { $0 }.count, 1)
        let ownerBefore = await service.userCloudOwner(); XCTAssertEqual(ownerBefore, "A")
        await coordinator.confirmAccount("B")
        let status = await coordinator.currentStatus(); XCTAssertTrue(status.enabled); XCTAssertNil(status.accountToConfirm)
        let owner = await service.userCloudOwner(); XCTAssertEqual(owner, "B")
    }
    @MainActor func testPausedSettingsAndAccountConfirmationRender() async throws {
        let (_, coordinator, probe, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await coordinator.setEnabled(true)
        await probe.set(["B"]); await coordinator.identityChanged()
        let cloud = CloudStore(coordinator: coordinator)
        await cloud.updateStatus()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { CloudSettingsView() }
            .environment(cloud).environment(\.locale, Locale(identifier: "en"))
            .environment(\.dynamicTypeSize, .xxxLarge))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.layoutIfNeeded()
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image); attachment.name = name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        capture("paused-cloud-settings-english-large-text")
        cloud.requestConfirmation()
        let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in host.presentedViewController != nil }, object: nil)
        await fulfillment(of: [presented], timeout: 5)
        capture("specific-account-confirmation")
        XCTAssertTrue(cloud.status.requested); XCTAssertFalse(cloud.status.enabled)
    }
    func testStaleConfirmationAndFailedInitializationRetry() async throws {
        let (service, coordinator, probe, suite) = try fixture()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        await probe.fail(); await coordinator.setEnabled(true)
        var status = await coordinator.currentStatus(); XCTAssertTrue(status.requested); XCTAssertFalse(status.enabled)
        await coordinator.resume(); status = await coordinator.currentStatus(); XCTAssertTrue(status.enabled)
        await probe.set(["B"]); await coordinator.identityChanged()
        await probe.set(["B", "C"]); await coordinator.confirmAccount("B")
        status = await coordinator.currentStatus(); XCTAssertFalse(status.enabled); XCTAssertEqual(status.accountToConfirm, "C")
        let ownerBefore = await service.userCloudOwner(); XCTAssertEqual(ownerBefore, "A")
        await probe.fail(); await coordinator.confirmAccount("C")
        status = await coordinator.currentStatus(); XCTAssertTrue(status.requested); XCTAssertFalse(status.enabled)
        let owner = await service.userCloudOwner(); XCTAssertEqual(owner, "C")
        await coordinator.resume(); status = await coordinator.currentStatus(); XCTAssertTrue(status.enabled); XCTAssertNil(status.accountToConfirm)
    }
}

extension UserDataTests {
    @MainActor func testPaletteStorageDoesNotCaptureDevicePreferences() async throws {
        let (root, service, _, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = defaultThemeSnapshot().palettes[0]
        template.name = "Independent"
        let palette = try await service.savePalette(template, creating: true)
        let rows = try await store.allValues(prefix: "palette/")
        let json = try XCTUnwrap(rows["palette/\(palette.id)"])
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(stored["preferences"]); XCTAssertNil(stored["palettes"])
        var preferences = defaultThemeSnapshot().preferences
        preferences.appLight = .palette(id: palette.id)
        let selected = try await service.saveThemes(preferences)
        XCTAssertEqual(selected.preferences.appLight, .palette(id: palette.id))
        let deleted = try await service.deletePalette(palette.id)
        XCTAssertEqual(deleted.preferences.appLight, defaultThemeSnapshot().preferences.appLight)
        XCTAssertFalse(deleted.palettes.contains { $0.id == palette.id })
    }
    private func syncJSON(_ text: String, _ change: (inout [String: Any]) -> Void) throws -> String {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        change(&value)
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func syncPosition(_ key: String, offset: UInt64 = 9, updated: Int64 = 100) throws -> String {
        try UserSyncJSON.encode(StoredValue(updated: updated, token: "v1", value: UserSyncJSON.encode(PositionValue(content_key: key, offset: offset))), envelope: true)
    }
    private func syncFact(_ key: String, id: String = "fact") -> String {
        """
        {"v":1,"content_key":"\(key)","device":"device","title":"Original sample","slice":{"id":"\(id)","session_id":"session","visit_id":"visit","book_id":"book","started_ms":1,"ended_ms":1001,"local_day":20000,"utc_offset_seconds":0,"preview":false,"exposures":[{"start_utf8":0,"end_utf8":9,"duration_ms":1000}]}}
        """
    }
    private static func rejectSync<T: Sendable>(_ operation: @Sendable () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Quarantined data must block this write/read", file: file, line: line) }
        catch is UserSyncCompatibilityError { }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }
    func testSyncV1WritesExplicitNullAndAcceptsOnlyCompleteObjects() async throws {
        let store = try store(), item = candidate("base", content: content("note"))
        try await store.receiveFixture(key: "sha", mark: "m", candidate: item)
        try await store.changeDeletion("m", baseline: [item], deleted: true, restoring: nil)
        let payloads = try await store.syncFixturePayloads("mark")
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(payloads.first).utf8)) as? [String: Any])
        XCTAssertEqual(value["v"] as? Int, 1)
        XCTAssertTrue(value["content"] is NSNull); XCTAssertTrue(value["mergedInto"] is NSNull)
        XCTAssertNotNil(value["relatedMarks"] as? [String])
        try await store.clear(book: nil, session: nil)
        let clears = try await store.syncFixturePayloads("clear")
        let clear = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(clears.first).utf8)) as? [String: Any])
        XCTAssertEqual(clear["v"] as? Int, 1)
        XCTAssertTrue(clear["book"] is NSNull); XCTAssertTrue(clear["session"] is NSNull)
        // Missing version alone means v1. Missing/null/wrong required fields are not defaults.
        let noVersion = try syncJSON(payloads[0]) { $0.removeValue(forKey: "v") }
        let other = try self.store()
        let deleted = try JSONDecoder().decode(AnnotationCandidate.self, from: Data(noVersion.utf8))
        try await other.receiveSyncFixture("mark", id: deleted.id, payload: noVersion)
        let heads = try await other.candidates(key: "sha")
        XCTAssertEqual(heads["m"]?.count, 1); XCTAssertNil(heads["m"]?.first?.content)
        for field in ["content", "ancestors", "relatedMarks", "mergedInto", "created", "bookmark", "id"] {
            let broken = try syncJSON(noVersion) { $0.removeValue(forKey: field) }
            let isolated = try self.store()
            try await isolated.receiveSyncFixture("mark", id: deleted.id, payload: broken)
            let hidden = try await isolated.candidates(key: "sha")
            XCTAssertTrue(hidden.isEmpty, field)
            let retained = try await isolated.syncFixturePayloads("mark")
            XCTAssertEqual(retained, [broken])
        }
    }
    func testSyncPositionsRemainQuarantinedInEitherArrivalOrderAndKeepPrecision() async throws {
        let valid = try syncPosition("sha", offset: 9, updated: 9_007_199_254_740_993)
        let variants = [
            try syncJSON(valid) { $0["v"] = 2 }, try syncJSON(valid) { $0["v"] = true },
            try syncJSON(valid) { $0["v"] = 1.5 }, try syncJSON(valid) { $0["v"] = "1" },
            try syncJSON(valid) { $0["future"] = "must not be dropped" },
            try syncJSON(valid) { $0.removeValue(forKey: "token") },
            try syncJSON(valid) { $0["updated"] = NSNull() },
            try syncJSON(valid) { $0["value"] = "{\"content_key\":\"sha\",\"offset\":null}" },
            try syncJSON(valid) { $0["value"] = "{\"content_key\":\"sha\",\"offset\":1,\"future\":2}" },
            "not-json"
        ]
        for future in variants {
            for reverse in [false, true] {
                let store = try store()
                for payload in reverse ? [future, valid] : [valid, future] { try await store.receiveSyncFixture("position", payload: payload) }
                try await store.importedChanges(keys: ["sha"])
                let before = try await store.syncFixturePayloads("position", key: "sha")
                XCTAssertEqual(before, [valid, future].sorted())
                let replacement = try UserSyncJSON.encode(PositionValue(content_key: "sha", offset: 10))
                await Self.rejectSync { try await store.put("position/sha", value: replacement, device: "offline") }
                let after = try await store.syncFixturePayloads("position", key: "sha")
                XCTAssertEqual(after, before)
                let projection = try await store.projection(generation: 0, enabled: true, includeFacts: false)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
                XCTAssertTrue((json["positions"] as? [Any])?.isEmpty == true)
                XCTAssertEqual(json["unsupportedPositions"] as? [String], ["sha"])
                let notice = try await store.compatibilityNotice(key: "sha")
                XCTAssertNotNil(notice)
                try await store.put("position/other", value: UserSyncJSON.encode(PositionValue(content_key: "other", offset: 8)), device: "device")
            }
        }
        let precise = try store(), offset: UInt64 = 9_007_199_254_740_993
        try await precise.put("position/sha", value: UserSyncJSON.encode(PositionValue(content_key: "sha", offset: offset)), device: "device")
        let storedText = try await precise.value("position/sha")
        let text = try XCTUnwrap(storedText)
        XCTAssertEqual(try JSONDecoder().decode(PositionValue.self, from: Data(text.utf8)).offset, offset)
        let projected = try await precise.projection(generation: 0, enabled: true, includeFacts: false)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projected.utf8)) as? [String: Any])
        let position = try XCTUnwrap((json["positions"] as? [[String: Any]])?.first)
        XCTAssertEqual((position["offset"] as? NSNumber)?.uint64Value, offset)
    }
    func testSyncUnknownAnnotationHeadsBlockCompactionAndAllMutations() async throws {
        let base = candidate("base", content: content("visible before future"))
        var futureHead = candidate("future", parents: ["base"], content: content("future"))
        futureHead.relatedMarks = ["related"]
        let original = try UserSyncJSON.encode(futureHead, envelope: true)
        for future in [try syncJSON(original) { $0["v"] = 2 }, try syncJSON(original) { $0["content"] = ["start": 0,"end":9,"excerpt":"text","note":"note","future":true] }] {
            for reverse in [false, true] {
                let store = try store()
                let known = try UserSyncJSON.encode(base, envelope: true)
                for payload in reverse ? [future, known] : [known, future] {
                    let id = payload == future ? "future" : "base"
                    try await store.receiveSyncFixture("mark", id: id, payload: payload)
                }
                let before = try await store.syncFixturePayloads("mark")
                let groups = try await store.candidates(key: "sha")
                XCTAssertNil(groups["m"])
                let edit = AnnotationEdit(id: "m", bookId: "book", startUtf8: 0, endUtf8: 9, excerpt: "text", note: "", marks: [], baselines: ["m": [base]])
                let replacement = content("new")
                await Self.rejectSync { try await store.saveAnnotation(key: "sha", edit: edit, content: replacement) }
                await Self.rejectSync { try await store.resolve(key: "sha", id: "m", expected: [base], content: replacement) }
                await Self.rejectSync { try await store.applyDeletions([.init(id: "m", key: "sha", baseline: [base], content: replacement, deleted: true)]) }
                await Self.rejectSync { try await store.bookmark(key: "sha", id: "m", content: replacement) }
                let after = try await store.syncFixturePayloads("mark")
                XCTAssertEqual(after, before)
                _ = try await store.ensureBookmark(key: "sha", id: "unrelated", content: replacement)
            }
        }
    }
    func testSyncUnknownClearBlocksItsScopeAndUnknownFactsShowPartialStatistics() async throws {
        let store = try store(), known = syncFact("sha")
        try await store.saveFacts([("fact", "sha", known), ("other-fact", "other", syncFact("other", id: "other-fact"))], generation: 0, current: 0, enabled: true)
        let clear = try UserSyncJSON.encode(ClearValue(book: "sha", session: nil, through: 10_000, ids: []), envelope: true)
        let future = try syncJSON(clear) { $0["v"] = 2 }
        try await store.receiveSyncFixture("clear", payload: future)
        await Self.rejectSync { try await store.projection(generation: 0, enabled: true, includeFacts: true) }
        await Self.rejectSync { try await store.projection(generation: 0, enabled: true, includeFacts: true, statisticsBook: "sha") }
        await Self.rejectSync { try await store.clear(book: "sha", session: nil) }
        let other = try await store.projection(generation: 0, enabled: true, includeFacts: true, statisticsBook: "other")
        XCTAssertTrue(other.contains("other-fact"))
        let retained = try await store.syncFixturePayloads("clear")
        XCTAssertEqual(retained, [future])
        try await store.clear(book: "other", session: nil)
        let malformed = try syncJSON(clear) { $0.removeValue(forKey: "book") }
        try await store.receiveSyncFixture("clear", payload: malformed)
        await Self.rejectSync { try await store.projection(generation: 0, enabled: true, includeFacts: true, statisticsBook: "other") }
        await Self.rejectSync { try await store.clear(book: "other", session: nil) }
        let partial = try self.store()
        let futureFact = try syncJSON(known) { $0["future"] = 1 }
        try await partial.receiveSyncFixture("fact", id: "fact", payload: futureFact)
        try await partial.saveFacts([("known", "sha", syncFact("sha", id: "known"))], generation: 0, current: 0, enabled: true)
        let incomplete = try await partial.statisticsIncomplete(book: "sha")
        XCTAssertTrue(incomplete)
        let visible = try await partial.projection(generation: 0, enabled: true, includeFacts: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(visible.utf8)) as? [String: Any])
        XCTAssertEqual((json["facts"] as? [Any])?.count, 1)
        let facts = try await partial.syncFixturePayloads("fact")
        XCTAssertTrue(facts.contains(futureFact))
    }
    func testSyncPendingQuarantinePreventsTransferAndRemovalAndKeepsUnknownKeys() async throws {
        for kind in ["position", "mark", "fact"] {
            let pending = try store(), formal = try store(), key = "pending:book"
            let position = try syncPosition(key)
            let mark = candidate("operation", content: content("note"))
            let operation = try UserSyncJSON.encode(mark, envelope: true)
            let fact = syncFact(key)
            let raw = kind == "position" ? position : kind == "mark" ? operation : fact
            let future = try syncJSON(raw) { $0["v"] = 2 }
            try await pending.receiveSyncFixture("position", key: key, payload: position)
            try await pending.receiveSyncFixture("mark", key: key, id: "operation", payload: operation)
            try await pending.receiveSyncFixture("fact", key: key, id: "fact", payload: fact)
            try await pending.receiveSyncFixture(kind, key: key, id: kind == "mark" ? "operation" : "fact", payload: future)
            await Self.rejectSync { try await pending.exportPending(key: key) }
            await Self.rejectSync { try await pending.removePending(key: key) }
            let retained = try await pending.syncFixturePayloads(kind, key: key)
            XCTAssertEqual(retained.count, 2)
            XCTAssertTrue(retained.contains(future))
            let transfer = UserDataTransfer(positions: kind == "position" ? [future] : [], operations: kind == "mark" ? [.init(id: "operation", mark: "m", payload: future)] : [], facts: kind == "fact" ? [.init(id: "fact", payload: future)] : [])
            await Self.rejectSync { try await formal.importPending(transfer, from: key, to: "sha") }
            for type in ["position", "mark", "fact"] {
                let empty = try await formal.syncFixturePayloads(type)
                XCTAssertTrue(empty.isEmpty)
            }
        }
        let store = try self.store()
        let unknown = "{\"v\":9000,\"future\":true}"
        try await store.receiveSyncFixture("value", key: "metadata/sha/future", payload: unknown)
        try await store.receiveSyncFixture("value", key: "future/pending:book", payload: unknown)
        try await store.put("metadata/sha/author", value: "\"Original author\"", device: "device")
        let projection = try await store.projection(generation: 0, enabled: true, includeFacts: false)
        XCTAssertFalse(projection.contains("future"))
        try await store.removePending(key: "pending:book")
        let retained = try await store.syncFixturePayloads("value")
        XCTAssertEqual(retained.filter { $0 == unknown }.count, 2)
    }
    @MainActor func testSyncUnknownStatusSurvivesMetadataEditingAndUnsupportedCoverIsRetained() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = "metadata/" + book.contentSha256 + "/status"
        try await store.put(key, value: "\"FutureReadingState\"", device: "remote")
        let initial = try await service.details(bookID: book.id)
        XCTAssertEqual(initial.metadata.status, .other(value: "FutureReadingState"))
        let before = try await store.syncFixturePayloads("value", key: key)
        var edit = initial.metadata; edit.author = "Original author"
        try await service.saveMetadata(base: initial.metadata, edited: edit)
        let after = try await store.syncFixturePayloads("value", key: key)
        XCTAssertEqual(before, after, "Editing another key must not overwrite unsupported status")
        var known = try await service.details(bookID: book.id).metadata
        let base = known; known.status = .reading
        try await service.saveMetadata(base: base, edited: known)
        let changed = try await service.details(bookID: book.id)
        XCTAssertEqual(changed.metadata.status, .reading)
        let bytes = Data("opaque future image".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let cover = BookCoverAsset(id: UUID().uuidString, sha256: hash, extension: "future", width: 300, height: 400)
        try await store.saveCover(id: cover.id, bytes: bytes)
        var metadata = changed.metadata; metadata.cover = cover
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(encodeBookMetadata(value: metadata).utf8)) as? [String: Any])
        let coverJSON = String(decoding: try JSONSerialization.data(withJSONObject: XCTUnwrap(encoded["cover"])), as: UTF8.self)
        try await store.put("metadata/" + book.contentSha256 + "/cover", value: coverJSON, device: "remote")
        let restored = try await service.details(bookID: book.id)
        XCTAssertEqual(restored.metadata.cover, cover)
        let retainedBytes = try await store.cover(cover.id)
        XCTAssertEqual(retainedBytes, bytes)
        let image = try? await service.coverImage(cover, pixels: 200)
        XCTAssertNil(image)
        await Self.rejectSync { try await store.saveCover(id: cover.id, bytes: Data("different".utf8)) }
        let unchanged = try await store.cover(cover.id)
        XCTAssertEqual(unchanged, bytes)
    }

    func testSyncNestedUnknownFieldsAndInvalidTypesAreNotReencodedOrTransferred() async throws {
        let key = "sha", validPosition = try syncPosition(key)
        let cover = "{\"id\":\"cover\",\"sha256\":\"hash\",\"extension\":\"png\",\"width\":300,\"height\":400,\"future\":true}"
        let badCover = try UserSyncJSON.encode(StoredValue(updated: 1, token: "cover", value: cover), envelope: true)
        let chapter = "{\"content_key\":\"sha\",\"offset\":0,\"title\":\"Original chapter\",\"level\":0}"
        let badChapter = try UserSyncJSON.encode(StoredValue(updated: 1, token: "chapter", value: chapter), envelope: true)
        for (recordKey, payload) in [("metadata/sha/cover", badCover), ("chapter/sha/0", badChapter)] {
            let store = try store()
            try await store.receiveSyncFixture("value", key: recordKey, payload: payload)
            let replacement = "null"
            await Self.rejectSync { try await store.put(recordKey, value: replacement, device: "device") }
            let retained = try await store.syncFixturePayloads("value", key: recordKey)
            XCTAssertEqual(retained, [payload])
        }
        let clear = try UserSyncJSON.encode(ClearValue(book: key, session: nil, through: 10, ids: []), envelope: true)
        let variants = [try syncJSON(clear) { $0["through"] = NSNull() }, try syncJSON(clear) { $0["session"] = 1 }, try syncJSON(clear) { $0["future"] = true }]
        for payload in variants {
            let store = try store()
            try await store.receiveSyncFixture("clear", payload: payload)
            await Self.rejectSync { try await store.clear(book: key, session: nil) }
            let retained = try await store.syncFixturePayloads("clear")
            XCTAssertEqual(retained, [payload])
        }
        let fact = syncFact(key)
        let nested = try syncJSON(fact) {
            var slice = $0["slice"] as! [String: Any]
            var exposure = (slice["exposures"] as! [[String: Any]])[0]
            exposure["future"] = true; slice["exposures"] = [exposure]; $0["slice"] = slice
        }
        let badSlice = try syncJSON(fact) { var slice = $0["slice"] as! [String: Any]; slice["visit_id"] = NSNull(); $0["slice"] = slice }
        for payload in [nested, badSlice] {
            let store = try store()
            try await store.receiveSyncFixture("fact", id: "fact", payload: payload)
            let incomplete = try await store.statisticsIncomplete(book: key)
            XCTAssertTrue(incomplete)
            let projection = try await store.projection(generation: 0, enabled: true, includeFacts: true)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
            XCTAssertTrue((json["facts"] as? [Any])?.isEmpty == true)
            let retained = try await store.syncFixturePayloads("fact")
            XCTAssertEqual(retained, [payload])
        }
        let destination = try store(), source = try store()
        try await source.receiveSyncFixture("position", payload: validPosition)
        let transfer = UserDataTransfer(positions: [try syncPosition("pending:book")], operations: [], facts: [])
        let future = try syncJSON(validPosition) { $0["v"] = 2 }
        try await destination.receiveSyncFixture("position", payload: future)
        await Self.rejectSync { try await destination.importPending(transfer, from: "pending:book", to: "sha") }
        let retained = try await destination.syncFixturePayloads("position")
        XCTAssertEqual(retained, [future])
    }
    func testSyncFutureClearAndFactBarriersDoNotDependOnArrivalOrder() async throws {
        let fact = syncFact("sha")
        let clear = try UserSyncJSON.encode(ClearValue(book: "sha", session: nil, through: 1, ids: []), envelope: true)
        let futureClear = try syncJSON(clear) { $0["v"] = 2 }
        let futureFact = try syncJSON(fact) { $0["v"] = 2 }
        for reverse in [false, true] {
            let store = try store()
            for payload in reverse ? [futureClear, clear] : [clear, futureClear] { try await store.receiveSyncFixture("clear", payload: payload) }
            await Self.rejectSync { try await store.projection(generation: 0, enabled: true, includeFacts: true) }
            await Self.rejectSync { try await store.clear(book: nil, session: nil) }
            let retained = try await store.syncFixturePayloads("clear")
            XCTAssertEqual(retained, [clear, futureClear].sorted())
            let partial = try self.store()
            for payload in reverse ? [futureFact, fact] : [fact, futureFact] { try await partial.receiveSyncFixture("fact", id: "fact", payload: payload) }
            let projection = try await partial.projection(generation: 0, enabled: true, includeFacts: true)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
            XCTAssertTrue((json["facts"] as? [Any])?.isEmpty == true)
            let incomplete = try await partial.statisticsIncomplete(book: "sha")
            XCTAssertTrue(incomplete)
            await Self.rejectSync { try await partial.saveFacts([("fact", "sha", fact)], generation: 0, current: 0, enabled: true) }
            let facts = try await partial.syncFixturePayloads("fact")
            XCTAssertEqual(facts, [fact, futureFact].sorted())
        }
    }
    @MainActor func testSyncFutureMetadataIsNotOfferedAsAnEditableFallback() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = BookInformationModel(readInformation: { _ in (nil, try await service.details(bookID: book.id)) }, readChapters: { _ in [] })
        let target = StatisticsRoute(bookID: book.id, title: "Original sample", fromReader: true)
        await model.load(target)
        XCTAssertNotNil(model.details)
        let payload = try UserSyncJSON.encode(StoredValue(updated: 1, token: "future", value: "\"Future author\""), envelope: true)
        let future = try syncJSON(payload) { $0["v"] = 2 }
        try await store.receiveSyncFixture("value", key: "metadata/" + book.contentSha256 + "/author", payload: future)
        await model.load(target)
        XCTAssertNil(model.details); XCTAssertNil(model.draft); XCTAssertNotNil(model.error)
        let retained = try await store.syncFixturePayloads("value", key: "metadata/" + book.contentSha256 + "/author")
        XCTAssertEqual(retained, [future])
    }

    @MainActor func testSyncStatisticsSurfaceHidesStaleTotalsAndReportsPartialFacts() async throws {
        let (root, service, book, store) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fact = syncFact(book.contentSha256)
        try await store.saveFacts([("fact", book.contentSha256, fact)], generation: 0, current: 0, enabled: true)
        let model = StatisticsModel()
        model.overview = try await service.statistics(first: 20000, last: 20000, book: book.contentSha256)
        XCTAssertNotNil(model.overview)
        let futureFact = try syncJSON(syncFact(book.contentSha256, id: "futureFact")) { $0["v"] = 2 }
        try await store.receiveSyncFixture("fact", key: book.contentSha256, id: "futureFact", payload: futureFact)
        let notice = try await service.statisticsCompatibilityNotice(book: book.contentSha256)
        XCTAssertNotNil(notice)
        let clear = try UserSyncJSON.encode(ClearValue(book: book.contentSha256, session: nil, through: 10000, ids: []), envelope: true)
        let future = try syncJSON(clear) { $0["v"] = 2 }
        try await store.receiveSyncFixture("clear", payload: future)
        do {
            _ = try await service.statistics(first: 20000, last: 20000, book: book.contentSha256)
            XCTFail("Unknown clear must not display totals")
        } catch is UserSyncCompatibilityError {
            model.report(UserSyncCompatibilityError(statistics: true))
        }
        XCTAssertNil(model.overview); XCTAssertNil(model.cumulative); XCTAssertTrue(model.spans.isEmpty)
        XCTAssertNotNil(model.error)
        await Self.rejectSync { try await service.deleteStatistics(book: book.contentSha256) }
        let retained = try await store.syncFixturePayloads("clear")
        XCTAssertEqual(retained, [future])
    }

    @MainActor func testSyncLatePendingRecordsBlockPromotedFastPathAndCanonicalFallback() async throws {
        let (root, service, book, formal) = try await editorFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.savePosition(bookID: book.id, offset: 9)
        let before = try await formal.syncFixturePayloads("position", key: book.contentSha256)
        let pending = try await service.userStore(pending: true)
        let sourceKey = "pending:" + book.id
        let raw = try syncPosition(sourceKey)
        let future = try syncJSON(raw) { $0["v"] = 2 }
        try await pending.receiveSyncFixture("position", key: sourceKey, payload: future)
        await Self.rejectSync { try await service.savePosition(bookID: book.id, offset: 18) }
        let retained = try await pending.syncFixturePayloads("position", key: sourceKey)
        XCTAssertEqual(retained, [future])
        let after = try await formal.syncFixturePayloads("position", key: book.contentSha256)
        XCTAssertEqual(after, before)
        let snapshot = try await service.snapshot(book.id)
        XCTAssertEqual(snapshot.book.positionUtf8, 0, "The old canonical position must not mask an unsupported pending alias")
        let notice = try await service.readingCompatibilityNotice(book.id)
        XCTAssertNotNil(notice)
        let protected = await service.pendingPromotionIDs.contains(book.id)
        XCTAssertTrue(protected, "Do not reclaim the source identity while its pending raw data is protected")
        let clear = try UserSyncJSON.encode(ClearValue(book: sourceKey, session: nil, through: 10, ids: []), envelope: true)
        let futureClear = try syncJSON(clear) { $0["v"] = 2 }
        try await pending.receiveSyncFixture("clear", payload: futureClear)
        await Self.rejectSync { try await service.statistics(first: 0, last: 20000, book: book.contentSha256) }
    }

}
