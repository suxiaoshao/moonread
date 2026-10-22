import AISDKProvider
import AISDKProviderUtils
import SwiftData
import UIKit
import XCTest

@testable import Moonread

@MainActor class AIRepositoryFixture: XCTestCase {
  func fileRepository() async throws -> AIRepository {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return try await AIRepository.open(url: directory.appending(path: "session.store"))
  }
  func pixels() -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 3)).pngData { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 3))
    }
  }
  func toolEntry(sequence: Int, name: String, output: JSONValue) -> AIAgentEntry {
    .init(
      sequence: sequence, turn: "turn", provider: "fixture", model: "fixture",
      message: .object([
        "role": .string("tool"),
        "content": .array([
          .object([
            "type": .string("tool-result"), "toolCallId": .string("call"),
            "toolName": .string(name),
            "output": .object(["type": .string("json"), "value": output]),
          ])
        ]),
      ]))
  }
}
