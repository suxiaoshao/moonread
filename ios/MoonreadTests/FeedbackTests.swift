import SQLite3
import XCTest

@testable import Moonread

final class FeedbackTests: AppStorePrivacyFixture {
  // S243: 反馈只包含用户选中的回复和请求身份，不夹带其他消息、书名或 credential reference。
  @MainActor func testReplyFeedbackContainsOnlySelectedTextAndRequestIdentity() async throws {
    let repository = try await AIRepository.open(inMemory: true)
    let row = AISessionValue(title: "Private conversation title")
    try await repository.create(row)
    let conversation = AIConversation(row)
    var connection = AIProviderPreset.all.first!.connection()
    connection.name = "Selected Provider"
    connection.models = [AIModelOption(id: "selected-model", name: "Readable Model", thinking: [])]
    let turn = "selected-turn"
    let old = AIAgentEntry(
      sequence: 0, turn: "other", provider: "other", model: "other-model",
      message: .object([
        "role": .string("assistant"),
        "content": .object(["value": .string("Do not include other replies")]),
      ]))
    let answer = AIAgentEntry(
      sequence: 1, turn: turn, provider: connection.id + ":fixture", model: "selected-model",
      message: .object([
        "role": .string("assistant"), "content": .object(["value": .string("Selected reply")]),
      ]), outcome: .completed)
    conversation.mergeEntries([old, answer])
    let selected = AIMessageRow(
      id: turn + "/actions", turnID: turn, content: .actions("Selected reply", .completed))
    let feedback = try XCTUnwrap(
      AIReplyFeedback(row: selected, conversation: conversation, connections: [connection]))
    XCTAssertEqual(feedback.recipient, AppLinks.supportEmail)
    XCTAssertEqual(feedback.provider, connection.name)
    XCTAssertEqual(feedback.model, "Readable Model")
    XCTAssertEqual(feedback.text, "Selected reply")
    XCTAssertFalse(feedback.version.isEmpty)
    XCTAssertTrue(feedback.body.contains("Selected reply"))
    XCTAssertFalse(feedback.body.contains("Do not include other replies"))
    XCTAssertFalse(feedback.body.contains(row.title))
    XCTAssertFalse(feedback.body.contains(connection.credentialReference))
    XCTAssertTrue(feedback.copyText.contains(AppLinks.supportEmail))
    let removed = try XCTUnwrap(
      AIReplyFeedback(row: selected, conversation: conversation, connections: []))
    XCTAssertEqual(removed.provider, String(localized: "已删除的连接"))
    XCTAssertEqual(removed.model, answer.model)
    XCTAssertFalse(removed.body.contains(connection.id))
    XCTAssertNil(
      AIReplyFeedback(
        row: .init(id: "user", turnID: turn, content: .user(answer)), conversation: conversation,
        connections: [connection]))
  }

  // S245: 反馈路由按能力降级且只交付明确反馈内容；假 composer/open sink，保留成功与拒绝两个分支，不启动系统邮件。
  @MainActor func testReplyFeedbackOpensDefaultMailAppWithEncodedFields() async throws {
    let feedback = AIReplyFeedback(
      provider: "Provider", model: "Model", text: "Synthetic + & ? # 漢字\nnext line",
      version: "1.0 (2)")
    var opened: [URL] = []
    let route = await AIReplyFeedbackDelivery.route(feedback, canCompose: false) {
      opened.append($0)
      return true
    }
    XCTAssertEqual(route, .defaultMailApp)
    XCTAssertEqual(opened.count, 1)
    let url = try XCTUnwrap(opened.first)
    let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(parts.scheme, "mailto")
    XCTAssertEqual(parts.path, feedback.recipient)
    let query = Dictionary(
      uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["subject"], feedback.subject)
    XCTAssertEqual(query["body"], feedback.body)
    XCTAssertTrue(url.absoluteString.contains("%2B"))
    XCTAssertTrue(url.absoluteString.contains("%26"))
    XCTAssertTrue(url.absoluteString.contains("%0A"))
    XCTAssertFalse(url.absoluteString.contains("\n"))

    opened.removeAll()
    let composer = await AIReplyFeedbackDelivery.route(feedback, canCompose: true) { url in
      opened.append(url)
      return true
    }
    XCTAssertEqual(composer, .composer, "A supported composer owns delivery")
    XCTAssertTrue(opened.isEmpty)
    let refused = await AIReplyFeedbackDelivery.route(feedback, canCompose: false) { _ in false }
    XCTAssertEqual(refused, .copyFallback, "A rejected mail URL must offer explicit copying")
    XCTAssertEqual(
      feedback.copyText, "\(feedback.recipient)\n\(feedback.subject)\n\n\(feedback.body)")

  }
}
