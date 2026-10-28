import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AIProposalTests: BookAIFixture {
  // S086: 确认元数据后只写目标书，重命名冲突/陈旧源不误改文件，保留原阅读位置。
  func testMetadataRenameSuccessConflictAndStaleSource() async throws {
    for scenario in ["success", "conflict", "stale"] {
      let (root, reader, book, _, shelf) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let repository = try await AIRepository.open(inMemory: true)
      let owner = UUID().uuidString
      let registry = await registry(repository, reader: reader, owner: owner)
      let files = try await reader.aiLibraryBooks(shelf)
      let source = try XCTUnwrap(files.first)
      try await reader.savePosition(bookID: book.id, offset: 9)
      let input = AIMetadataProposalInput(
        bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Updated author",
        rename: .init(fileRef: AIReadingTools.ref("f", source.id), name: "New title"))
      let proposal = try await registry.metadataProposal(input)
      let value = try XCTUnwrap(
        AICommittedResultDecoder.results(
          entry(
            try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))),
            name: "propose_book_metadata"), sessionID: owner
        ).first)
      await registry.openResult(value)
      if scenario == "conflict" {
        try "Do not overwrite".write(
          to: root.appending(path: "library/New title.txt"), atomically: true, encoding: .utf8)
      }
      if scenario == "stale" {
        try await reader.renameLibraryItem(source, name: "External.txt", replace: false)
      }
      await registry.applyMetadata([value.id])
      let details = try await reader.details(sha: book.contentSha256)
      XCTAssertEqual(details.metadata.author, "Updated author", scenario)
      XCTAssertNotNil(registry.feedback[value.id], scenario)
      XCTAssertNil(registry.lastErrors[value.id], scenario)
      XCTAssertEqual(details.book?.positionUtf8, 9, scenario)
      if scenario == "success" {
        XCTAssertNotNil(registry.renameFeedback[value.id])
        XCTAssertNil(registry.renameErrors[value.id])
        XCTAssertTrue(
          FileManager.default.fileExists(atPath: root.appending(path: "library/New title.txt").path)
        )
        guard case .metadata(let review) = registry.review(value.id)?.body else {
          return XCTFail("Missing review")
        }
        XCTAssertEqual(registry.metadataChangeCount(value.id, review), 0)
      } else {
        XCTAssertNotNil(registry.renameErrors[value.id])
        XCTAssertNil(registry.renameFeedback[value.id])
        if scenario == "conflict" {
          XCTAssertEqual(
            try String(contentsOf: root.appending(path: "library/New title.txt"), encoding: .utf8),
            "Do not overwrite")
          XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appending(path: "library/book.txt").path))
        } else {
          XCTAssertTrue(
            FileManager.default.fileExists(
              atPath: root.appending(path: "library/External.txt").path))
        }
      }
    }
  }

  // S087: 审核草稿取消/重开从原建议和当前元数据重建，未确认选择不落盘。
  func testMetadataReviewCountsAndReplaceDefaults() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let base = try await reader.details(sha: book.contentSha256).metadata
    var initial = base
    initial.author = "Author"
    initial.tags = ["keep", "remove"]
    try await reader.saveMetadata(base: base, edited: initial)
    let owner = UUID().uuidString
    let registry = await registry(
      try await AIRepository.open(inMemory: true), reader: reader, owner: owner)
    let proposal = AIMetadataProposal(
      proposalRef: "review", bookRef: AIReadingTools.bookRef(book.contentSha256), author: "Author",
      synopsis: "New synopsis", tags: ["keep", " add ", "add", " "], tagsMode: .replace)
    let value = try XCTUnwrap(
      AICommittedResultDecoder.results(
        entry(
          try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.metadata(proposal))),
          name: "propose_book_metadata"), sessionID: owner
      ).first)
    await registry.openResult(value)
    guard case .metadata(let review) = registry.review(value.id)?.body else {
      return XCTFail("Missing review")
    }
    XCTAssertEqual(review.fields.first(where: { $0.kind == .tags })?.selectedTags, ["add"])
    XCTAssertEqual(registry.metadataChangeCount(value.id, review), 2)
    registry.editMetadata(value.id, kind: .synopsis, text: "Edited synopsis")
    registry.editMetadata(value.id, kind: .synopsis, selected: false)
    registry.editMetadata(value.id, kind: .tags, tag: "add")
    guard case .metadata(let deselected) = registry.review(value.id)?.body else {
      return XCTFail("Missing review")
    }
    XCTAssertEqual(registry.metadataChangeCount(value.id, deselected), 0)
    XCTAssertEqual(
      deselected.fields.first(where: { $0.kind == .synopsis })?.draft, "Edited synopsis")
    registry.editMetadata(value.id, kind: .synopsis, selected: true)
    registry.editMetadata(value.id, kind: .tags, tag: "remove")
    await registry.applyMetadata([value.id])
    let saved = try await reader.details(sha: book.contentSha256).metadata
    XCTAssertEqual(saved.synopsis, "Edited synopsis")
    XCTAssertEqual(saved.tags, ["keep"])
    registry.editMetadata(value.id, kind: .synopsis, text: "Discarded draft", selected: true)
    registry.closeResult(value.id)
    await registry.openResult(value)
    guard case .metadata(let reopened) = registry.review(value.id)?.body else {
      return XCTFail("Review missing after reopening")
    }
    XCTAssertEqual(
      reopened.fields.first { $0.kind == .synopsis }?.draft, "New synopsis",
      "unconfirmed draft must not replace canonical suggestion")
    XCTAssertEqual(reopened.fields.first { $0.kind == .synopsis }?.current, "Edited synopsis")
  }

  // S089: 跨书来源/非法名称不得执行重命名；名称全集归 Rust，Swift 仅测一次失败传播和一次错误 owner。
  func testMetadataRenameRejectsForeignBookAndInvalidNames() async throws {
    let (root, reader, book, _, shelf) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let registry = AIProposalRegistry(reader: reader)
    let files = try await reader.aiLibraryBooks(shelf)
    let file = try XCTUnwrap(files.first)
    let ref = AIReadingTools.ref("f", file.id)
    for name in ["", "../bad", ".hidden", "a/b", "a\\b", "a:b"] {
      do {
        _ = try await registry.metadataProposal(
          .init(
            bookRef: AIReadingTools.bookRef(book.contentSha256),
            rename: .init(fileRef: ref, name: name)))
        XCTFail("Accepted \(name)")
      } catch {}
    }
    do {
      _ = try await registry.metadataProposal(
        .init(
          bookRef: AIReadingTools.bookRef(String(repeating: "a", count: 64)),
          rename: .init(fileRef: ref, name: "Name")))
      XCTFail("Accepted wrong book")
    } catch {}
  }

  // S094: AI ensure-bookmark 重试幂等但用户 toggle 仍可删除；不能把两种操作合成同一开关。
  func testEnsureBookmarkRetriesPreserveOneOperationAndReaderToggleStillDeletes() async throws {
    let (root, reader, book, store, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await reader.ensureBookmark(book.id, at: 0)
    let again = try await reader.ensureBookmark(book.id, at: 0)
    XCTAssertEqual(first.id, again.id)
    let heads = try await store.candidates(key: book.contentSha256)
    XCTAssertEqual(heads[first.id]?.count, 1)
    let toggled = try await reader.toggleBookmark(book.id, at: 0)
    XCTAssertFalse(toggled)
    let remains = try await reader.hasBookmark(book.id, at: 0)
    XCTAssertFalse(remains)
  }

  // S096: 目录预览失败不消耗尚未提交的应用资格，可明确重试，取消后不可提交。
  func testReadyChapterPreviewActionFailureKeepsApplyAvailable() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var writes = 0
    var starts = 0
    let model = ChapterRebuildModel(
      bookID: book.id, reader: reader,
      start: { id in starts += 1; return try await reader.rebuildChapters(id) },
      preview: { _, _ in throw CocoaError(.fileReadUnknown) },
      commit: { job in
        writes += 1
        if writes == 1 { throw CocoaError(.fileWriteUnknown) }
        try await reader.applyRebuild(job)
      })
    await model.load()
    await model.load()
    XCTAssertEqual(starts, 1, "reappearing does not start another rebuild")
    XCTAssertNotNil(model.actionError)
    XCTAssertTrue(model.canApply)
    XCTAssertTrue(model.hasMore)
    let failed = await model.apply()
    XCTAssertFalse(failed)
    XCTAssertTrue(model.canApply)
    let saved = await model.apply()
    XCTAssertTrue(saved)
    XCTAssertEqual(writes, 2)
    let tools = ReaderWideTools()
    tools.beginEditing(.rebuild(model), presenter: .reader)
    for regular in [true, false, true] {
      _ = ReaderContainerPolicy.container(ReaderContainerMetrics(bounds: CGRect(x: 0, y: 0, width: 1400, height: 900), regular: regular), settings: defaultReaderSettings())
      model.startIfNeeded()
      XCTAssertTrue(model.canApply, "layout changes must not cancel the rebuild")
    }
    XCTAssertEqual(starts, 1)
    tools.finishEditing(try XCTUnwrap(tools.editor).id)
    XCTAssertFalse(model.canApply)
    let ignored = await model.apply()
    XCTAssertFalse(ignored)
    XCTAssertEqual(writes, 2)
  }

  // S104: 笔记建议未确认不写入，重开丢弃草稿并进入同一业务编辑入口。
  func testNoteReviewReopenDiscardsDraftAndUsesSharedEditorOnce() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Notes", listed: false))
    let registry = await registry(repository, reader: reader, owner: owner)
    let proposal = AINoteProposal(
      proposalRef: "note", bookRef: AIReadingTools.bookRef(book.contentSha256), kind: .note,
      startUtf8: 0, endUtf8: 9, note: "Original suggestion", markRef: nil)
    let original = entry(
      try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.notes(proposal))),
      name: "propose_note")
    try await append(original, repository: repository, owner: owner)
    let result = try XCTUnwrap(AICommittedResultDecoder.results(original, sessionID: owner).first)
    await registry.openResult(result)
    registry.editNote(result.id, text: "Discarded draft")
    registry.closeResult(result.id)
    await registry.openResult(result)
    guard case .note(let review) = registry.review(result.id)?.body else {
      return XCTFail("Missing note review")
    }
    XCTAssertEqual(review.draft, "Original suggestion")
    let unchanged = try await reader.annotations(book.id, start: 0, end: 9)
    XCTAssertTrue(unchanged.isEmpty)
    let baseline = try await reader.prepareAnnotation(book.id, start: 0, end: 9)
    _ = try await reader.saveNote(baseline, text: "Existing note")
    var applications = 0
    registry.beginApplication = { _ in
      applications += 1
      return UUID()
    }
    let requested = await registry.saveNote(result.id)
    let request = try XCTUnwrap(requested)
    let beforeCommit = applications
    XCTAssertEqual(request.edit.startUtf8, 0)
    XCTAssertEqual(request.edit.endUtf8, 9)
    let editor = NoteEditorModel(
      edit: request.edit, service: reader, aiCommit: registry.annotationHooks(result))
    await editor.loadConflicts()
    editor.text = "Confirmed edit"
    let saved = await editor.commit()
    XCTAssertTrue(saved)
    let repeated = await editor.commit()
    XCTAssertTrue(repeated)
    XCTAssertEqual(applications, beforeCommit + 1)
    let marks = try await reader.annotations(book.id, start: 0, end: 9)
    XCTAssertEqual(marks.count, 1)
    XCTAssertEqual(marks.first?.note, "Confirmed edit")
    XCTAssertNotNil(registry.feedback[result.id])
  }

  // S109: 封面审核选择取消不保存，重开同一候选仍可明确应用。
  func testCoverReviewDiscardsChoiceAndSameCandidateCanBeAppliedAgain() async throws {
    let (root, reader, book, _, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await AIRepository.open(inMemory: true)
    let owner = UUID().uuidString
    try await repository.create(.init(id: owner, title: "Cover", listed: false))
    await AIImageStore.shared.bind(owner, repository: repository)
    defer { Task { await AIImageStore.shared.forget(owner) } }
    let image = try await AIImageStore.shared.save(pixels(), owner: owner)
    let proposal = AICoverProposal(
      proposalRef: "cover", bookRef: AIReadingTools.bookRef(book.contentSha256), attachment: image,
      origin: .unknown)
    let registry = await registry(repository, reader: reader, owner: owner)
    let result = entry(
      try AIAgentEntry.json(AIToolResponse(data: AIProposalSnapshot.cover(proposal))),
      name: "propose_cover")
    try await append(result, repository: repository, owner: owner)
    let value = try XCTUnwrap(AICommittedResultDecoder.results(result, sessionID: owner).first)
    let id = value.id
    await registry.openResult(value)
    let first = await registry.setCover(id, attachmentRef: image.id)
    XCTAssertTrue(first)
    registry.closeResult(id)
    let base = try await reader.details(sha: book.contentSha256).metadata
    var manual = base
    manual.cover = nil
    try await reader.saveMetadata(base: base, edited: manual)
    let reopened = await self.registry(repository, reader: reader, owner: owner)
    let loaded = try await repository.history(owner)
    await reopened.openResult(
      try XCTUnwrap(loaded.flatMap { AICommittedResultDecoder.results($0, sessionID: owner) }.first)
    )
    guard case .cover(let fresh) = reopened.review(id)?.body else {
      return XCTFail("Fresh cover review missing")
    }
    XCTAssertEqual(fresh.candidateAssetIDs, [image.id])
    let second = await reopened.setCover(id, attachmentRef: image.id)
    XCTAssertTrue(second)
    let actual = try await reader.details(sha: book.contentSha256).metadata
    XCTAssertNotNil(actual.cover)
    let history = try await repository.history(owner, limit: nil)
    XCTAssertEqual(history.map(\.id), [result.id])
  }
}
