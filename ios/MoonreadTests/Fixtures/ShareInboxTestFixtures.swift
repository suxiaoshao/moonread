import UniformTypeIdentifiers
import XCTest

@testable import Moonread

/// A host-owned URL expires as soon as its file callback returns.
final class EphemeralShareProvider: NSItemProvider {
  let source: URL
  init(_ source: URL) {
    self.source = source
    super.init()
    suggestedName = "callback.txt"
    registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) {
      completion in
      completion(Data(), nil)
      return nil
    }
  }
  required init?(coder: NSCoder) { fatalError("Fixture only") }
  override func loadFileRepresentation(
    forTypeIdentifier typeIdentifier: String,
    completionHandler: @escaping @Sendable (URL?, Error?) -> Void
  ) -> Progress {
    completionHandler(source, nil)
    try? FileManager.default.removeItem(at: source)
    return Progress(totalUnitCount: 1)
  }
}

@MainActor final class ShareCallbackGate {
  let requested: XCTestExpectation
  var callback: (@Sendable (URL?, Bool, Error?) -> Void)?
  init(_ requested: XCTestExpectation) { self.requested = requested }
  func provider() -> NSItemProvider {
    let provider = NSItemProvider()
    provider.suggestedName = "delayed.txt"
    provider.registerFileRepresentation(
      forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all
    ) { completion in
      Task { @MainActor in
        self.callback = completion
        self.requested.fulfill()
      }
      return Progress(totalUnitCount: 1)
    }
    return provider
  }
}

@MainActor class ShareInboxFixture: XCTestCase {
  func fixture() throws -> (URL, ShareInbox) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, ShareInbox(root: root.appendingPathComponent("inbox")))
  }

}
