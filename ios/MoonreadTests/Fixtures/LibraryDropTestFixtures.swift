import UniformTypeIdentifiers
import XCTest

@testable import Moonread

/// Supplies the URL at our public callback boundary without Foundation renaming it.
final class CallbackURLProvider: NSItemProvider {
  let callbackURL: URL
  init(_ url: URL) {
    callbackURL = url
    super.init()
    suggestedName = "output.txt"
    registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) {
      completion in
      completion(Data(), nil)
      return nil
    }
  }
  required init?(coder: NSCoder) { fatalError("Not used by the fixture") }
  override func loadFileRepresentation(
    forTypeIdentifier typeIdentifier: String,
    completionHandler: @escaping @Sendable (URL?, Error?) -> Void
  ) -> Progress {
    completionHandler(callbackURL, nil)
    return Progress(totalUnitCount: 1)
  }
}

@MainActor final class DropProviderGate {
  let requested: XCTestExpectation
  var completion: (@Sendable (URL?, Bool, Error?) -> Void)?
  var progress: Progress?
  init(_ requested: XCTestExpectation) { self.requested = requested }
  func provider(name: String?, options: NSItemProviderFileOptions = []) -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = name
    provider.registerFileRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, fileOptions: options, visibility: .all
    ) { completion in
      let progress = Progress(totalUnitCount: 1)
      Task { @MainActor in
        self.completion = completion
        self.progress = progress
        self.requested.fulfill()
      }
      return progress
    }
    return provider
  }
  func complete(_ url: URL? = nil, error: Error? = nil) {
    let callback = completion
    completion = nil
    callback?(url, false, error)
    progress?.completedUnitCount = 1
  }
}

@MainActor final class DropPayloadGate {
  let requested: XCTestExpectation
  var completion: (@Sendable (Data?, Error?) -> Void)?
  private(set) var loaded = false
  init(_ requested: XCTestExpectation) { self.requested = requested }
  func provider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: UTType.moonreadLibraryItem.identifier, visibility: .ownProcess
    ) { completion in
      Task { @MainActor in
        self.completion = completion
        self.loaded = true
        self.requested.fulfill()
      }
      return Progress(totalUnitCount: 1)
    }
    return provider
  }
  func complete(_ data: Data?, error: Error? = nil) {
    let callback = completion
    completion = nil
    callback?(data, error)
  }
}

@MainActor final class DropEntryGate {
  let requested: XCTestExpectation
  var continuation: CheckedContinuation<Void, Never>?
  init(_ requested: XCTestExpectation) { self.requested = requested }
  func wait() async {
    await withCheckedContinuation {
      continuation = $0
      requested.fulfill()
    }
  }
  func release() {
    let value = continuation
    continuation = nil
    value?.resume()
  }
}

@MainActor class LibraryDropFixture: XCTestCase {
  struct Fixture {
    let root: URL, books: URL
    let core: ReaderCore
    let service: ReaderService
    func write(_ name: String) throws -> URL {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("Chapter 1\nSynthetic fixture only.\n".utf8).write(to: url)
      return url
    }
    @MainActor func model(lookup: (@MainActor (String) async throws -> LibraryEntry)? = nil)
      -> LibraryModel
    {
      LibraryModel(
        service: service, fileMutationReload: {}, prepareSource: { _, _ in },
        lookupDropEntry: lookup)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
  }
  func fixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let books = root.appendingPathComponent("books")
    let service = ReaderService(core: core, libraryDirectory: books)
    try await service.prepareLibrary()
    return Fixture(root: root, books: books, core: core, service: service)
  }
  func fileProvider(_ url: URL, name: String?, options: NSItemProviderFileOptions = [])
    -> NSItemProvider
  {
    let provider = NSItemProvider()
    provider.suggestedName = name
    provider.registerFileRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, fileOptions: options, visibility: .all
    ) { completion in
      completion(url, false, nil)
      return nil
    }
    return provider
  }
  func stagingDirectories() -> Set<URL> {
    Set(
      (try? FileManager.default.contentsOfDirectory(
        at: FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Drops"),
        includingPropertiesForKeys: nil)) ?? [])
  }
  func entry(_ path: String, directory: Bool = false) -> LibraryEntry {
    .init(
      id: path, shelfId: "builtin", shelfName: "Builtin", relativePath: path,
      parentPath: (path as NSString).deletingLastPathComponent,
      name: (path as NSString).lastPathComponent,
      directory: directory, size: 0, modified: 0, needsDownload: false, bookId: nil,
      positionUtf8: 0, byteCount: 0, chapterTitle: nil, childBookCount: 0, lastRead: 0,
      preferred: false, coverPreviews: [], metadata: nil, contentSha256: nil, readingIdentity: nil)
  }

}
