import Foundation
import StoreKitTest
import XCTest

@testable import Moonread

final class TipJarTests: TipJarFixture {
  // S444: 验证成功的消耗型打赏可重复处理且不形成持久功能解锁；fake gateway，不验证 StoreKit。
  func testCatalogAndSuccessfulRepeatConsumable() async throws {
    let (store, gateway) = await fixture()
    XCTAssertEqual(store.catalog, .ready)
    XCTAssertEqual(store.products.map(\.id), TipJar.productIDs)
    let product = try XCTUnwrap(store.products.first)
    gateway.result = .success(.init(id: 1, productID: product.id))
    await store.buy(product)
    XCTAssertTrue(store.thanked)
    XCTAssertNil(store.purchasing)
    let first = store.celebrationID
    gateway.result = .success(.init(id: 2, productID: product.id))
    await store.buy(product)
    XCTAssertNotEqual(store.celebrationID, first)
    XCTAssertEqual(gateway.finished, [1, 2])
    XCTAssertFalse(TipJar(gateway: gateway).thanked)
  }

  // S446: 取消/失败/未验证交易不得触发成功或 finish；一失败及一未验证结果，保留安全后果。
  func testUnverifiedPurchaseDoesNotThankOrFinish() async throws {
    let (store, gateway) = await fixture()
    let product = try XCTUnwrap(store.products.first)
    gateway.result = .success(.init(id: 1, productID: product.id, verified: false))
    await store.buy(product)
    XCTAssertFalse(store.thanked)
    XCTAssertTrue(gateway.finished.isEmpty)
    gateway.buy = { _ in throw AIError.invalidResponse }
    await store.buy(product)
    XCTAssertFalse(store.thanked)
    XCTAssertTrue(gateway.finished.isEmpty)
    gateway.buy = nil
    gateway.result = .userCancelled
    await store.buy(product)
    XCTAssertFalse(store.thanked)
    XCTAssertTrue(gateway.finished.isEmpty)
  }

  // S447: pending 只有应用收到有效交易完成才变成功，重试前清本次 pending；假事件。
  func testPendingApprovalCompletedByApplicationListener() async throws {
    let (store, gateway) = await fixture()
    let product = try XCTUnwrap(store.products.first)
    gateway.result = .pending
    await store.buy(product)
    XCTAssertEqual(store.pending, [product.id])
    let done = expectation(description: "Verified event finished")
    gateway.onFinish = { done.fulfill() }
    let listener = Task { await store.listenForTransactions() }
    defer {
      listener.cancel()
      gateway.continuation.finish()
    }
    gateway.continuation.yield(.init(id: 1, productID: product.id))
    await fulfillment(of: [done], timeout: 2)
    await awaitState { store.pending.isEmpty && store.thanked }
    XCTAssertTrue(store.pending.isEmpty)
    XCTAssertTrue(store.thanked)
    gateway.result = .pending
    await store.buy(product)
    gateway.buy = { _ in
      XCTAssertFalse(store.pending.contains(product.id))
      return .userCancelled
    }
    await store.buy(product)
    XCTAssertTrue(store.pending.isEmpty, "retry does not retain an obsolete pending result")
  }

  // S449: 离开页面后晚到 pending 不污染下一次进入，旧申请不冒充当前申请。
  func testLeavingPageClearsPendingIncludingLateResult() async throws {
    let (store, gateway) = await fixture()
    let product = try XCTUnwrap(store.products.first)
    gateway.buy = { _ in
      store.leavePage()
      return .pending
    }
    await store.buy(product)
    XCTAssertTrue(store.pending.isEmpty)
    gateway.buy = nil
    gateway.result = .pending
    await store.buy(product)
    store.leavePage()
    await store.enterPage()
    XCTAssertTrue(store.pending.isEmpty)
  }

  // S454: 商品目录不完整/失败时禁止购买，明确重入可恢复；删共享 load 次数断言。
  func testMissingProductsDoNotOfferIncompleteCatalog() async {
    let gateway = FakePurchaseGateway()
    gateway.catalog.removeLast()
    let store = TipJar(gateway: gateway)
    await store.load()
    XCTAssertEqual(store.catalog, .unavailable)
    await store.buy(gateway.catalog[0])
    XCTAssertTrue(gateway.purchases.isEmpty)
    gateway.load = { throw AIError.invalidResponse }
    await store.load()
    XCTAssertEqual(store.catalog, .unavailable)
    gateway.catalog = TipJar.productIDs.map {
      TipProduct(id: $0, displayName: $0, description: "Fixture", displayPrice: "1")
    }
    gateway.load = nil
    await store.enterPage()
    XCTAssertEqual(store.catalog, .ready)
  }

  // S455: 同时只能发起一笔购买，加载/购买互斥；这是重复交易保护，不删除行为次数断言。
  func testPurchasingAndLoadingStatesAreExclusive() async throws {
    let (store, gateway) = await fixture()
    let product = try XCTUnwrap(store.products.first)
    gateway.buy = { _ in
      XCTAssertEqual(store.purchasing, product.id)
      await store.buy(store.products[1])
      return .userCancelled
    }
    await store.buy(product)
    XCTAssertEqual(gateway.purchases, [product.id])
    XCTAssertNil(store.purchasing)
  }
}
