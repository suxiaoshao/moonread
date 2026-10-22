import Observation
import SQLite3
import SwiftData
import SwiftUI
import UIKit
import XCTest

@testable import Moonread

final class OnboardingStateTests: ReaderIntegrationFixture {
  // S327: 首次设置先保存用户同步选择再完成引导，云不可用仍能本地继续。
  @MainActor func testIntroductionPersistsSyncChoiceBeforeCompletionAndImmediateReload()
    async throws
  {
    for choice in [true, false] {
      let (root, service, _, suite) = try introductionFixture()
      defer {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
      }
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      await service.setCloudSyncRequested(!choice)
      let onboarding = Onboarding(defaults: defaults, enabled: false, showIntroduction: true)
      let cloud = CloudStore(
        coordinator: CloudSyncCoordinator(service: service, available: false, observeEvents: false))
      let published = expectation(
        description: "completion is published after the sync intent is persisted")
      withObservationTracking {
        _ = onboarding.completed
      } onChange: {
        XCTAssertEqual(
          UserDefaults(suiteName: suite)?.bool(forKey: "Moonread.userCloudEnabled"), choice)
        published.fulfill()
      }
      var activation: Task<Void, Never>?
      onboarding.completeIntroduction(destination: .library) {
        activation = cloud.saveIntroductionChoice(choice)
      }
      // No background-task wait after completion: model a relaunch now.
      let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      XCTAssertTrue(
        Onboarding(defaults: reloadedDefaults, enabled: false, showIntroduction: true).completed)
      XCTAssertEqual(reloadedDefaults.bool(forKey: "Moonread.userCloudEnabled"), choice)
      XCTAssertEqual(cloud.status.requested, choice)
      await fulfillment(of: [published], timeout: 1)
      await activation?.value
    }
  }

  // S331: 样例只在确认的空目录落一次且不覆盖已有书/新根；保留已有文件反例和新空根正例。
  @MainActor func testIntroductionStoryNeverOverwritesExistingBooksOrChangedRoot() async throws {
    let (root, service, core, suite) = try introductionFixture()
    defer {
      try? FileManager.default.removeItem(at: root)
      UserDefaults.standard.removePersistentDomain(forName: suite)
    }
    let file = root.appendingPathComponent("library/原创合成.txt")
    try "第一章 测试\n已有合成正文。".write(to: file, atomically: true, encoding: .utf8)
    try await service.scanLibraryShelf("builtin")
    let model = LibraryModel(service: service, prepareLibrary: {}, cloudDiscoveryRequired: false)
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    let story = try await model.welcomeStoryForIntroduction()
    XCTAssertNil(story)
    XCTAssertEqual(try core.sourceFiles(shelfId: "builtin").map(\.relativePath), ["原创合成.txt"])
    do {
      _ = try await service.welcomeStory(expectedRoot: root)
      XCTFail("A changed root must be rejected")
    } catch {}
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "第一章 测试\n已有合成正文。")
    // A fresh empty root gets the original sample only once.
    do {

      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: temporary) }
      let data = temporary.appendingPathComponent("db")
      let root = temporary.appendingPathComponent("books")
      let core = try ReaderCore(dataDirectory: data.path)
      let service = ReaderService(
        core: core, libraryDirectory: root,
        libraryDeletion: { url, _ in try TrashIOProbe.move(url) })
      try await service.prepareLibrary()
      try await service.refreshLibrary()
      let entries = try await service.libraryEntries(LibraryLocation(shelfID: "builtin"))
      XCTAssertEqual(entries.map(\.name), ["月光下的归途.txt"])
      XCTAssertTrue(try core.querySnapshot(json: "{}").recentLibraryEntries(limit: 3).isEmpty)
      XCTAssertTrue(
        try core.sourceFiles(shelfId: "builtin").allSatisfy { $0.bookId == nil },
        "Creating the file must not import it or mark it as read")
      let file = root.appendingPathComponent(entries[0].name)
      XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("第三章 灯下"))
      try await service.deleteLibraryItem(entries[0])
      let reopened = ReaderService(
        core: try ReaderCore(dataDirectory: data.path), libraryDirectory: root)
      try await reopened.prepareLibrary()
      try await reopened.refreshLibrary()
      let remaining = try await reopened.libraryEntries(LibraryLocation(shelfID: "builtin"))
      XCTAssertTrue(remaining.isEmpty, "Deleting the welcome book must survive reinitialization")
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

    }
  }
}
