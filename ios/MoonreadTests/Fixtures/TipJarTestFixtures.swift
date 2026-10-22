import Foundation
import StoreKitTest
import XCTest

@testable import Moonread

@MainActor final class FakePurchaseGateway: PurchaseGateway {
  var catalog = TipJar.productIDs.map {
    TipProduct(id: $0, displayName: $0, description: "Synthetic", displayPrice: "¥1")
  }
  var load: (() async throws -> [TipProduct])?
  var buy: ((String) async throws -> TipPurchaseResult)?
  var result = TipPurchaseResult.userCancelled
  var finished: [UInt64] = []
  var purchases: [String] = []
  var loads = 0
  var onFinish: (() -> Void)?
  let stream: AsyncStream<TipTransaction>
  let continuation: AsyncStream<TipTransaction>.Continuation
  init() { (stream, continuation) = AsyncStream.makeStream() }
  func products() async throws -> [TipProduct] {
    loads += 1
    return try await load?() ?? catalog
  }
  func purchase(_ id: String) async throws -> TipPurchaseResult {
    purchases.append(id)
    return try await buy?(id) ?? result
  }
  func transactions() -> AsyncStream<TipTransaction> { stream }
  func finish(_ id: UInt64) async {
    finished.append(id)
    onFinish?()
  }
}

@MainActor class TipJarFixture: XCTestCase {
  func fixture() async -> (TipJar, FakePurchaseGateway) {
    let gateway = FakePurchaseGateway()
    let clock = ManualTestClock()
    let store = TipJar(gateway: gateway, thanksDelay: { try await clock.sleep(4) })
    await store.load()
    return (store, gateway)
  }
}
