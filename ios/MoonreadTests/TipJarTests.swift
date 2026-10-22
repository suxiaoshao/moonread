import XCTest
import Foundation
import StoreKitTest
@testable import Moonread

@MainActor private final class FakePurchaseGateway: PurchaseGateway {
    var catalog = TipJar.productIDs.map { TipProduct(id: $0, displayName: $0, description: "Synthetic", displayPrice: "¥1") }
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
    func products() async throws -> [TipProduct] { loads += 1; return try await load?() ?? catalog }
    func purchase(_ id: String) async throws -> TipPurchaseResult {
        purchases.append(id); return try await buy?(id) ?? result
    }
    func transactions() -> AsyncStream<TipTransaction> { stream }
    func finish(_ id: UInt64) async { finished.append(id); onFinish?() }
}

@MainActor final class TipJarTests: XCTestCase {
    private func fixture() async -> (TipJar, FakePurchaseGateway) {
        let gateway = FakePurchaseGateway(), clock = ManualTestClock()
        let store = TipJar(gateway: gateway, thanksDelay: { try await clock.sleep(4) })
        await store.load(); return (store, gateway)
    }
    func testCatalogAndSuccessfulRepeatConsumable() async throws {
        let (store, gateway) = await fixture()
        XCTAssertEqual(store.catalog, .ready); XCTAssertEqual(store.products.map(\.id), TipJar.productIDs)
        let product = try XCTUnwrap(store.products.first)
        gateway.result = .success(.init(id: 1, productID: product.id))
        await store.buy(product); XCTAssertTrue(store.thanked); XCTAssertNil(store.purchasing)
        let first = store.celebrationID
        gateway.result = .success(.init(id: 2, productID: product.id))
        await store.buy(product); XCTAssertNotEqual(store.celebrationID, first)
        XCTAssertEqual(gateway.finished, [1, 2]); XCTAssertFalse(TipJar(gateway: gateway).thanked)
    }
    func testCancellationAndPurchaseFailure() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        await store.buy(product); XCTAssertTrue(store.errors.isEmpty); XCTAssertFalse(store.thanked)
        gateway.buy = { _ in throw AIError.invalidResponse }
        await store.buy(product); XCTAssertNotNil(store.errors[product.id]); XCTAssertNil(store.purchasing)
    }
    func testUnverifiedPurchaseDoesNotThankOrFinish() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.result = .success(.init(id: 1, productID: product.id, verified: false))
        await store.buy(product); XCTAssertFalse(store.thanked); XCTAssertTrue(gateway.finished.isEmpty)
    }
    func testPendingApprovalCompletedByApplicationListener() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.result = .pending; await store.buy(product); XCTAssertEqual(store.pending, [product.id])
        let done = expectation(description: "Verified event finished")
        gateway.onFinish = { done.fulfill() }
        let listener = Task { await store.listenForTransactions() }; defer { listener.cancel(); gateway.continuation.finish() }
        gateway.continuation.yield(.init(id: 1, productID: product.id))
        await fulfillment(of: [done], timeout: 2)
        await awaitState { store.pending.isEmpty && store.thanked }
        XCTAssertTrue(store.pending.isEmpty); XCTAssertTrue(store.thanked)
    }
    func testPendingRetryClearsBeforePurchaseStarts() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.result = .pending; await store.buy(product)
        gateway.buy = { _ in XCTAssertFalse(store.pending.contains(product.id)); return .userCancelled }
        await store.buy(product); XCTAssertTrue(store.pending.isEmpty)
    }
    func testLeavingPageClearsPendingIncludingLateResult() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.buy = { _ in store.leavePage(); return .pending }
        await store.buy(product); XCTAssertTrue(store.pending.isEmpty)
    }
    func testDeclinedApprovalWithoutTransactionDoesNotSurviveLeavingPage() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.result = .pending; await store.buy(product); store.leavePage()
        await store.enterPage(); XCTAssertTrue(store.pending.isEmpty); XCTAssertFalse(store.thanked)
    }
    func testProductLoadingFailureCanRetry() async {
        let gateway = FakePurchaseGateway(), store = TipJar(gateway: gateway)
        gateway.load = { throw AIError.invalidResponse }; await store.load(); XCTAssertEqual(store.catalog, .unavailable)
        gateway.load = nil; await store.load(); XCTAssertEqual(store.catalog, .ready)
    }
    func testLeavingAndImmediatelyReenteringSharesProductLoad() async {
        let gateway = FakePurchaseGateway(), store = TipJar(gateway: gateway)
        let started = expectation(description: "Load admitted")
        var release: CheckedContinuation<[TipProduct], Error>?
        gateway.load = { try await withCheckedThrowingContinuation { release = $0; started.fulfill() } }
        let first = Task { await store.enterPage() }; await fulfillment(of: [started], timeout: 2)
        store.leavePage(); let second = Task { await store.enterPage() }
        release?.resume(returning: gateway.catalog); await first.value; await second.value
        XCTAssertEqual(gateway.loads, 1); XCTAssertEqual(store.catalog, .ready)
    }
    func testUnavailableCatalogRetriesAutomaticallyOnReentry() async {
        let gateway = FakePurchaseGateway(), store = TipJar(gateway: gateway)
        let products = gateway.catalog; gateway.catalog = []; await store.enterPage()
        XCTAssertEqual(store.catalog, .unavailable); store.leavePage(); gateway.catalog = products
        await store.enterPage(); XCTAssertEqual(store.catalog, .ready)
    }
    func testMissingProductsDoNotOfferIncompleteCatalog() async {
        let gateway = FakePurchaseGateway(); gateway.catalog.removeLast()
        let store = TipJar(gateway: gateway); await store.load(); XCTAssertEqual(store.catalog, .unavailable)
        await store.buy(gateway.catalog[0]); XCTAssertTrue(gateway.purchases.isEmpty)
    }
    func testPurchasingAndLoadingStatesAreExclusive() async throws {
        let (store, gateway) = await fixture(), product = try XCTUnwrap(store.products.first)
        gateway.buy = { _ in
            XCTAssertEqual(store.purchasing, product.id)
            await store.buy(store.products[1]); return .userCancelled
        }
        await store.buy(product); XCTAssertEqual(gateway.purchases, [product.id]); XCTAssertNil(store.purchasing)
    }
    func testStoreKitAdapterLoadsAndCompletesSyntheticPurchase() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moonread/Settings/TipJar.storekit")
        let session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        defer { session.clearTransactions() }
        let gateway = StoreKitPurchaseGateway()
        let loaded = expectation(description: "StoreKit adapter purchase")
        var outcome: TipPurchaseResult?
        let task = Task {
            do {
                let products = try await gateway.products()
                XCTAssertEqual(Set(products.map(\.id)), Set(TipJar.productIDs))
                let result = try await gateway.purchase(TipJar.productIDs[0]); outcome = result
                if case .success(let transaction) = result { await gateway.finish(transaction.id) }
            } catch { XCTFail("StoreKit adapter: \(error)") }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 20); task.cancel()
        guard case .success(let transaction) = outcome else { return XCTFail("Synthetic StoreKit purchase did not complete") }
        XCTAssertTrue(transaction.verified); XCTAssertEqual(transaction.productID, TipJar.productIDs[0])
    }
}
