import SwiftUI
import StoreKit
import OSLog

@MainActor @Observable final class TipJar {
    static let productIDs = ["dev.moonread.tip.star", "dev.moonread.tip.tea", "dev.moonread.tip.snack", "dev.moonread.tip.book"]
    enum Catalog { case idle, loading, ready, unavailable }
    private(set) var catalog = Catalog.idle
    private(set) var products: [Product] = []
    private(set) var purchasing: String?
    private(set) var pending: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var thanked = false
    private(set) var celebrationID = UUID()
    private let loadProducts: () async throws -> [Product]
    private var loadTask: Task<Void, Never>?
    private var thanksTask: Task<Void, Never>?
    // Session-only deduplication between purchase results and StoreKit.Transaction.updates; never persisted.
    private var handledTransactions: Set<UInt64> = []
    private var pendingGeneration = UUID()
    private var listening = false
    private static let logger = Logger(subsystem: "dev.moonread.Moonread", category: "TipJar")

    init(loadProducts: @escaping () async throws -> [Product] = { try await Product.products(for: TipJar.productIDs) }) {
        self.loadProducts = loadProducts
    }

    func enterPage() async {
        guard catalog != .ready else { return }
        await load()
    }

    func load() async {
        if let loadTask { await loadTask.value; return }
        catalog = .loading
        // The store owns this operation; cancelling a page waiter must not cancel it.
        let task = Task {
            defer { loadTask = nil }
            do {
                let loaded = try await loadProducts()
                products = Self.productIDs.compactMap { id in loaded.first { $0.id == id && $0.type == .consumable } }
                catalog = products.count == Self.productIDs.count ? .ready : .unavailable
            } catch { catalog = .unavailable }
        }
        loadTask = task
        await task.value
    }

    /// The root scene owns this task; closing the store page doesn't stop it.
    func listenForTransactions() async {
        guard !listening else { return }
        listening = true
        defer { listening = false }
        let updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                await self?.complete(result)
            }
        }
        await withTaskCancellationHandler {
            for await result in StoreKit.Transaction.unfinished {
                guard !Task.isCancelled else { break }
                await complete(result)
            }
            await updates.value
        } onCancel: { updates.cancel() }
    }

    func leavePage() {
        pending.removeAll()
        pendingGeneration = UUID()
    }

    func buy(_ product: Product, purchase: () async throws -> Product.PurchaseResult) async {
        guard purchasing == nil else { return }
        pending.remove(product.id)
        let generation = pendingGeneration
        purchasing = product.id
        errors[product.id] = nil
        defer { purchasing = nil }
        do {
            switch try await purchase() {
            case .success(let verification): await complete(verification)
            case .pending:
                if generation == pendingGeneration { pending.insert(product.id) }
            case .userCancelled: break
            @unknown default: errors[product.id] = String(localized: "暂时无法完成付款，请重试")
            }
        } catch StoreKitError.userCancelled {
            // Some StoreKit purchase implementations surface cancellation as an error.
        } catch is CancellationError {
        } catch {
            errors[product.id] = String(localized: "暂时无法完成付款，请重试")
        }
    }

    private func complete(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard Self.productIDs.contains(transaction.productID), transaction.productType == .consumable,
                  transaction.revocationDate == nil, handledTransactions.insert(transaction.id).inserted else { return }
            await transaction.finish()
            pending.remove(transaction.productID)
            errors[transaction.productID] = nil
            thanked = true
            celebrationID = UUID()
            thanksTask?.cancel()
            thanksTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.thanked = false
            }
        case .unverified:
            Self.logger.error("Unverified tip transaction; not finishing or showing thanks")
        }
    }
}

struct TipJarView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(TipJar.self) private var store
    @Environment(\.purchase) private var purchase
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(spacing: LayoutTokens.section) {
                AIMoonMark(pose: store.thanked ? .done : .idle).scaleEffect(1.5)
                    .frame(width: 96, height: 96).id(store.celebrationID).accessibilityHidden(true)
                Text(store.thanked ? LocalizedStringKey("谢谢你的支持") : LocalizedStringKey("月读没有广告，也没有自己的服务器，你的书和阅读记录只留在你的设备和 iCloud 里。"))
                    .multilineTextAlignment(.center).foregroundStyle(Color(uiColor: theme.ink))
                    .accessibilityIdentifier("tipJarIntroduction")
                switch store.catalog {
                case .idle, .loading:
                    ProgressView().tint(Color(uiColor: theme.secondary)).accessibilityLabel("正在连接 App Store")
                case .unavailable:
                    VStack(spacing: LayoutTokens.control) {
                        Text("暂时无法连接 App Store")
                        Button("重试") { Task { await store.load() } }.buttonStyle(ThemedProminentButtonStyle())
                    }.frame(maxWidth: .infinity).padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
                case .ready:
                    ForEach(store.products, id: \.id) { product in row(product) }
                }
                Text("打赏不会解锁任何功能。付款由 Apple 处理。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).multilineTextAlignment(.center)
            }.padding(LayoutTokens.page).frame(maxWidth: 640).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle("支持月读").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("tipJar")
            .task { await store.enterPage() }
            .onDisappear { store.leavePage() }
    }
    private func row(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LayoutTokens.content) {
                    description(product)
                    price(product).fixedSize(horizontal: true, vertical: false)
                }
            } else {
                HStack(alignment: .center, spacing: LayoutTokens.content) {
                    description(product)
                    price(product).fixedSize(horizontal: true, vertical: false)
                }
            }
            if store.pending.contains(product.id) {
                Text("已请求批准，批准后会自动完成").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityIdentifier("tipJarPending-" + product.id)
            }
            if let error = store.errors[product.id] {
                Text(error).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityIdentifier("tipJarError-" + product.id)
            }
        }.padding(LayoutTokens.content).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).stroke(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
            .accessibilityElement(children: .contain).accessibilityIdentifier("tipJarRow-" + product.id)
    }
    private func description(_ product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(product.displayName).font(.headline).foregroundStyle(Color(uiColor: theme.ink))
                .accessibilityIdentifier("tipJarTitle-" + product.id)
            Text(product.description).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityIdentifier("tipJarDescription-" + product.id)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityIdentifier("tipJarText-" + product.id)
    }
    private func price(_ product: Product) -> some View {
        Button {
            Task { await store.buy(product) { try await purchase(product) } }
        } label: {
            ZStack {
                Text(product.displayPrice).fixedSize().opacity(store.purchasing == product.id ? 0 : 1)
                if store.purchasing == product.id { ProgressView().tint(Color(uiColor: theme.onAccent)) }
            }
        }.buttonStyle(ThemedProminentButtonStyle()).disabled(store.purchasing != nil)
            .accessibilityLabel(product.displayName + " " + product.displayPrice)
            .accessibilityValue(store.purchasing == product.id ? Text("正在付款") : Text(""))
            .accessibilityIdentifier("tipJarBuy-" + product.id)
    }
}
