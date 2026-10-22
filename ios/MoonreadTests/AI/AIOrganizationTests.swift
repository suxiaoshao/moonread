import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

final class AIOrganizationTests: BookAIFixture {
  // S092: 临时节点引用不能碰撞真实/保留引用，拒绝发生在任何文件准备前。
  func testOrganizationTemporaryRefsRejectRealAndReservedCollisionsBeforePreparation() async throws
  {
    let (root, reader, _, _, shelf) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entries = try await reader.allLibraryBooks(shelf)
    let file = AIReadingTools.ref("f", try XCTUnwrap(entries.first).id)
    let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
    for ref in [
      file, scope, "source:any", "b:any", "d:any", "s:any", "mark:any", "session:any", "web:any",
      "asset:any", "cursor:any", "proposal:any", "preview:any", "c:any", "v:any",
    ] {
      let input = AIOrganizationInput(
        scopeRef: scope, folders: [.init(temporaryRef: ref, parentRef: scope, name: "New")],
        placements: [.init(fileRef: file, parentRef: ref, name: nil)])
      XCTAssertThrowsError(try input.validate())
      let plan = AIOrganizationPlan(
        proposal: .init(proposalRef: "proposal", previewRef: "preview", input: input),
        scope: .init(shelfID: shelf), reader: reader)
      do {
        try await plan.prepare()
        XCTFail("Colliding reference prepared")
      } catch {}
      XCTAssertTrue(plan.nodes.isEmpty)
    }
    let valid = AIOrganizationInput(
      scopeRef: scope,
      folders: [
        .init(temporaryRef: "source", parentRef: scope, name: "Source"),
        .init(temporaryRef: "f", parentRef: "source", name: "Nested"),
        .init(temporaryRef: "planned:folder", parentRef: scope, name: "Other"),
      ],
      placements: [.init(fileRef: file, parentRef: "f", name: nil)])
    XCTAssertNoThrow(try valid.validate())
    let plan = AIOrganizationPlan(
      proposal: .init(proposalRef: "valid", previewRef: "preview", input: valid),
      scope: .init(shelfID: shelf), reader: reader)
    try await plan.prepare()
    XCTAssertEqual(Set(plan.nodes.map(\.id)).count, 4)
    XCTAssertTrue(plan.nodes.allSatisfy { $0.conflict == nil })
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appending(path: "library/Source").path))
    let duplicate = AIOrganizationInput(
      scopeRef: scope,
      folders: [
        .init(temporaryRef: "same", parentRef: scope, name: "One"),
        .init(temporaryRef: "same", parentRef: scope, name: "Two"),
      ], placements: [])
    XCTAssertThrowsError(try duplicate.validate())
  }

  // S097: 第一批执行腾出的名称必须经第二次明确确认才能使用，不隐式扩大用户批准范围。
  func testOrganizationVacatedNameRequiresSecondConfirmedExecution() async throws {
    let (root, reader, _, _, shelf) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "library")
    try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
    try await reader.refreshLibraryShelf(shelf)
    let entries = try await reader.allLibraryBooks(shelf)
    let a = try XCTUnwrap(entries.first { $0.name == "book.txt" })
    let b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
    let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
    let aRef = AIReadingTools.ref("f", a.id)
    let bRef = AIReadingTools.ref("f", b.id)
    let input = AIOrganizationInput(
      scopeRef: scope, folders: [],
      placements: [
        .init(fileRef: bRef, parentRef: scope, name: "book.txt"),
        .init(fileRef: aRef, parentRef: scope, name: "C.txt"),
      ])
    let plan = AIOrganizationPlan(
      proposal: .init(proposalRef: "p", previewRef: "v", input: input),
      scope: .init(shelfID: shelf), reader: reader)
    try await plan.prepare()
    XCTAssertEqual(plan.nodes.first?.conflict, .occupied)
    let firstConfirmation = plan.eligibleNodeIDs
    XCTAssertEqual(firstConfirmation, [aRef])
    _ = await plan.executeRemaining(confirmedIDs: firstConfirmation)
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "C.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "book.txt").path))
    let remaining = try XCTUnwrap(plan.nodes.first { $0.id == bRef })
    XCTAssertNil(remaining.result)
    XCTAssertNil(remaining.conflict)
    XCTAssertEqual(plan.eligibleNodeIDs, [bRef])
    _ = await plan.executeRemaining(confirmedIDs: firstConfirmation)
    XCTAssertNil(remaining.result, "The earlier confirmation never enrolls newly unblocked B")
    _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
    XCTAssertEqual(remaining.result?.stage, .completed)
    XCTAssertEqual(
      try String(contentsOf: library.appending(path: "book.txt"), encoding: .utf8), "B")
    XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
  }

  // S098: 已移动但索引失败不能再次移动；按不可重放结果限制重试，保留原源占用约束。
  func testOrganizationOwnStagesPreserveSourceOccupancyAndNonReplayableOutcomes() async throws {
    for stage in [AIFileExecutionStage.movedButIndexFailed, .copiedSourceRemains, .uncertain] {
      let (root, reader, _, _, shelf) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let library = root.appending(path: "library")
      try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
      try await reader.refreshLibraryShelf(shelf)
      let entries = try await reader.allLibraryBooks(shelf)
      let a = try XCTUnwrap(entries.first { $0.name == "book.txt" })
      let b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
      let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
      let aRef = AIReadingTools.ref("f", a.id)
      let bRef = AIReadingTools.ref("f", b.id)
      var calls = 0
      let input = AIOrganizationInput(
        scopeRef: scope, folders: [],
        placements: [
          .init(fileRef: aRef, parentRef: scope, name: "C.txt"),
          .init(fileRef: bRef, parentRef: scope, name: "book.txt"),
        ])
      let plan = AIOrganizationPlan(
        proposal: .init(proposalRef: "p", previewRef: "v", input: input),
        scope: .init(shelfID: shelf), reader: reader,
        moveItem: { entry, destination, name, check in
          calls += 1
          if stage == .movedButIndexFailed {
            let actual = await reader.aiMoveLibraryItem(
              entry, to: destination, name: name, check: check)
            XCTAssertEqual(actual.stage, .completed)
          } else if stage == .copiedSourceRemains {
            // Isolated fixture models a verified destination with source removal failure.
            do {
              try FileManager.default.copyItem(
                at: library.appending(path: entry.relativePath), to: library.appending(path: name))
            } catch {
              XCTFail("Fixture copy failed: \(error)")
              return .init(id: entry.id, stage: .notMoved)
            }
          }
          return .init(id: entry.id, stage: stage)
        })
      try await plan.prepare()
      _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
      let result = try XCTUnwrap(plan.nodes.first { $0.id == aRef }?.result)
      XCTAssertEqual(result.stage, stage)
      XCTAssertFalse(result.canExecuteRemaining)
      if stage == .movedButIndexFailed {
        XCTAssertEqual(plan.eligibleNodeIDs, [bRef])
      } else {
        XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.conflict, .occupied)
        XCTAssertTrue(plan.eligibleNodeIDs.isEmpty)
      }
      _ = await plan.executeRemaining(confirmedIDs: [aRef])
      XCTAssertEqual(calls, 1, "Known partial/uncertain work is never replayed")
    }
  }

  // S100: 计划确认后外部源/占用改变不得被刷新悄悄认可；再次执行前拒绝陈旧计划且原文件不动。
  func testCheckedOrganizationShowsOccupiedAndRejectsChangedSourceWithoutMoving() async throws {
    let (root, reader, _, _, shelf) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appending(path: "library")
    try "existing".write(
      to: library.appending(path: "occupied.txt"), atomically: true, encoding: .utf8)
    try await reader.refreshLibraryShelf(shelf)
    let libraryEntries = try await reader.allLibraryBooks(shelf)
    let entry = try XCTUnwrap(libraryEntries.first { $0.name == "book.txt" })
    let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
    let file = AIReadingTools.ref("f", entry.id)
    let input = AIOrganizationInput(
      scopeRef: scope, folders: [],
      placements: [.init(fileRef: file, parentRef: scope, name: "occupied.txt")])
    let plan = AIOrganizationPlan(
      proposal: .init(proposalRef: "p", previewRef: "v", input: input),
      scope: .init(shelfID: shelf), reader: reader)
    try await plan.prepare()
    XCTAssertEqual(plan.nodes.first?.conflict, .occupied)
    plan.nodes.first?.name = "renamed.txt"
    plan.recomputeConflicts()
    XCTAssertNil(plan.nodes.first?.conflict)
    try "changed bytes".write(
      to: library.appending(path: "book.txt"), atomically: true, encoding: .utf8)
    let executions = await plan.execute()
    let result = try XCTUnwrap(executions.first)
    XCTAssertEqual(result.stage, .notMoved)
    XCTAssertEqual(result.reason, .changed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "book.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: library.appending(path: "renamed.txt").path))
    do {

      let (root, reader, _, _, shelf) = try await fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let library = root.appending(path: "library")
      try "B".write(to: library.appending(path: "B.txt"), atomically: true, encoding: .utf8)
      try "occupied".write(
        to: library.appending(path: "occupied.txt"), atomically: true, encoding: .utf8)
      try await reader.refreshLibraryShelf(shelf)
      let entries = try await reader.allLibraryBooks(shelf)
      let a = try XCTUnwrap(entries.first { $0.name == "book.txt" })
      let b = try XCTUnwrap(entries.first { $0.name == "B.txt" })
      let scope = AIReadingTools.scopeRef(shelfID: shelf, path: "")
      let aRef = AIReadingTools.ref("f", a.id)
      let bRef = AIReadingTools.ref("f", b.id)
      let input = AIOrganizationInput(
        scopeRef: scope, folders: [],
        placements: [
          .init(fileRef: aRef, parentRef: scope, name: "C.txt"),
          .init(fileRef: bRef, parentRef: scope, name: "D.txt"),
        ])
      let plan = AIOrganizationPlan(
        proposal: .init(proposalRef: "p", previewRef: "v", input: input),
        scope: .init(shelfID: shelf), reader: reader,
        moveItem: { entry, destination, name, check in
          let result = await reader.aiMoveLibraryItem(
            entry, to: destination, name: name, check: check)
          if entry.id == a.id {
            do {
              try "external".write(
                to: library.appending(path: "external.txt"), atomically: true, encoding: .utf8)
            } catch { XCTFail("Fixture external change failed: \(error)") }
          }
          return result
        })
      try await plan.prepare()
      _ = await plan.executeRemaining(confirmedIDs: plan.eligibleNodeIDs)
      XCTAssertEqual(plan.nodes.first { $0.id == aRef }?.result?.stage, .completed)
      XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.result?.stage, .notMoved)
      XCTAssertEqual(plan.nodes.first { $0.id == bRef }?.result?.reason, .changed)
      XCTAssertEqual(
        try String(contentsOf: library.appending(path: "occupied.txt"), encoding: .utf8), "occupied"
      )
      XCTAssertTrue(FileManager.default.fileExists(atPath: library.appending(path: "B.txt").path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: library.appending(path: "D.txt").path))

    }
  }
}
