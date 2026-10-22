import AISDKProvider
import AISDKProviderUtils
import Litext
import MarkdownView
import SwiftData
import SwiftUI
import XCTest

@testable import Moonread

final class AIConnectionStorageTests: ConversationFixture {
  // S176: 连接逐条容错，显式保存保留未知记录/字段；删品牌列表/资源快照，保留真实持久化兼容性。
  func testConnectionsDecodeIndividuallyAndPreserveOpaqueEntriesOnSave() throws {
    let suite = "AIStoredJSON-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "Moonread.ai.connections"
    var connection = AIProviderPreset.all[0].connection()
    connection.thinking = "low"
    var known = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(connection)) as? [String: Any])
    known["futureField"] = ["enabled": true]
    var future = known
    future["id"] = "future"
    future["authMethod"] = "futureAuth"
    let original = try JSONSerialization.data(withJSONObject: [known, future, 42])
    defaults.set(original, forKey: key)
    let service = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    XCTAssertEqual(service.connections.map(\.id), [connection.id])
    XCTAssertEqual(
      defaults.data(forKey: key), original, "Reading must never repair the stored collection")
    service.connections[0].name = "Edited"
    service.connections[0].thinking = nil
    service.saveConnections()
    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [Any])
    XCTAssertEqual((saved[0] as? [String: Any])?["name"] as? String, "Edited")
    XCTAssertNil(
      (saved[0] as? [String: Any])?["thinking"],
      "Cleared known fields must not survive as opaque data")
    XCTAssertEqual(
      (saved[0] as? NSDictionary)?["futureField"] as? NSDictionary,
      known["futureField"] as? NSDictionary)
    XCTAssertEqual(saved[1] as? NSDictionary, future as NSDictionary)
    XCTAssertEqual(saved[2] as? Int, 42)
    service.connections = []
    service.saveConnections()
    let remaining = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [Any])
    XCTAssertEqual(remaining.count, 2, "Explicit deletion only removes understood entries")
    XCTAssertEqual(remaining[0] as? NSDictionary, future as NSDictionary)
    let malformed = Data("not-json".utf8)
    defaults.set(malformed, forKey: key)
    let unreadable = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    unreadable.saveConnections()
    XCTAssertNotNil(unreadable.error)
    XCTAssertEqual(
      defaults.data(forKey: key), malformed, "A corrupt whole container must not be overwritten")
  }

  // S177: 用途默认值兼容旧格式并保留未知键，显式编辑不得清掉新版本数据。
  func testPurposeDefaultsSkipUnknownKeysAndKeepThemAcrossExplicitSaves() throws {
    let suite = "AIPurposes-" + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let key = "Moonread.ai.purposeDefaults"
    let selection = AIPurposeSelection(connectionID: "known", modelID: "model")
    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection))
    let original = try JSONSerialization.data(withJSONObject: [
      "search": value, "image": 42, "futurePurpose": ["mode": "future"],
    ])
    defaults.set(original, forKey: key)
    let service = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    XCTAssertEqual(service.purposeDefaults, [.search: selection])
    XCTAssertEqual(defaults.data(forKey: key), original)
    XCTAssertTrue(service.setPurpose(.search, selection: nil))
    let saved = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
    XCTAssertNil(saved["search"])
    XCTAssertEqual(saved["image"] as? Int, 42)
    XCTAssertEqual(saved["futurePurpose"] as? NSDictionary, ["mode": "future"] as NSDictionary)
    // Read the actual enum-keyed Codable format already stored by previous builds too.
    let pairs = try JSONSerialization.data(withJSONObject: [
      "futurePurpose", value, "search", value, "image", 42,
    ])
    defaults.set(pairs, forKey: key)
    let restored = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    XCTAssertEqual(restored.purposeDefaults, [.search: selection])
    restored.saveConnections()
    let again = TestAI.connections(
      defaults: defaults,
      auth: TestAI.authentication(makeCallbackSource: { CallbackFixture.make() }))
    XCTAssertEqual(again.purposeDefaults, [.search: selection])
    let roundTrip = try XCTUnwrap(
      JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: key))) as? [String: Any])
    XCTAssertEqual(roundTrip["futurePurpose"] as? NSDictionary, value as? NSDictionary)
  }
}
