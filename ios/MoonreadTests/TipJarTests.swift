import XCTest
import SwiftUI
import UIKit
import TipKit
import StoreKit
import StoreKitTest
@testable import Moonread

@MainActor final class TipJarTests: XCTestCase {
    private func makeSession() throws -> SKTestSession {
        // Keep the local StoreKit fixture out of every target's bundle resources.
        let configuration = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Moonread/Settings/TipJar.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        return session
    }

    func testCatalogAndSuccessfulRepeatConsumable() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load()
        let listener = Task { await store.listenForTransactions() }; defer { listener.cancel() }
        XCTAssertEqual(store.catalog, .ready)
        XCTAssertEqual(store.products.map(\.id), TipJar.productIDs)
        XCTAssertTrue(store.products.allSatisfy { !$0.displayPrice.isEmpty && $0.type == .consumable })
        let product = try XCTUnwrap(store.products.first)
        await store.buy(product) { try await product.purchase() }
        XCTAssertTrue(store.thanked); XCTAssertNil(store.purchasing)
        let firstCelebration = store.celebrationID
        await store.buy(product) { try await product.purchase() }
        XCTAssertNotEqual(store.celebrationID, firstCelebration)
        XCTAssertFalse(TipJar().thanked, "Thanks and purchases aren't persisted")
    }
    func testCancellationAndPurchaseFailure() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        await store.buy(product) { .userCancelled }
        XCTAssertFalse(store.thanked); XCTAssertTrue(store.errors.isEmpty); XCTAssertNil(store.purchasing)
        await store.buy(product) { throw StoreKitError.userCancelled }
        XCTAssertTrue(store.errors.isEmpty); XCTAssertFalse(store.thanked)
        try await session.setSimulatedError(.generic(.unknown), forAPI: .purchase)
        await store.buy(product) { try await product.purchase() }
        XCTAssertNotNil(store.errors[product.id]); XCTAssertFalse(store.thanked); XCTAssertNil(store.purchasing)
    }
    func testUnverifiedPurchaseDoesNotThankOrFinish() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        let before = store.celebrationID
        try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
        await store.buy(product) { try await product.purchase() }
        XCTAssertFalse(store.thanked); XCTAssertEqual(store.celebrationID, before)
        var unfinished = false
        for await result in StoreKit.Transaction.unfinished {
            if case .unverified(let transaction, _) = result, transaction.productID == product.id { unfinished = true }
        }
        XCTAssertTrue(unfinished, "Unverified payment must remain unfinished")
    }

    func testPendingApprovalCompletedByApplicationListener() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        let listener = Task { await store.listenForTransactions() }; defer { listener.cancel() }
        await store.buy(product) { try await product.purchase() }
        XCTAssertTrue(store.pending.contains(product.id)); XCTAssertFalse(store.thanked)
        let transaction = try XCTUnwrap(session.allTransactions().first)
        store.leavePage()
        XCTAssertTrue(store.pending.isEmpty)
        try session.approveAskToBuyTransaction(identifier: transaction.identifier)
        let approved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in store.thanked && store.pending.isEmpty }, object: nil)
        await fulfillment(of: [approved], timeout: 10)
        XCTAssertTrue(store.thanked); XCTAssertTrue(store.pending.isEmpty)
    }
    func testPendingRetryClearsBeforePurchaseStarts() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        await store.buy(product) { .pending }
        XCTAssertTrue(store.pending.contains(product.id))
        await store.buy(product) {
            XCTAssertFalse(store.pending.contains(product.id))
            return .userCancelled
        }
        XCTAssertTrue(store.pending.isEmpty)
    }

    func testLeavingPageClearsPendingIncludingLateResult() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        for product in store.products { await store.buy(product) { .pending } }
        XCTAssertEqual(store.pending.count, TipJar.productIDs.count)
        store.leavePage()
        XCTAssertTrue(store.pending.isEmpty)
        await store.buy(product) {
            store.leavePage()
            return .pending
        }
        XCTAssertTrue(store.pending.isEmpty, "A late result from the previous visit must not restore pending")
    }

    func testDeclinedApprovalWithoutTransactionDoesNotSurviveLeavingPage() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        let listener = Task { await store.listenForTransactions() }; defer { listener.cancel() }
        await store.buy(product) { try await product.purchase() }
        XCTAssertTrue(store.pending.contains(product.id))
        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.declineAskToBuyTransaction(identifier: transaction.identifier)
        store.leavePage()
        XCTAssertTrue(store.pending.isEmpty)
        XCTAssertFalse(store.thanked)
        await store.load()
        XCTAssertTrue(store.pending.isEmpty, "Reopening doesn't depend on a denial transaction callback")
    }

    func testProductLoadingFailureCanRetry() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        try await session.setSimulatedError(.generic(.unknown), forAPI: .loadProducts)
        let store = TipJar(); await store.load(); XCTAssertEqual(store.catalog, .unavailable)
        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        await store.load(); XCTAssertEqual(store.catalog, .ready)
    }
    func testLeavingAndImmediatelyReenteringSharesProductLoad() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let products = try await Product.products(for: TipJar.productIDs)
        var calls = 0
        var release: CheckedContinuation<[Product], Never>?
        let entered = expectation(description: "owned load entered")
        let store = TipJar(loadProducts: {
            calls += 1
            XCTAssertFalse(Task.isCancelled, "Page cancellation must not cancel the owned load")
            return await withCheckedContinuation { release = $0; entered.fulfill() }
        })
        let oldPage = Task { await store.enterPage() }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(store.catalog, .loading)
        oldPage.cancel(); store.leavePage()
        let reentered = expectation(description: "new page entered")
        let newPage = Task { reentered.fulfill(); await store.enterPage() }
        await fulfillment(of: [reentered], timeout: 5)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.catalog, .loading)
        release?.resume(returning: products)
        await oldPage.value; await newPage.value
        XCTAssertEqual(store.catalog, .ready)
        XCTAssertEqual(store.products.map(\.id), TipJar.productIDs)
        XCTAssertEqual(calls, 1, "Both visits await the same load")
        await store.enterPage()
        XCTAssertEqual(calls, 1, "Ready catalog doesn't reload on entry")
    }

    func testUnavailableCatalogRetriesAutomaticallyOnReentry() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let products = try await Product.products(for: TipJar.productIDs)
        var calls = 0
        let store = TipJar(loadProducts: {
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return products
        })
        await store.enterPage()
        XCTAssertEqual(store.catalog, .unavailable)
        await store.enterPage()
        XCTAssertEqual(store.catalog, .ready)
        XCTAssertEqual(calls, 2)
    }

    func testMissingProductsDoNotOfferIncompleteCatalog() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(loadProducts: { [] }); await store.load()
        XCTAssertEqual(store.catalog, .unavailable)
    }
    func testPurchasingAndLoadingStatesAreExclusive() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load()
        let product = try XCTUnwrap(store.products.first)
        let entered = expectation(description: "purchase entered")
        var release: CheckedContinuation<Product.PurchaseResult, Never>?
        let task = Task {
            await store.buy(product) {
                await withCheckedContinuation { continuation in
                    release = continuation; entered.fulfill()
                }
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(store.purchasing, product.id)
        await store.buy(store.products[1]) { XCTFail("A second purchase must not start"); return .userCancelled }
        try await renderState(store, name: "state-purchasing")
        release?.resume(returning: .userCancelled); await task.value
        XCTAssertNil(store.purchasing)
        let loadingEntered = expectation(description: "loading entered")
        var loaded: CheckedContinuation<[Product], Never>?
        let loading = TipJar(loadProducts: {
            await withCheckedContinuation { continuation in loaded = continuation; loadingEntered.fulfill() }
        })
        let loadTask = Task { await loading.load() }
        await fulfillment(of: [loadingEntered], timeout: 5)
        XCTAssertEqual(loading.catalog, .loading)
        try await renderState(loading, name: "state-loading")
        loaded?.resume(returning: store.products); await loadTask.value
        XCTAssertEqual(loading.catalog, .ready)
    }

    func testHelpAndStoreThemeRenderingMatrix() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load()
        XCTAssertEqual(store.catalog, .ready)
        let palettes = defaultThemeSnapshot().palettes
        for palette in palettes {
            let theme = ThemeSurface(plan: ResolvedTheme(appearance: palette.appearance, highContrast: false, colors: palette.colors, paletteId: palette.id))
            for large in [false, true] {
                let suffix = palette.id + (large ? "-ax" : "")
                let tips = VStack(spacing: 16) {
                    ThemedTipCard(title: ImportNovelTip().title) {}
                    ThemedTipCard(title: ReaderControlsTip().title) {}
                    ThemedTipCard(title: ReaderSelectionTip().title) {}
                }.padding().frame(maxWidth: .infinity).background(Color(uiColor: theme.paper))
                try await render(tips, name: "tips-" + suffix, theme: theme, large: large)
                try await render(NavigationStack { UsageGuideView() }, name: "guide-" + suffix, theme: theme, large: large)
                try await render(NavigationStack { TipJarView() }.environment(store), name: "store-" + suffix, theme: theme, large: large)
            }
        }
    }

    func testStoreStateRendering() async throws {
        let session = try makeSession(); defer { session.clearTransactions() }
        let store = TipJar(); await store.load(); let product = try XCTUnwrap(store.products.first)
        await store.buy(product) { .pending }
        try await renderState(store, name: "state-pending")
        await store.buy(product) { throw StoreKitError.unknown }
        try await renderState(store, name: "state-error")
        await store.buy(product) { try await product.purchase() }
        try await renderState(store, name: "state-thanks")
        try await render(NavigationStack { TipJarView() }.environment(store).environment(\.moonreadReduceMotion, true),
                         name: "state-thanks-reduced", theme: .initial)
        let unavailable = TipJar(loadProducts: { [] }); await unavailable.load()
        try await renderState(unavailable, name: "state-unavailable")
    }

    private func renderState(_ store: TipJar, name: String) async throws {
        for appearance in [ThemeAppearance.light, .dark] {
            let plan = try resolveThemes(value: defaultThemeSnapshot(), system: appearance, highContrast: false).app
            for large in [false, true] {
                try await render(NavigationStack { TipJarView() }.environment(store),
                                 name: name + (appearance == .dark ? "-dark" : "-light") + (large ? "-ax" : ""),
                                 theme: ThemeSurface(plan: plan), large: large)
            }
        }
    }

    private func render<Content: View>(_ content: Content, name: String, theme: ThemeSurface, large: Bool = false) async throws {
        let host = UIHostingController(rootView: content.themeScope(theme)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large))
        host.overrideUserInterfaceStyle = theme.style
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // SwiftUI's asynchronous initial render settles on the next run-loop cycle.
        await Task.yield()
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-TipJar-Renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        print("TipJar render: " + directory.appendingPathComponent(name + ".png").path)
    }

}
