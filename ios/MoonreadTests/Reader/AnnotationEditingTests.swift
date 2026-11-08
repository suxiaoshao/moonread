import CryptoKit
import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class AnnotationEditingReaderIntegrationTests: ReaderIntegrationFixture {
  // S357: 部分选择编辑保存使用完整合并批注链，不截断旧注释内容；候选裁决另在 UserData。
  @MainActor
  func testPartialSelectionOpensOneEditorAndSavesMergedComments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let core = try ReaderCore(dataDirectory: root.path)
    let service = AppDataService(core: core)
    let book = try core.createSampleBook()
    let session = ReaderSession(service: service)
    await session.open(.book(book.id))
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in session.window != nil }, object: nil)
    await fulfillment(of: [ready], timeout: 5)
    let source = try XCTUnwrap(session.window.map { ReadingText($0).text })
    func offset(_ n: Int) -> UInt64 { UInt64(source.prefix(n).utf8.count) }
    let rightEdit = try await service.prepareAnnotation(book.id, start: offset(8), end: offset(12))
    _ = try await service.saveNote(rightEdit, text: "Second comment")
    let leftEdit = try await service.prepareAnnotation(book.id, start: offset(1), end: offset(5))
    let left = try await service.saveNote(leftEdit, text: "First comment")
    let position = session.anchor
    session.selectText(start: offset(4), end: offset(9), action: .comment)
    let opened = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in session.editor != nil }, object: nil)
    await fulfillment(of: [opened], timeout: 5)
    let edit = try XCTUnwrap(session.editor)
    XCTAssertEqual(edit.note, "First comment\n\nSecond comment")
    XCTAssertEqual(edit.startUtf8, offset(1))
    XCTAssertEqual(edit.endUtf8, offset(12))
    let unchanged = try await service.mark(left.id)
    XCTAssertEqual(unchanged.endUtf8, offset(5), "Opening must not commit range changes")
    let draft = try XCTUnwrap(session.noteEditorModel)
    XCTAssertTrue(draft.hasUnsavedChanges, "The uncommitted range merge is itself a change")
    draft.text = "Edited together"
    let write = try XCTUnwrap(draft.beginCommit())
    XCTAssertTrue(draft.saving, "Save admission is synchronous before task scheduling")
    let saved = await write.value
    XCTAssertTrue(saved)
    XCTAssertFalse(draft.hasUnsavedChanges)
    let persisted = try await service.prepareAnnotation(book.id, start: edit.startUtf8, end: edit.endUtf8)
    let existing = NoteEditorModel(edit: persisted, service: service)
    XCTAssertFalse(existing.hasUnsavedChanges)
    existing.text += "changed"; XCTAssertTrue(existing.hasUnsavedChanges)
    existing.text = persisted.note; XCTAssertFalse(existing.hasUnsavedChanges)
    existing.conflictChoice = true; XCTAssertTrue(existing.hasUnsavedChanges)
    let marks = try await service.marks(book.id, kind: .annotation, offset: 0).items
    XCTAssertEqual(marks.count, 1)
    XCTAssertEqual(marks.first?.note, "Edited together")
    XCTAssertEqual(session.anchor, position)
    await session.leave().value
  }
}

final class AnnotationEditingApplicationStateTests: ApplicationStateFixture {
  // S443: 撤销仅在仍可见的有效期可用，取消的旧计时器不能清新撤销；假 clock 显式推进。
  func testUndoCountsOnlyVisibleTimeAndRejectsCancelledOldTimer() async {
    let clock = ManualTestClock()
    let tools = ReaderToolsModel(
      uptime: { .seconds(clock.now.timeIntervalSince1970 - 1_800_000_000) },
      sleep: { duration in
        let value = duration.components
        try await clock.sleep(Double(value.seconds) + Double(value.attoseconds) / 1e18)
      })
    tools.deletedIDs = ["mark"]
    tools.setUndoVisible(true)
    await awaitState { clock.pendingSleeps == 1 }
    clock.advance(2)
    tools.setUndoVisible(false)
    clock.advance(100)
    XCTAssertEqual(tools.deletedIDs, ["mark"])
    tools.setUndoVisible(true)
    await awaitState { clock.pendingSleeps == 1 }
    clock.advance(3)
    XCTAssertEqual(tools.deletedIDs, ["mark"])
    clock.advance(1)
    await awaitState { tools.deletedIDs == nil }
    XCTAssertNil(tools.deletedIDs)
  }
}

