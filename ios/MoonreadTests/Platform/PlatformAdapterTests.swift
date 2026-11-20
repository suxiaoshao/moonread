import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import StoreKit
import StoreKitTest
import UIKit
import XCTest

@testable import Moonread

final class PlatformAdapterCredentialStoreAdapterTests: CredentialStoreAdapterFixture {
  // S076: 隔离 namespace 的真实钥匙串适配器集成；业务失败由内存 store 覆盖。
  func testKeychainAdapterRoundTripInIsolatedNamespace() throws {
    let store = KeychainCredentialStore(service: "dev.moonread.tests." + UUID().uuidString)
    let reference = "synthetic-credential"
    defer { try? store.remove(reference) }
    XCTAssertNil(try store.read(reference))
    let first = AICredentialStorage(
      accessToken: "synthetic-first", refreshToken: "", expires: .distantFuture,
      accountID: "fixture")
    try store.save(first, reference: reference)
    XCTAssertEqual(try store.load(reference)?.accessToken, first.accessToken)
    let next = AICredentialStorage(
      accessToken: "synthetic-replacement", refreshToken: "", expires: .distantFuture,
      accountID: "fixture")
    try store.save(next, reference: reference)
    XCTAssertEqual(try store.load(reference)?.accessToken, next.accessToken)
    try store.remove(reference)
    XCTAssertNil(try store.read(reference))
  }
}

final class PlatformAdapterTipJarTests: TipJarFixture {
  // S456: 项目 StoreKit 配置生成外部交易，验证真实适配器的加载、更新映射和 finish；购买状态用假 gateway。
  func testStoreKitAdapterLoadsAndCompletesSyntheticPurchase() async throws {
    if ProcessInfo.processInfo.environment["CI"] == "true" {
      throw XCTSkip("无界面 CI 模拟器上 StoreKitTest 交易推送不可靠，本地与发版前运行")
    }
    // Load the test-bundle configuration explicitly; test-without-building must
    // not depend on the Run action's StoreKit selection.
    let session = try SKTestSession(configurationFileNamed: "TipJar")
    session.resetToDefaultState()
    session.clearTransactions()
    session.disableDialogs = true
    session.storefront = "USA"
    session.locale = Locale(identifier: "zh_CN")
    defer { session.clearTransactions() }
    let gateway = StoreKitPurchaseGateway()
    // Subscribe before creating the external transaction. Loading the catalog
    // suspends while the adapter installs its Transaction.updates listener.
    let updates = gateway.transactions()
    let products = try await gateway.products()
    XCTAssertEqual(Set(products.map(\.id)), Set(TipJar.productIDs))
    let received = expectation(description: "StoreKit adapter mapped and finished transaction")
    var mapped: TipTransaction?
    let listener = Task {
      for await transaction in updates {
        mapped = transaction
        await gateway.finish(transaction.id)
        received.fulfill()
        break
      }
    }
    defer { listener.cancel() }
    let generated = try await session.buyProduct(identifier: TipJar.productIDs[0])
    await fulfillment(of: [received], timeout: 20)
    let transaction = try XCTUnwrap(mapped)
    XCTAssertEqual(transaction.id, generated.id)
    XCTAssertEqual(transaction.productID, generated.productID)
    XCTAssertTrue(transaction.verified)
    XCTAssertTrue(transaction.consumable)
    XCTAssertFalse(transaction.revoked)
    var unfinished = Set<UInt64>()
    for await result in StoreKit.Transaction.unfinished {
      if case .verified(let value) = result { unfinished.insert(value.id) }
    }
    XCTAssertFalse(unfinished.contains(generated.id), "The adapter must finish the real transaction")
  }
}

final class PlatformAdapterSystemReadingTests: XCTestCase {
  func testPublishedSnapshotDoesNotSubstituteRecentBookForMissingSelection() throws {
    let book = SystemReadingWidgetModel.sample
    let missing = "book:" + String(repeating: "b", count: 64)
    let snapshot = SystemReadingSnapshot(generation: UUID(), storeScope: "fixture",
      generatedAt: .distantPast, books: [book], recentIDs: [book.id], exposurePolicy: .initial,
      appearance: nil, statistics: nil)
    let decoded = try JSONDecoder().decode(SystemReadingSnapshot.self, from: JSONEncoder().encode(snapshot))
    let selection = SystemReadingWidgetModel.selection(in: decoded, selectedID: missing, specific: true)
    guard case .missing(let id) = selection else { return XCTFail("Missing selection must retain its identity") }
    XCTAssertEqual(id, missing)
    XCTAssertEqual(try SystemReadingRequest(url: XCTUnwrap(SystemReadingLink.book(id))),
                   .openBook(try SystemReadingBookID(rawValue: missing)))
    XCTAssertEqual(SystemReadingWidgetModel.selection(in: decoded, selectedID: nil).book?.id, book.id)
  }
}

final class SystemReadingPublicationTests: XCTestCase {
  func testIndependentStatisticsFileAndAtomicBookPromotion() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SystemPublish-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = SystemReadingSnapshotFile(directory: directory)
    let statistics = SystemReadingStatisticsSnapshot(storeScope: "fixture")
    try output.publishStatistics(statistics)
    XCTAssertEqual(try output.readStatistics(), statistics)
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.url.path))

    let old = SystemReadingSnapshot(storeScope: "fixture")
    try output.publish(old)
    let next = SystemReadingSnapshot(storeScope: "fixture")
    let staging = try output.stage(next)
    XCTAssertEqual(try output.read(), old)
    try output.publishStaged(staging)
    XCTAssertEqual(try output.read(), next)
    XCTAssertEqual(try output.readStatistics(), statistics)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
  }

  func testUrgentRequestsWakeThrottleButDoNotReplaceAnActiveBuild() async {
    let now = Date()
    var lane = SystemPublicationLane()
    lane.request(immediate: false)
    lane.begin(at: now)
    lane.task = Task {}
    let active = UUID()
    lane.taskID = active
    let revision = lane.revision
    lane.request(immediate: true)
    lane.request(immediate: true)
    XCTAssertEqual(lane.taskID, active)
    XCTAssertNotEqual(lane.revision, revision)
    XCTAssertTrue(lane.dirty)
    XCTAssertTrue(lane.urgent)

    lane.begin(at: now)
    lane.request(immediate: false)
    XCTAssertEqual(lane.delay(now: now.addingTimeInterval(10)), 20)
    lane.waiting = true
    lane.request(immediate: true)
    XCTAssertNil(lane.task)
    XCTAssertNil(lane.taskID)
    XCTAssertEqual(lane.delay(now: now), 0)
  }
}
