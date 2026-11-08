import UniformTypeIdentifiers
import XCTest

@testable import Moonread

final class LibraryDropTests: LibraryDropFixture {
  // S253: 文件移动目标不能为自身/后代或不可用源；当前 Swift policy 未与 Rust 共享，保留到生产规则迁移完成，禁止提前删覆盖。
  func testMovePolicyUsesPathSegments() {
    let folder = entry("a", directory: true)
    for path in ["", "a", "a/child"] {
      XCTAssertFalse(
        LibraryDropPolicy.canMove(
          folder, to: .init(shelfID: "builtin", path: path), available: true))
    }
    XCTAssertTrue(
      LibraryDropPolicy.canMove(folder, to: .init(shelfID: "builtin", path: "ab"), available: true))
    XCTAssertTrue(
      LibraryDropPolicy.canMove(folder, to: .init(shelfID: "external", path: "a"), available: true))
    XCTAssertFalse(
      LibraryDropPolicy.canMove(folder, to: .init(shelfID: "external"), available: false))
    XCTAssertFalse(
      LibraryDropPolicy.canMove(
        entry("a/book.txt"), to: .init(shelfID: "builtin", path: "a"), available: true))
  }

  // S254: 拖放准入只接受明确 TXT 元数据且拒绝混合来源批次，不触发 provider 读取。
  func testCandidateNamesAndTypesAreExplicitMetadata() async throws {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, visibility: .all
    ) { completion in
      completion(Data("Named text".utf8), nil)
      return nil
    }
    for name in [
      nil, "", "book", "book.pdf", "../book.txt", "/book.txt", ".hidden.txt", "a:b.txt", "a\0.txt",
    ] as [String?] {
      provider.suggestedName = name
      XCTAssertNil(
        LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin")),
        "\(String(describing: name))")
    }
    provider.suggestedName = "book.TXT"
    XCTAssertEqual(
      LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin"))?.fileName, "book.TXT")
    XCTAssertNil(LibraryDropPolicy.candidate(provider, at: .init(shelfID: "external")))
    let string = NSItemProvider(object: "Selected text" as NSString)
    XCTAssertNil(LibraryDropPolicy.candidate(string, at: .init(shelfID: "builtin")))
    let image = NSItemProvider()
    image.suggestedName = "image.txt"
    image.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) {
      completion in
      completion(Data(), nil)
      return nil
    }
    XCTAssertNil(LibraryDropPolicy.candidate(image, at: .init(shelfID: "builtin")))
    do {

      let f = try await fixture()
      defer { f.remove() }
      let model = f.model()
      try await model.reload()
      let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
      let gate = DropPayloadGate(
        XCTestExpectation(description: "not awaited: metadata-only provider"))
      let internalProvider = gate.provider()
      let external = fileProvider(try f.write("external.txt"), name: "external.txt")
      XCTAssertEqual(delegate.operation([internalProvider]), .move)
      XCTAssertEqual(delegate.operation([external]), .copy)
      XCTAssertEqual(delegate.operation([internalProvider, external]), .forbidden)
      XCTAssertFalse(delegate.accept([internalProvider, external]))
      XCTAssertTrue(model.canAcceptFileWork)
      XCTAssertEqual(delegate.operation([]), .forbidden)
      let unavailable = LibraryShelfDropDelegate(
        model: model, destination: .init(shelfID: "unknown"))
      XCTAssertEqual(unavailable.operation([internalProvider]), .forbidden)
      XCTAssertEqual(unavailable.operation([external]), .forbidden)
      XCTAssertFalse(gate.loaded)

    }
  }

  // S255: 应用在 provider 临时文件生命周期内复制原字节到自有暂存；文件与 named-data 各一类输入。
  func testCopyAndOpenInPlaceFilesUseAdmittedNameAndOriginalBytes() async throws {
    let f = try await fixture()
    defer { f.remove() }
    let source = try f.write("temporary-name.txt")
    for options in [NSItemProviderFileOptions(), .openInPlace] {
      let provider = fileProvider(source, name: "admitted.TXT", options: options)
      XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
      let candidate = try XCTUnwrap(
        LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin")))
      let file = try await LibraryDropFile.load(candidate)
      XCTAssertEqual(file.url.lastPathComponent, "admitted.TXT")
      XCTAssertEqual(try Data(contentsOf: file.url), try Data(contentsOf: source))
      file.finish()
      XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
    }
    XCTAssertNil(
      LibraryDropPolicy.candidate(fileProvider(source, name: nil), at: .init(shelfID: "builtin")))
    let data = Data([0xc4, 0xe3, 0xba, 0xc3])
    let provider = NSItemProvider()
    provider.suggestedName = "named.txt"
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, visibility: .all
    ) { done in
      done(data, nil)
      return nil
    }
    let candidate = try XCTUnwrap(
      LibraryDropPolicy.candidate(provider, at: .init(shelfID: "builtin")))
    let staged = try await LibraryDropFile.load(candidate)
    defer { staged.finish() }
    XCTAssertEqual(
      try Data(contentsOf: staged.url), data, "named data must preserve original decoder bytes")
  }

  // S258: 准备部分失败回收本次暂存、不导入半批内容且释放 owner。
  func testPreparationFailureCleansPartialStagingAndReportsError() async throws {
    let f = try await fixture()
    defer { f.remove() }
    let baseline = stagingDirectories()
    let first = DropProviderGate(expectation(description: "first requested"))
    let second = DropProviderGate(expectation(description: "second requested"))
    let model = f.model()
    try await model.reload()
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([first.provider(name: "first.txt"), second.provider(name: "second.txt")]),
        at: .init(shelfID: "builtin")))
    await fulfillment(of: [first.requested], timeout: 3)
    first.complete(try f.write("first.txt"))
    await fulfillment(of: [second.requested], timeout: 3)
    XCTAssertFalse(stagingDirectories().subtracting(baseline).isEmpty)
    second.complete(error: CocoaError(.fileReadNoPermission))
    await model.waitForFileWork()
    XCTAssertNotNil(model.error)
    XCTAssertTrue(model.canAcceptFileWork)
    XCTAssertEqual(stagingDirectories(), baseline)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("first.txt").path))
  }

  // S259: 取消释放当前任务，旧 provider 晚到不能重启或覆盖新任务。
  func testCancellationReleasesPreparationAndLateProviderCannotRestartIt() async throws {
    let f = try await fixture()
    defer { f.remove() }
    let model = f.model()
    try await model.reload()
    let old = DropProviderGate(expectation(description: "cancelled provider"))
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([old.provider(name: "old.txt")]), at: .init(shelfID: "builtin")))
    await fulfillment(of: [old.requested], timeout: 3)
    model.cancelFileWork()
    await model.waitForFileWork()
    XCTAssertTrue(model.canAcceptFileWork)
    XCTAssertNil(model.error)
    let current = DropProviderGate(expectation(description: "current provider"))
    XCTAssertTrue(
      model.acceptDrop(
        .importProviders([current.provider(name: "current.txt")]), at: .init(shelfID: "builtin")))
    await fulfillment(of: [current.requested], timeout: 3)
    old.complete(try f.write("old.txt"))
    XCTAssertFalse(model.canAcceptFileWork)
    current.complete(try f.write("current.txt"))
    await model.waitForFileWork()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("old.txt").path))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("current.txt").path))
    XCTAssertNil(model.error)
  }

  // S260: 实际交付文件仍须是 TXT 普通文件，伪装扩展名/目录不得入书架；ShareInbox 的独立防御入口用共同样例保留一个反例。
  func testWrongExtensionAndDirectoryAreVisibleFailures() async throws {
    let f = try await fixture()
    defer { f.remove() }
    let wrong = try f.write("wrong.pdf")
    let directory = f.root.appendingPathComponent("directory.txt")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = f.model()
    try await model.reload()
    for source in [wrong, directory] {
      XCTAssertTrue(
        model.acceptDrop(
          .importProviders([CallbackURLProvider(source)]), at: .init(shelfID: "builtin")))
      await model.waitForFileWork()
      XCTAssertNotNil(model.error)
      XCTAssertTrue(model.canAcceptFileWork)
      model.error = nil
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("output.txt").path))
    do {

      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let inbox = ShareInbox(root: root.appendingPathComponent("inbox"))
      defer { try? FileManager.default.removeItem(at: root) }
      let draft = try ShareInbox.Draft(in: inbox)
      defer { draft.discard() }
      for name in ["valid.txt", "skipped.pdf"] {
        let source = root.appendingPathComponent(name)
        let bytes = Data("Original file URL fixture".utf8)
        try bytes.write(to: source)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
          forTypeIdentifier: UTType.fileURL.identifier, visibility: .all
        ) { completion in
          completion(source.dataRepresentation, nil)
          return nil
        }
        do {
          let item = try await draft.load(provider)
          XCTAssertEqual(name, "valid.txt")
          XCTAssertEqual(try Data(contentsOf: item.url(in: draft.directory)), bytes)
        } catch let skipped as ShareInbox.SkippedFile {
          XCTAssertEqual(skipped.name, "skipped.pdf")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
      }

    }
  }

  // S264: 执行前重新验证源/目的地身份，陈旧或缺失目标不写文件且释放 owner。
  func testLookupIsOwnedAndChangedMoveRelationReportsFailure() async throws {
    let f = try await fixture()
    defer { f.remove() }
    try Data("Source".utf8).write(to: f.books.appendingPathComponent("source.txt"))
    try await f.service.scanLibraryShelf("builtin")
    try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "target")
    let entries = try await f.service.libraryEntries(.init(shelfID: "builtin"))
    let source = try XCTUnwrap(entries.first { !$0.directory })
    let gate = DropEntryGate(expectation(description: "lookup entered"))
    let model = f.model(lookup: { id in
      await gate.wait()
      return try await f.service.libraryEntry(id)
    })
    try await model.reload()
    let destination = LibraryLocation(shelfID: "builtin", path: "target")
    XCTAssertTrue(model.acceptDrop(.moveIDs([source.id]), at: destination))
    XCTAssertTrue(model.runningFileBatch)
    await fulfillment(of: [gate.requested], timeout: 3)
    XCTAssertFalse(model.acceptDrop(.moveIDs([source.id]), at: destination))
    try await f.service.moveLibraryItem(source, to: destination, replace: false)
    gate.release()
    await model.waitForFileWork()
    XCTAssertNotNil(model.error)
    XCTAssertTrue(model.canAcceptFileWork)
    // A missing source is rejected without retaining the work owner.
    do {

      let f = try await fixture()
      defer { f.remove() }
      let model = f.model()
      try await model.reload()
      XCTAssertTrue(model.acceptDrop(.moveIDs(["gone"]), at: .init(shelfID: "builtin")))
      await model.waitForFileWork()
      XCTAssertNotNil(model.error)
      XCTAssertTrue(model.canAcceptFileWork)
      model.error = nil
      let gate = DropProviderGate(expectation(description: "provider before invalidation"))
      XCTAssertTrue(
        model.acceptDrop(
          .importProviders([gate.provider(name: "book.txt")]), at: .init(shelfID: "builtin")))
      await fulfillment(of: [gate.requested], timeout: 3)
      try f.core.setLibraryShelfError(shelfId: "builtin", message: "Unavailable")
      try await model.reload()
      gate.complete(try f.write("book.txt"))
      await model.waitForFileWork()
      XCTAssertNotNil(model.error)
      XCTAssertTrue(model.canAcceptFileWork)
      XCTAssertFalse(model.canAcceptDrop(at: .init(shelfID: "builtin")))
      XCTAssertFalse(model.canAcceptDrop(at: .init(shelfID: "unknown")))

    }
  }

  // S266: 内部 drag payload 的 file ID 进入当前路径解析，不误作外部复制；保留一次 adapter 接线断言。
  func testPrivatePayloadHomeMoveUsesModelAdmissionAndCurrentID() async throws {
    let f = try await fixture()
    defer { f.remove() }
    try await f.service.createLibraryFolder(at: .init(shelfID: "builtin"), name: "child")
    try Data("Source".utf8).write(to: f.books.appendingPathComponent("child/before.txt"))
    try await f.service.scanLibraryShelf("builtin")
    let entries = try await f.service.libraryEntries(.init(shelfID: "builtin", path: "child"))
    let source = try XCTUnwrap(entries.first)
    try await f.service.renameLibraryItem(source, name: "after.txt", replace: false)
    let provider = try LibraryDragPayload(fileID: source.id).provider()
    let model = f.model()
    try await model.reload()
    let delegate = LibraryShelfDropDelegate(model: model, destination: .init(shelfID: "builtin"))
    XCTAssertEqual(delegate.operation([provider]), .move)
    XCTAssertFalse(model.acceptDrop(.importProviders([provider]), at: .init(shelfID: "builtin")))
    XCTAssertTrue(delegate.accept([provider]))
    XCTAssertTrue(model.busy)
    await model.waitForFileWork()
    XCTAssertNil(model.error)
    XCTAssertTrue(model.path.isEmpty)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("after.txt").path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: f.books.appendingPathComponent("child/after.txt").path)
    )
  }
}