final class AnnotationEditingUserDataTests: UserDataFixture {
  // S472: 编辑器读取完整冲突并在远端更新后撤销旧选择；关闭不提交，重新明确选择才能写入。
  @MainActor func testEditorLoadsEntireMergeAndInvalidatesChoiceOnRemoteArrival() async throws {
    let (root, service, book, store) = try await editorFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults(suiteName: "Review-\(root.lastPathComponent)")?.removePersistentDomain(
        forName: "Review-\(root.lastPathComponent)")
    }
    let a = candidate("a", content: content("first", start: 0, end: 10))
    let b = candidate("b", content: content("A", start: 8, end: 20))
    let c = candidate("c", content: content("B", start: 8, end: 20))
    let d = candidate("d", content: content("third", start: 18, end: 30))
    for (mark, value) in [("a", a), ("b", b), ("b", c), ("c", d)] {
      try await store.receiveFixture(key: book.contentSha256, mark: mark, candidate: value)
    }
    let edit = try await service.prepareAnnotation(book.id, start: 0, end: 2)
    XCTAssertEqual(Set(edit.baselines.keys), ["a", "b", "c"])
    let model = NoteEditorModel(edit: edit, service: service)
    await model.loadConflicts()
    XCTAssertEqual(model.conflicts.count, 4)
    await model.keepBoth()
    XCTAssertTrue(model.text.contains("A"))
    XCTAssertTrue(model.text.contains("B"))
    try await store.receiveFixture(
      key: book.contentSha256, mark: "b",
      candidate: candidate("late", content: content("late", start: 8, end: 20)))
    await model.loadConflicts()
    XCTAssertFalse(model.conflictChoice)
    XCTAssertEqual(model.conflicts.count, 5)
    let unresolved = await model.commit()
    XCTAssertFalse(unresolved)
    await model.keepBoth()
    model.text += "\nmanual"
    let saved = await model.commit()
    XCTAssertTrue(saved)
    let results = try await store.candidates(key: book.contentSha256).values.flatMap { $0 }
      .compactMap(\.content)
    XCTAssertEqual(results.count, 1)
    XCTAssertTrue(results[0].note.contains("late"))
    XCTAssertTrue(results[0].note.contains("manual"))
    let reopened = try await service.prepareAnnotation(book.id, start: 0, end: 2)
    _ = try await service.saveNote(reopened, text: "edited after merge")
    let subsequent = try await store.candidates(key: book.contentSha256).values.flatMap { $0 }
      .compactMap(\.content)
    XCTAssertEqual(subsequent.count, 1)
    XCTAssertEqual(subsequent[0].note, "edited after merge")
    // Closing a resolution never implicitly commits the selected candidate.
    do {

      let (root, service, book, store) = try await editorFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: "Review-\(root.lastPathComponent)")?.removePersistentDomain(
          forName: "Review-\(root.lastPathComponent)")
      }
      let live = candidate("live", content: content("retained"))
      let deletion = candidate("delete", content: nil)
      for value in [live, deletion] {
        try await store.receiveFixture(key: book.contentSha256, mark: "m", candidate: value)
      }
      let edit = try await service.prepareAnnotation(book.id, start: 0, end: 2)
      let model = NoteEditorModel(edit: edit, service: service)
      await model.loadConflicts()
      model.choose(deletion)
      XCTAssertTrue(model.deleteChoice)
      XCTAssertEqual(model.text, "")
      let afterClose = try await store.candidates(key: book.contentSha256)["m"] ?? []
      XCTAssertEqual(afterClose.count, 2)
      let reopened = NoteEditorModel(
        edit: try await service.prepareAnnotation(book.id, start: 0, end: 2), service: service)
      await reopened.loadConflicts()
      XCTAssertFalse(reopened.deleteChoice)
      XCTAssertFalse(reopened.conflictChoice)
      reopened.choose(live)
      reopened.text = "manual kept"
      let kept = await reopened.commit()
      XCTAssertTrue(kept)
      let keptHeads = try await store.candidates(key: book.contentSha256)["m"] ?? []
      XCTAssertEqual(keptHeads.first?.content?.note, "manual kept")
      try await store.receiveFixture(
        key: book.contentSha256, mark: "m", candidate: candidate("delete-again", content: nil))
      let final = NoteEditorModel(
        edit: try await service.prepareAnnotation(book.id, start: 0, end: 2), service: service)
      await final.loadConflicts()
      final.choose(candidate("delete-again", content: nil))
      let removed = await final.commit()
      XCTAssertTrue(removed)
      let deleted = try await store.candidates(key: book.contentSha256)["m"] ?? []
      XCTAssertEqual(deleted.count, 1)
      XCTAssertNil(deleted.first?.content)

    }
  }

  // S477: 取消新增/编辑只丢草稿，不改既有批注正文和范围。
  @MainActor func testCancelledEditingDiscardsNewContentAndPreservesExistingTextAndRange()
    async throws
  {
    let (root, service, book, store) = try await editorFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fresh = try await service.prepareAnnotation(book.id, start: 0, end: 8)
    var session: NoteEditorModel? = NoteEditorModel(edit: fresh, service: service)
    session?.text = "unconfirmed new comment"
    session?.edit.endUtf8 = 18
    session = nil  // X and swipe simply release the editing session.
    let afterNew = try await store.candidates(key: book.contentSha256)
    XCTAssertTrue(afterNew.isEmpty)
    let empty = try await service.prepareAnnotation(book.id, start: 0, end: 8)
    XCTAssertEqual(empty.note, "")
    XCTAssertEqual(empty.endUtf8, 8)
    let saved = try await service.saveNote(empty, text: "confirmed")
    session = NoteEditorModel(
      edit: try await service.prepareAnnotation(book.id, start: 0, end: 8), service: service)
    session?.text = "unconfirmed edit"
    session?.edit.endUtf8 = 28
    session = nil
    let formal = try await service.mark(saved.id)
    XCTAssertEqual(formal.note, "confirmed")
    XCTAssertEqual(formal.endUtf8, 8)
    let reopened = try await service.prepareAnnotation(book.id, start: 0, end: 8)
    XCTAssertEqual(reopened.note, "confirmed")
    XCTAssertEqual(reopened.endUtf8, 8)
    let highlighted = try await service.annotate(book.id, start: 40, end: 48)
    let keptHighlight = try await service.mark(highlighted.id)
    XCTAssertEqual(keptHighlight.note, "")
    XCTAssertEqual(keptHighlight.endUtf8, 48)
  }
}
