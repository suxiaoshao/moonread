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
    let first = AICredential(
      accessToken: "synthetic-first", refreshToken: "", expires: .distantFuture,
      accountID: "fixture")
    try store.save(first, reference: reference)
    XCTAssertEqual(try store.load(reference)?.accessToken, first.accessToken)
    let next = AICredential(
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
