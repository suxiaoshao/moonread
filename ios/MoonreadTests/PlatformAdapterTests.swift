import AISDKProvider
import AISDKProviderUtils
import AuthenticationServices
import CryptoKit
import Foundation
import Security
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
  // S456: 使用项目 StoreKit 配置验证真实购买适配器；业务测试使用假 PurchaseGateway。
  func testStoreKitAdapterLoadsAndCompletesSyntheticPurchase() async throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Moonread/Settings/TipJar.storekit")
    let session = try SKTestSession(contentsOf: file)
    session.resetToDefaultState()
    session.clearTransactions()
    session.disableDialogs = true
    defer { session.clearTransactions() }
    let gateway = StoreKitPurchaseGateway()
    let loaded = expectation(description: "StoreKit adapter purchase")
    var outcome: TipPurchaseResult?
    let task = Task {
      do {
        let products = try await gateway.products()
        XCTAssertEqual(Set(products.map(\.id)), Set(TipJar.productIDs))
        let result = try await gateway.purchase(TipJar.productIDs[0])
        outcome = result
        if case .success(let transaction) = result { await gateway.finish(transaction.id) }
      } catch { XCTFail("StoreKit adapter: \(error)") }
      loaded.fulfill()
    }
    await fulfillment(of: [loaded], timeout: 20)
    task.cancel()
    guard case .success(let transaction) = outcome else {
      return XCTFail("Synthetic StoreKit purchase did not complete")
    }
    XCTAssertTrue(transaction.verified)
    XCTAssertEqual(transaction.productID, TipJar.productIDs[0])
  }
}
