import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import XCTest

@testable import Moonread

final class AIImageToolsTests: AINativeToolsFixture {
  // S218: 图片生成结果持久为当前会话资产，编辑只读当前 owner 引用；一个假生成→编辑流程，删逐模型 image/images 请求形状。
  func testGeneratedAttachmentPersistsAndIsUsedForEditing() async throws {
    let (_, tools, _, _) = try await fixture("native-image")
    let result = try await tools.generate(.init(prompt: "moon"))
    let attachment = try XCTUnwrap(result.data.attachments?.first)
    try await commitNative(result, tools: tools)
    XCTAssertEqual(attachment.width, 1)
    let reopened = tools.images
    let data = try await reopened.read(owner: "test-session", ref: attachment.id)
    XCTAssertFalse(data.isEmpty)
    let edited = try await tools.generate(
      .init(prompt: "blue moon", referenceAttachmentRefs: [attachment.id]))
    XCTAssertEqual(edited.data.attachments?.count, 1)
    let body =
      try JSONSerialization.jsonObject(with: XCTUnwrap(AITestURLProtocol.state.requestBody))
      as! [String: Any]
    let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
    let parts = messages.flatMap { $0["content"] as? [[String: Any]] ?? [] }
    let image = try XCTUnwrap(parts.first { $0["type"] as? String == "input_image" })
    XCTAssertTrue((image["image_url"] as? String)?.hasPrefix("data:image/") == true)
    do {
      _ = try await reopened.read(owner: "another-session", ref: attachment.id)
      XCTFail("Cross-session reference")
    } catch {}
    await tools.images.forget("test-session")
    do {
      _ = try await reopened.read(owner: "test-session", ref: attachment.id)
      XCTFail("Deleted attachment")
    } catch {}
  }

  // S219: 缺失/其他 owner/路径伪造图片引用在外发前拒绝，不能泄露其他会话资产。
  func testMissingOrOtherOwnerImageReferenceFailsExplicitlyBeforeProviderRequest() async throws {
    let (_, tools, _, _) = try await fixture("native-image")
    let bytes = Data(
      base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII="
    )!
    let otherRepository = try await AIRepository.open(inMemory: true)
    try await otherRepository.create(.init(id: "another-session", title: "Other"))
    await tools.images.bind("another-session", repository: otherRepository)
    let other = try await tools.images.save(bytes, owner: "another-session")
    let stage = await tools.images.staged(owner: "another-session", refs: [other.id])
    var otherHead = AIAgentHead()
    otherHead.queue = [
      .init(
        text: "Sent", mode: .steering,
        readingAttachments: [
          .init(kind: .image, origin: "fixture", title: "Image", attachmentRef: other.id)
        ])
    ]
    try await otherRepository.commit(
      "another-session", head: otherHead, assets: stage, references: [other.id])
    defer { Task { await tools.images.forget("another-session") } }
    for ref in [UUID().uuidString, other.attachmentRef] {
      do {
        _ = try await tools.generate(.init(prompt: "edit", referenceAttachmentRefs: [ref]))
        XCTFail("Missing reference accepted")
      } catch let error as AIToolError {
        XCTAssertEqual(error.code, "not_found")
        XCTAssertEqual(error.field, "referenceAttachmentRefs")
      }
      XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
    }
    do {
      _ = try await tools.generate(
        .init(prompt: "edit", referenceAttachmentRefs: ["../another-session/asset.png"]))
      XCTFail("path-like attachment references must not escape owner lookup")
    } catch {}
    XCTAssertEqual(AITestURLProtocol.state.counts.0, 0)
  }
}
