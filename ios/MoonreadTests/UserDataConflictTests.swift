import CryptoKit
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class UserDataConflictTests: UserDataFixture {
  // S457: 正式/pending 同时间裁决稳定且不受遍历顺序影响，提升前后同一 winner；候选裁决唯一来源。
  func testEqualTimestampFormalAndPendingPositionWinnerSurvivesPromotion() async throws {
    for formalWins in [true, false] {
      let f = try positionWinnerFixture()
      defer { f.clean() }
      let sha = f.book.contentSha256
      let alias = "pending:" + f.aliases[1]
      let formal = try positionRecord(
        key: sha, token: formalWins ? "z-formal" : "a-formal", offset: 7)
      let pending = try positionRecord(
        key: alias, token: formalWins ? "a-pending" : "z-pending", offset: 19)
      try await receivePosition(formal, key: sha, store: f.formal)
      try await receivePosition(pending, key: alias, store: f.pending)
      let keys = [sha, alias]
      let expected: UInt64 = formalWins ? 7 : 19
      let before = try await f.service.effectiveQuery(keys: keys).bookInfo(bookId: f.book.id)
      XCTAssertEqual(before.positionUtf8, expected)
      // Scoped projection must carry the exact token used by the reducer.
      let scoped = try await f.formal.projection(
        generation: 0, enabled: true, includeFacts: false, keys: [sha, sha])
      let json = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(scoped.utf8)) as? [String: Any])
      let positions = try XCTUnwrap(json["positions"] as? [[String: Any]])
      XCTAssertEqual(positions.count, 1)
      XCTAssertEqual(positions.first?["token"] as? String, formal.token)
      let transfer = try await f.pending.exportPending(key: alias)
      try await f.formal.importPending(transfer, from: alias, to: sha)
      try await f.pending.removePending(key: alias)
      let after = try await f.service.effectiveQuery(keys: keys).bookInfo(bookId: f.book.id)
      XCTAssertEqual(after.positionUtf8, before.positionUtf8)
      let winner = try await f.formal.positionValues()["position/" + sha]
      XCTAssertEqual(winner?.token, formalWins ? formal.token : pending.token)
    }
    // Two aliases have the same time; enumeration and promotion order cannot change the winner.
    do {

      for reverse in [false, true] {
        let f = try positionWinnerFixture()
        defer { f.clean() }
        let sha = f.book.contentSha256
        let keys = f.aliases.map { "pending:" + $0 }
        let a = try positionRecord(key: keys[0], token: "a-alias", offset: 7)
        let z = try positionRecord(key: keys[1], token: "z-alias", offset: 19)
        let records = reverse ? [z, a] : [a, z]
        let candidates = try records.map { try PositionCandidate($0).rekeyed(to: sha) }
        let reduced = PositionCandidate.reduce(candidates)
        XCTAssertEqual(reduced.count, 1)
        XCTAssertEqual(reduced[sha]?.stored.token, "z-alias")
        for record in records {
          let key = try PositionCandidate(record).value.content_key
          try await receivePosition(record, key: key, store: f.pending)
        }
        let scopedKeys = reverse ? Array(keys.reversed()) : keys
        let before = try await f.service.effectiveQuery(keys: scopedKeys).bookInfo(
          bookId: f.book.id)
        XCTAssertEqual(before.positionUtf8, 19, "Only the final SHA winner is loaded by Rust")
        for key in scopedKeys {
          let transfer = try await f.pending.exportPending(key: key)
          try await f.formal.importPending(transfer, from: key, to: sha)
          try await f.pending.removePending(key: key)
        }
        let after = try await f.service.effectiveQuery(keys: [sha]).bookInfo(bookId: f.book.id)
        XCTAssertEqual(after.positionUtf8, before.positionUtf8)
        let winner = try await f.formal.positionValues()["position/" + sha]
        XCTAssertEqual(winner?.token, "z-alias")
      }

    }
  }

  // S459: 并发完整编辑及范围编辑形成真实冲突，明确决议后保留唯一结果，不丢候选。
  func testThreeConcurrentWholeEditsAndRangeOnlyConflictsResolveToOneResult() async throws {
    let store = try self.store()
    let key = String(repeating: "a", count: 64)
    let initial = candidate("base", content: content(""))
    let a = candidate("a", parents: ["base"], content: content("", start: 0, end: 12))
    let b = candidate("b", parents: ["base"], content: content("", start: 3, end: 15))
    let c = candidate("c", parents: ["base"], content: content("third", start: 0, end: 9))
    for value in [c, initial, a, b, a] {
      try await store.receiveFixture(key: key, mark: "mark", candidate: value)
    }
    let heads = try await store.candidates(key: key)["mark"] ?? []
    XCTAssertEqual(Set(heads.map(\.id)), ["a", "b", "c"])
    XCTAssertTrue(AnnotationReduction.conflicts(heads))
    let final = content("manual result", start: 0, end: 15)
    try await store.resolve(key: key, id: "mark", expected: heads, content: final)
    let resolved = try await store.candidates(key: key)["mark"] ?? []
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved.first?.content, final)
    let recordCount = try await store.fixtureRecordCount()
    XCTAssertEqual(recordCount, 1)
    // A late old record cannot resurrect content that the resolution consumed.
    try await store.receiveFixture(key: key, mark: "mark", candidate: b)
    let late = try await store.candidates(key: key)["mark"] ?? []
    XCTAssertEqual(late.count, 1)
    XCTAssertEqual(late.first?.content, final)
  }

  // S460: 删除/撤销只有观察过的祖先可被消除，离线编辑仍是并发候选，防误吞内容。
  func testOldBaselineDeleteConflictsButDeleteBasedOnNewEditWins() async throws {
    let store = try self.store()
    let key = String(repeating: "b", count: 64)
    let base = candidate("base", content: content("old"))
    let edit = candidate("edit", parents: ["base"], content: content("new"))
    let deletion = candidate("delete", parents: ["base"], content: nil)
    for value in [edit, deletion, base] {
      try await store.receiveFixture(key: key, mark: "mark", candidate: value)
    }
    let heads = try await store.candidates(key: key)["mark"] ?? []
    XCTAssertTrue(AnnotationReduction.conflicts(heads))
    XCTAssertEqual(heads.count, 2)
    try await store.resolve(key: key, id: "mark", expected: heads, content: edit.content)
    let newest = try await store.candidates(key: key)["mark"] ?? []
    try await store.changeDeletion("mark", baseline: newest, deleted: true, restoring: nil)
    let deleted = try await store.candidates(key: key)["mark"] ?? []
    XCTAssertFalse(AnnotationReduction.conflicts(deleted))
    XCTAssertEqual(deleted.count, 1)
    XCTAssertNil(deleted.first?.content)
    // Undo of a witnessed delete remains concurrent with an unseen offline edit.
    do {

      let store = try self.store()
      let old = content("old")
      let key = "key"
      let base = candidate("base", content: old)
      try await store.receiveFixture(key: key, mark: "m", candidate: base)
      try await store.changeDeletion("m", baseline: [base], deleted: true, restoring: nil)
      let deletion = try await store.candidates(key: key)["m"] ?? []
      try await store.receiveFixture(
        key: key, mark: "m",
        candidate: candidate("remote", parents: ["base"], content: content("remote")))
      try await store.changeDeletion("m", baseline: deletion, deleted: false, restoring: old)
      let result = try await store.candidates(key: key)["m"] ?? []
      XCTAssertEqual(result.count, 2)
      XCTAssertTrue(AnnotationReduction.conflicts(result))

    }
  }

  // S461: 相同内容不制造冲突，但陈旧 resolution 不得删除后来候选。
  func testIdenticalEditsAreNotConflictAndStaleResolutionCannotEatNewCandidate() async throws {
    let store = try self.store()
    let key = "key"
    let same = content("same")
    let a = candidate("a", parents: ["base"], content: same)
    let b = candidate("b", parents: ["base"], content: same)
    for value in [a, b] { try await store.receiveFixture(key: key, mark: "m", candidate: value) }
    let observed = try await store.candidates(key: key)["m"] ?? []
    XCTAssertFalse(AnnotationReduction.conflicts(observed))
    try await store.receiveFixture(
      key: key, mark: "m", candidate: candidate("c", parents: ["base"], content: content("new")))
    do {
      try await store.resolve(key: key, id: "m", expected: observed, content: same)
      XCTFail("stale resolution")
    } catch is UserDataConflict {}
    let remaining = try await store.candidates(key: key)["m"] ?? []
    XCTAssertEqual(remaining.count, 3)
  }

  // S465: 重复创建同逻辑 value 按既定 token 裁决稳定，不依赖插入顺序；位置裁决在 S457 不重复。
  func testDuplicateLogicalValueCreationAndDevicePositionTiesAreDeterministic() async throws {
    let store = try self.store()
    try await store.put("metadata/sha/author", value: "\"First\"", device: "a")
    try await store.put("metadata/sha/author", value: "\"Second\"", device: "b")
    let author = try await store.value("metadata/sha/author")
    XCTAssertEqual(author, "\"Second\"")
  }

  // S466: 合并 mark 与离线编辑统一在完整 bundle 裁决，不将同一内容留成多个活跃标记。
  func testMergedMarksAndOfflineEditResolveInTheSameBundle() async throws {
    let store = try self.store()
    let key = "sha"
    let first = candidate("base-a", content: content("first", start: 0, end: 9))
    let second = candidate("base-b", content: content("second", start: 12, end: 21))
    try await store.receiveFixture(key: key, mark: "a", candidate: first)
    try await store.receiveFixture(key: key, mark: "b", candidate: second)
    let edit = AnnotationEdit(
      id: "a", bookId: "book", startUtf8: 0, endUtf8: 21, excerpt: "combined",
      note: "first\n\nsecond", marks: [], baselines: ["a": [first], "b": [second]])
    _ = try await store.saveAnnotation(
      key: key, edit: edit, content: content("first\n\nsecond", start: 0, end: 21))
    try await store.receiveFixture(
      key: key, mark: "b",
      candidate: candidate(
        "offline-b", parents: ["base-b"], content: content("offline", start: 12, end: 24)))
    let bundle = try await store.editingBundle(key: key, edit: edit)
    XCTAssertEqual(Set(bundle.keys), ["a", "b"])
    let choices = bundle.values.flatMap { $0 }.filter { $0.mergedInto == nil }
    XCTAssertEqual(choices.count, 2)
    try await store.resolveBundle(
      key: key, id: "a", expected: bundle, content: content("chosen", start: 0, end: 24), edit: edit
    )
    let after = try await store.editingBundle(key: key, edit: edit)
    XCTAssertFalse(after.values.contains(where: AnnotationReduction.conflicts))
    let groups = try await store.candidates(key: key)
    XCTAssertEqual(groups.values.flatMap { $0 }.filter { $0.content != nil }.count, 1)
  }

  // S470: 整条合并链任一成员有冲突时禁止普通保存，不能只验第一个 mark。
  func testMergeRejectsConflictOnLaterMemberAndIncludesRangeChain() async throws {
    let store = try self.store()
    let key = "sha"
    let a = candidate("first", content: content("first", start: 0, end: 10))
    let b = candidate("second-a", content: content("A", start: 8, end: 20))
    let other = candidate("second-b", content: content("B", start: 8, end: 20))
    let c = candidate("third", content: content("third", start: 18, end: 30))
    for (mark, value) in [("first", a), ("second", b), ("second", other), ("third", c)] {
      try await store.receiveFixture(key: key, mark: mark, candidate: value)
    }
    let edit = AnnotationEdit(
      id: "first", bookId: "book", startUtf8: 0, endUtf8: 10, excerpt: "text", note: "first",
      marks: [], baselines: ["first": [a]])
    let bundle = try await store.editingBundle(key: key, edit: edit)
    XCTAssertEqual(Set(bundle.keys), ["first", "second", "third"])
    do {
      _ = try await store.saveAnnotation(key: key, edit: edit, content: content("ordinary"))
      XCTFail("Unresolved later member")
    } catch is UserDataConflict {}
    var fullEdit = edit
    fullEdit.baselines = bundle
    do {
      _ = try await store.saveAnnotation(key: key, edit: fullEdit, content: content("ordinary"))
      XCTFail("Known conflicts require explicit resolution")
    } catch is UserDataConflict {}
    let untouched = try await store.candidates(key: key)
    XCTAssertEqual(Set(untouched["second", default: []].map(\.id)), ["second-a", "second-b"])
    try await store.resolveBundle(
      key: key, id: edit.id, expected: bundle,
      content: content("first\nA\nB\nthird\nmanual", start: 0, end: 30), edit: edit)
    let result = try await store.candidates(key: key).values.flatMap { $0 }.compactMap(\.content)
    XCTAssertEqual(result.count, 1)
    XCTAssertTrue(result[0].note.contains("B"))
  }

  // S471: 编辑期间新成员/候选出现使旧 resolution 失效，失败必须保留全部新增内容。
  func testResolutionRejectsNewMemberAndNewCandidateDuringEditing() async throws {
    let store = try self.store()
    let key = "sha"
    let a = candidate("a", content: content("A", start: 0, end: 10))
    let b = candidate("b", content: content("B", start: 0, end: 10))
    for value in [a, b] { try await store.receiveFixture(key: key, mark: "m", candidate: value) }
    let edit = AnnotationEdit(
      id: "m", bookId: "book", startUtf8: 0, endUtf8: 10, excerpt: "", note: "", marks: [],
      baselines: ["m": [a, b]])
    let initial = try await store.editingBundle(key: key, edit: edit)
    try await store.receiveFixture(
      key: key, mark: "new",
      candidate: candidate("new-member", content: content("new", start: 9, end: 18)))
    do {
      try await store.resolveBundle(
        key: key, id: "m", expected: initial, content: a.content, edit: edit)
      XCTFail("Missing member")
    } catch is UserDataConflict {}
    let next = try await store.editingBundle(key: key, edit: edit)
    try await store.receiveFixture(
      key: key, mark: "m", candidate: candidate("c", content: content("C")))
    do {
      try await store.resolveBundle(
        key: key, id: "m", expected: next, content: a.content, edit: edit)
      XCTFail("Missing candidate")
    } catch is UserDataConflict {}
    let remaining = try await store.candidates(key: key)
    XCTAssertEqual(remaining["m"]?.count, 3)
    XCTAssertEqual(remaining["new"]?.count, 1)
  }
  @MainActor
  func testNoteExportUsesWholeReadOnlySnapshotAndPreservesVersions() async throws {
    let (root, service, book, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = book.contentSha256
    for index in 0..<62 {
      let value = AnnotationCandidate(id: "operation-\(index)", ancestors: [],
        content: .init(start: UInt64(index), end: UInt64(index + 1), excerpt: "line \(index)\n<quote>*", note: "[note]\n`code`"),
        created: 1_000, bookmark: index == 0)
      try await store.receiveFixture(key: key, mark: "m\(index)", candidate: value)
    }
    let base = candidate("base", content: content("old"))
    let a = candidate("version-a", parents: ["base"], content: content("version A"))
    let b = candidate("version-b", parents: ["base"], content: content("version B"))
    let deletion = candidate("deleted-version", parents: ["base"], content: nil)
    for value in [base, a, b, deletion] {
      try await store.receiveFixture(key: key, mark: "conflict", candidate: value)
    }
    let before = try await store.syncFixturePayloads("mark")
    let listSnapshot = try await service.noteCandidates(book.id)
    let page = try await service.marks(book.id, kind: .annotation, offset: 0, snapshot: listSnapshot)
    XCTAssertTrue(page.hasMore)
    let document = try await service.noteDocument(book.id)
    XCTAssertEqual(document.records.count, 64, "Export bypasses list pagination and keeps both live versions")
    let conflict = document.records.filter { $0.mark.id == "conflict" }
    XCTAssertEqual(Set(conflict.compactMap(\.version)), [1, 2])
    XCTAssertTrue(conflict.allSatisfy(\.deletionVersion))
    let raw = document.render(.text)
    let md = document.render(.markdown)
    XCTAssertTrue(raw.contains("line 61\n<quote>*"))
    XCTAssertTrue(raw.contains("[note]\n`code`"))
    XCTAssertTrue(md.contains("> line 61\n> \\<quote\\>\\*"))
    XCTAssertTrue(md.contains("\\[note\\]\n\\`code\\`"))
    // Ordinary punctuation stays readable in the file; only Markdown syntax is escaped.
    let punctuation = "句中 (括号). foo-bar! a+b #话题 {文字} | & ~"
    XCTAssertEqual(NoteDocument.escape(punctuation), punctuation)
    for (source, escaped) in [
      ("# 标题", "\\# 标题"), ("  - 列表", "  \\- 列表"), ("+ 列表", "\\+ 列表"),
      ("1. 列表", "1\\. 列表"), ("12) 列表", "12\\) 列表"),
      ("段落\n---", "段落\n\\---"), ("段落\n===", "段落\n\\==="),
      ("#普通文字", "#普通文字"), ("1.23 和 2)句中", "1.23 和 2)句中"),
      ("[笔记] *强调* _文字_ <tag> `code`", "\\[笔记\\] \\*强调\\* \\_文字\\_ \\<tag\\> \\`code\\`"),
    ] { XCTAssertEqual(NoteDocument.escape(source), escaped) }
    for source in [punctuation, "# 标题", "- 列表", "1. 列表", "[链接](URL) *强调* <tag>"] {
      let rendered = try AttributedString(markdown: NoteDocument.escape(source))
      XCTAssertEqual(String(rendered.characters), source, "Rendered text preserves the original")
    }
    XCTAssertFalse(raw.contains(key))
    XCTAssertFalse(raw.contains("version-a"))
    let after = try await store.syncFixturePayloads("mark")
    XCTAssertEqual(after, before, "Export does not compact operations or mutate facts")
    let mark = try XCTUnwrap(document.records.first)
    let excerpt = NoteDocument(title: "Title", author: "Author", records: []).excerpt(
      .init(id: mark.id, mark: mark.mark, chapter: "Chapter", percentage: 42, version: nil, deletionVersion: false))
    XCTAssertEqual(excerpt, mark.mark.excerpt + "\n\n——《Title》 · Author · Chapter · 42%")
    let payload = try NoteSharePayload(document: document, format: .text)
    let url = try XCTUnwrap(payload.url)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), raw)
    payload.clean()
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    var future = candidate("future", content: content("unreadable"))
    future.bookmark = false
    let json = try syncJSON(UserSyncJSON.encode(future, envelope: true)) { $0["v"] = 2 }
    try await store.receiveSyncFixture("mark", key: key, id: future.id, mark: "unknown", payload: json)
    let snapshot = try await service.noteCandidates(book.id)
    XCTAssertNoThrow(try snapshot.checked(["m0"]))
    XCTAssertThrowsError(try snapshot.checked(nil))
    do { _ = try await service.noteDocument(book.id); XCTFail("Incomplete export must stop") }
    catch is NoteReadError {}

    // A completed source can still have unpromoted facts. Export must promote
    // first, and must not bypass a later unreadable pending record via the cache.
    let f = try positionWinnerFixture()
    defer { f.clean() }
    let id = f.aliases[0], pendingKey = "pending:" + id
    let staged = candidate("staged-note", content: content("pending note"))
    try await f.pending.receiveFixture(key: pendingKey, mark: "staged", candidate: staged)
    let promotedDocument = try await f.service.noteDocument(id)
    XCTAssertEqual(promotedDocument.records.map { $0.mark.note }, ["pending note"])
    let pendingAfter = try await f.pending.noteCandidates(key: pendingKey)
    XCTAssertTrue(pendingAfter.groups.isEmpty)
    let unknown = try syncJSON(UserSyncJSON.encode(candidate("future-pending", content: content("future")), envelope: true)) { $0["v"] = 2 }
    try await f.pending.receiveSyncFixture("mark", key: pendingKey, id: "future-pending", mark: "future", payload: unknown)
    let beforeBlockedExport = try await f.pending.syncFixturePayloads("mark")
    let selections: [Set<String>?] = [nil, ["staged"]]
    for selected in selections {
      do {
        _ = try await f.service.noteDocument(id, ids: selected)
        XCTFail("Failed pending promotion must block whole and selected export")
      } catch is UserSyncCompatibilityError {}
    }
    let afterBlockedExport = try await f.pending.syncFixturePayloads("mark")
    XCTAssertEqual(afterBlockedExport, beforeBlockedExport, "Unreadable pending facts are retained")
  }

  @MainActor
  func testSelectedNoteDeletionRejectsEntireChangedBatchAndReusesUndo() async throws {
    let (root, service, book, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let key = book.contentSha256
    let a = candidate("a", content: content("first"))
    let b = candidate("b", content: content("second"))
    try await store.receiveFixture(key: key, mark: "first", candidate: a)
    try await store.receiveFixture(key: key, mark: "second", candidate: b)
    for index in 0..<60 {
      try await store.receiveFixture(key: key, mark: "page-\(index)",
        candidate: candidate("page-op-\(index)", content: content("later page", start: UInt64(10 + index), end: UInt64(11 + index))))
    }
    let tools = ReaderToolsModel(service: service)
    tools.select(.notes)
    await tools.prepare(bookID: book.id, currentChapter: 0, library: true)
    XCTAssertEqual(tools.notes.count, 60)
    XCTAssertTrue(tools.moreNotes)
    tools.toggleNote(try XCTUnwrap(tools.notes.first { $0.id == "first" }))
    tools.toggleNote(try XCTUnwrap(tools.notes.first { $0.id == "second" }))
    let changed = candidate("changed", parents: ["b"], content: content("edited remotely"))
    try await store.receiveFixture(key: key, mark: "second", candidate: changed)
    await tools.loadNotes(reset: false)
    XCTAssertEqual(tools.notes.count, 62)
    XCTAssertEqual(tools.notes.first { $0.id == "second" }?.note, "second")
    XCTAssertEqual(tools.selectedCandidates["second"]?.map(\.id), ["b"])
    XCTAssertEqual(tools.noteSnapshot?.groups["second"]?.map(\.id), ["b"])
    let selected = NoteCandidates(key: key, groups: tools.selectedCandidates, blocked: [])
    let before = try await store.syncFixturePayloads("mark")
    do {
      try await service.deleteNoteSelection(book.id, expected: selected, ids: ["first", "second"])
      XCTFail("Stale selection must not delete even the unchanged first record")
    } catch is UserDataConflict {}
    let after = try await store.syncFixturePayloads("mark")
    XCTAssertEqual(after, before)
    let latest = try await service.noteCandidates(book.id)
    try await service.deleteNoteSelection(book.id, expected: latest, ids: ["first", "second"])
    let deleted = try await store.noteCandidates(key: key)
    for id in ["first", "second"] {
      XCTAssertTrue(try XCTUnwrap(deleted.groups[id]).allSatisfy { $0.content == nil })
    }
    XCTAssertEqual(deleted.groups.filter { $0.key.hasPrefix("page-") && $0.value.first?.content != nil }.count, 60)
    try await service.deleteMarks(["first", "second"], deleted: false)
    let restored = try await store.noteCandidates(key: key)
    XCTAssertEqual(restored.groups["first"]?.first?.content, a.content)
    XCTAssertEqual(restored.groups["second"]?.first?.content, changed.content)
  }

}
