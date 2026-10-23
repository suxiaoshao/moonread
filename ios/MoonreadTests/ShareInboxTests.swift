import UniformTypeIdentifiers
import XCTest

@testable import Moonread

final class ShareInboxTests: ShareInboxFixture {
  // S290: 发布版本化清单后接收进程消失，主 App 仍能消费完整原字节且只消费一次；不启动扩展宿主。
  func testRawBytesPublishRecoverAndConsume() async throws {
    let (root, inbox) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("原稿.txt")
    // GBK bytes, intentionally not valid UTF-8.
    let original = Data([0xb5, 0xda, 0xd2, 0xbb, 0xbb, 0xb0, 0x0d, 0x0a, 0xd4, 0xc2, 0xb9, 0xe2])
    try original.write(to: source)
    let draft = try ShareInbox.Draft(in: inbox)
    let first = try draft.copy(source, suggestedName: source.lastPathComponent, plainText: true)
    let second = try draft.copy(source, suggestedName: source.lastPathComponent, plainText: true)
    XCTAssertTrue(
      try inbox.scan().batches.isEmpty, "Files are invisible until the manifest is published")
    try draft.publish(items: [first, second], skippedNames: ["photo.pdf"])
    let batch = try XCTUnwrap(try ShareInbox(root: inbox.root).scan().batches.first)
    XCTAssertEqual(batch.manifest.schemaVersion, 1)
    XCTAssertEqual(batch.manifest.skippedNames, ["photo.pdf"])
    XCTAssertEqual(batch.files.count, 2)
    XCTAssertEqual(try Data(contentsOf: first.url(in: batch.directory)), original)
    do { _ = LibraryImportFile(url: first.url(in: batch.directory), inbox: (batch, first)) }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: first.url(in: batch.directory).path),
      "Releasing an owner is not user cancellation")
    LibraryImportFile(url: first.url(in: batch.directory), inbox: (batch, first)).finish()
    XCTAssertEqual(try inbox.scan().batches.first?.files, [second])
    LibraryImportFile(url: second.url(in: batch.directory), inbox: (batch, second)).finish()
    XCTAssertTrue(try inbox.scan().batches.isEmpty)
    XCTAssertEqual(try Data(contentsOf: source), original)
    let provider = NSItemProvider()
    provider.suggestedName = "data.txt"
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, visibility: .all
    ) { done in
      done(original, nil)
      return nil
    }
    let unreadable = NSItemProvider()
    unreadable.suggestedName = "unreadable.txt"
    unreadable.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { done in
      done(nil, false, CocoaError(.fileReadNoPermission))
      return nil
    }
    let providerDraft = try ShareInbox.Draft(in: inbox)
    let (items, skipped) = try await providerDraft.receive([provider, unreadable, provider])
    XCTAssertEqual(items.count, 2, "One I/O failure must not discard copies before or after it")
    XCTAssertEqual(skipped.count, 1)
    XCTAssertTrue(skipped[0].contains("unreadable.txt"))
    try providerDraft.publish(items: items, skippedNames: skipped)
    let recovered = try XCTUnwrap(try ShareInbox(root: inbox.root).scan().batches.first)
    for item in items {
      XCTAssertEqual(try Data(contentsOf: item.url(in: recovered.directory)), original)
      LibraryImportFile(url: item.url(in: recovered.directory), inbox: (recovered, item)).finish()
    }
    XCTAssertTrue(
      try inbox.scan().batches.isEmpty, "consuming again cannot rediscover the same manifest")
  }

  // S291: 未知/坏/空清单及无法证明归属的文件不被误回收，保留原件待后续版本处理。
  func testUnknownVersionAndMalformedManifestArePreserved() throws {
    let (root, inbox) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for data in [
      Data("{\"schemaVersion\":2,\"items\":[],\"skippedNames\":[]}".utf8), Data("broken".utf8),
      Data(
        "{\"schemaVersion\":1,\"items\":[{\"id\":\"00000000-0000-0000-0000-000000000000\",\"fileName\":\"../bad.txt\"}],\"skippedNames\":[]}"
          .utf8),
    ] {
      let draft = try ShareInbox.Draft(in: inbox)
      let manifest = draft.directory.appendingPathComponent("manifest.json")
      try data.write(to: manifest)
      let scan = try inbox.scan()
      XCTAssertTrue(scan.batches.isEmpty)
      XCTAssertFalse(scan.errors.isEmpty)
      XCTAssertEqual(try Data(contentsOf: manifest), data)
      draft.discard()
    }
    do {

      let (root, inbox) = try fixture()
      defer { try? FileManager.default.removeItem(at: root) }
      let draft = try ShareInbox.Draft(in: inbox)
      let file = draft.directory.appendingPathComponent("original.txt")
      try Data("Owned original staging fixture".utf8).write(to: file)
      try Data("{\"schemaVersion\":1,\"items\":[],\"skippedNames\":[]}".utf8).write(
        to: draft.directory.appendingPathComponent("manifest.json"))
      let scan = try inbox.scan()
      XCTAssertTrue(scan.batches.isEmpty)
      XCTAssertEqual(scan.errors.count, 1)
      XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

    }
  }

  // S294: 分享扩展批次准入检查每个 attachment，混入非 TXT 时拒绝；只保留一合法及一混合反例。
  func testActivationRuleFiltersEveryAttachment() throws {
    let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
    let info = try Data(
      contentsOf: plugins.appendingPathComponent("MoonreadShare.appex/Info.plist"))
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any])
    let extensionInfo = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
    let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
    let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
    let predicate = NSPredicate(format: rule)
    func accepts(_ types: [[String]]) -> Bool {
      predicate.evaluate(with: [
        "extensionItems": [["attachments": types.map { ["registeredTypeIdentifiers": $0] }]]
      ])
    }
    XCTAssertFalse(accepts([["public.plain-text"]]), "Selected text is not a shared file")
    XCTAssertTrue(accepts([["public.plain-text", "public.file-url"]]))
    XCTAssertTrue(
      accepts([
        ["public.utf8-plain-text", "public.file-url"], ["public.plain-text", "public.file-url"],
      ]))
    XCTAssertFalse(
      accepts([["public.utf8-plain-text", "public.file-url"], ["public.plain-text"]]),
      "Every attachment must be a file")
    XCTAssertTrue(accepts([["public.file-url"]]), "File-URL-only hosts are checked at runtime")
    XCTAssertFalse(accepts([["com.adobe.pdf", "public.file-url"]]))
    XCTAssertFalse(accepts([["public.plain-text"], ["com.adobe.pdf", "public.file-url"]]))
    XCTAssertFalse(accepts([["public.url"]]))
    XCTAssertFalse(accepts([]))
  }

  // S295: inbox 消费冲突取消保留待处理原件，再次明确继续可完成；与主 App 普通导入共用流程但持久队列边界不同。
  func testSharedRootImportConflictsCancelAndResume() async throws {
    let (root, inbox) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let books = root.appendingPathComponent("books")
    let service = ReaderService(core: core, libraryDirectory: books)
    let model = LibraryModel(service: service, fileMutationReload: {}, prepareSource: { _, _ in })
    let loaded = await model.load()
    XCTAssertTrue(loaded)
    let first = root.appendingPathComponent("first.txt")
    let second = root.appendingPathComponent("second.txt")
    let bytes = Data("Original UTF8 fiction only.\n".utf8)
    try bytes.write(to: first)
    try bytes.write(to: second)
    _ = try await service.receiveLibraryFile(first, at: .init(shelfID: "builtin"), replace: false)
    let draft = try ShareInbox.Draft(in: inbox)
    let item1 = try draft.copy(first, suggestedName: "first.txt", plainText: true)
    let item2 = try draft.copy(second, suggestedName: "second.txt", plainText: true)
    try draft.publish(items: [item1, item2], skippedNames: ["skip.pdf"])
    await model.receiveSharedInbox(inbox)
    await model.waitForFileWork()
    let decision = try XCTUnwrap(model.pendingDecision)
    XCTAssertTrue(FileManager.default.fileExists(atPath: item1.url(in: draft.directory).path))
    await model.receiveSharedInbox(inbox)  // foreground during a paused conflict must not duplicate input
    await model.resolveDecision(decision.id, accepting: false)
    await model.waitForFileWork()
    XCTAssertNil(model.pendingDecision)
    XCTAssertEqual(try Data(contentsOf: books.appendingPathComponent("first.txt")), bytes)
    XCTAssertEqual(try Data(contentsOf: books.appendingPathComponent("second.txt")), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
    XCTAssertTrue(try inbox.scan().batches.isEmpty)
    XCTAssertNotNil(model.sharedImportResult)
    XCTAssertTrue(model.sharedImportResult?.contains("skip.pdf") == true)
    XCTAssertFalse(
      model.libraryPath.contains { $0.isReader }, "Multiple input files do not open a reader")
    XCTAssertEqual(try Data(contentsOf: first), bytes)
  }

  // S296: 扩展必须在 provider 回调返回前复制临时 URL 内容，防文件失效造成丢书；只用自建短命 URL。
  func testProviderCopyFinishesBeforeTemporaryURLExpires() async throws {
    let (root, inbox) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("host.tmp")
    let bytes = Data([0xb5, 0xda, 0xd2, 0xbb, 0xbb, 0xb0])
    try bytes.write(to: source)
    let draft = try ShareInbox.Draft(in: inbox)
    defer { draft.discard() }
    let item = try await draft.load(EphemeralShareProvider(source))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    XCTAssertEqual(try Data(contentsOf: item.url(in: draft.directory)), bytes)
  }

  // S297: 分享取消或不支持输入不得发布/重建 inbox，也不得删除外部原件。
  func testCancellationDoesNotPublishOrRecreateAfterLateCallback() async throws {
    let (root, inbox) = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("Original cancellation fixture".utf8).write(to: source)
    let draft = try ShareInbox.Draft(in: inbox)
    let gate = ShareCallbackGate(expectation(description: "Provider requested"))
    let provider = gate.provider()
    let task = Task { try await draft.load(provider) }
    await fulfillment(of: [gate.requested], timeout: 3)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
    draft.discard()
    gate.callback?(source, false, nil)
    await Task.yield()
    XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    XCTAssertTrue(try inbox.scan().batches.isEmpty)
    let rejected = try ShareInbox.Draft(in: inbox)
    let unsupported = root.appendingPathComponent("source.pdf")
    try Data("Original".utf8).write(to: unsupported)
    XCTAssertThrowsError(
      try rejected.copy(unsupported, suggestedName: "source.pdf", plainText: false))
    rejected.discard()
    XCTAssertTrue(FileManager.default.fileExists(atPath: unsupported.path))
  }
}
