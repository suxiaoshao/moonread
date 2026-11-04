import AISDKProvider
import SwiftData
import XCTest

@testable import Moonread

@MainActor class AIReadingToolsFixture: XCTestCase {
  func fixture(paragraphs: Int = 8, text: String? = nil) async throws -> (
    URL, AppDataService, ImportText, UserDataStore, AIReadingTools
  ) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("book.txt")
    try (text ?? ("第一章 月\n\n" + String(repeating: "甲乙丙丁你好。\n", count: paragraphs) + "第二章 星\n再次阅读\n")).write(
      to: file, atomically: true, encoding: .utf8)
    let core = try ReaderCore(dataDirectory: root.appendingPathComponent("db").path)
    let book = try core.importBook(filePath: file.path, title: "Book")
    let container = try ModelContainer(
      for: UserDataStore.schema,
      configurations: [
        ModelConfiguration(
          schema: UserDataStore.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      ])
    let store = UserDataStore(modelContainer: container)
    let reader = AppDataService(
      core: core, sourceDefaultsSuite: "AI-\(root.lastPathComponent)",
      userStoreFactory: { _, _ in store })
    let shelf = try await reader.registerLibraryShelf(root)
    try await reader.refreshLibraryShelf(shelf)
    let fileEntry = try await reader.allLibraryBooks(shelf).first!
    try core.linkLibraryFile(fileId: fileEntry.id, bookId: book.id)
    return (root, reader, book, store, AIReadingTools(reader: reader))
  }
  func invoke(_ tools: AIReadingTools, _ name: String, _ args: [String: JSONValue])
    async throws -> JSONValue
  {
    let tool = try XCTUnwrap(tools.definitions().first { $0.name == name })
    let value = JSONValue.object(args)
    let validation = await tool.sdkTool.inputSchema.resolve().validate(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)))
    if case .failure(let error) = validation { throw error }
    guard let execute = tool.sdkTool.execute else { throw AIAgentFailure.invalidTool }
    do {
      return try await execute(value, .init(toolCallId: UUID().uuidString, messages: [])).resolve()
    } catch let error as AIToolError {
      return AIAgentRuntime.errorResult(error.code, field: error.field, message: error.message)
    } catch ReaderError.InvalidRange { return AIAgentRuntime.errorResult("invalid_argument") }

  }

}
