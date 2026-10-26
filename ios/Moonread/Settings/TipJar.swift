import SwiftUI
import StoreKit

struct TipProduct: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var description: String
    var displayPrice: String
    var consumable = true
}
struct TipTransaction: Sendable {
    let id: UInt64
    let productID: String
    var consumable = true
    var revoked = false
    var verified = true
}
enum TipPurchaseResult: Sendable { case success(TipTransaction), pending, userCancelled }

@MainActor protocol PurchaseGateway: AnyObject {
    func products() async throws -> [TipProduct]
    func purchase(_ id: String) async throws -> TipPurchaseResult
    func transactions() -> AsyncStream<TipTransaction>
    func finish(_ id: UInt64) async
}

/// The only StoreKit boundary. Business state consumes our own value types.
@MainActor final class StoreKitPurchaseGateway: PurchaseGateway {
    private var catalog: [String: Product] = [:]
    private var received: [UInt64: StoreKit.Transaction] = [:]
    func products() async throws -> [TipProduct] {
        let values = try await Product.products(for: TipJar.productIDs)
        catalog = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return values.map { TipProduct(id: $0.id, displayName: $0.displayName, description: $0.description,
                                      displayPrice: $0.displayPrice, consumable: $0.type == .consumable) }
    }
    private func adapt(_ result: VerificationResult<StoreKit.Transaction>) -> TipTransaction {
        let transaction: StoreKit.Transaction, verified: Bool
        switch result {
        case .verified(let value): transaction = value; verified = true
        case .unverified(let value, _): transaction = value; verified = false
        }
        if verified { received[transaction.id] = transaction }
        return TipTransaction(id: transaction.id, productID: transaction.productID,
                              consumable: transaction.productType == .consumable,
                              revoked: transaction.revocationDate != nil, verified: verified)
    }
    func purchase(_ id: String) async throws -> TipPurchaseResult {
        guard let product = catalog[id] else { throw AIError.invalidResponse }
        do {
            switch try await product.purchase() {
            case .success(let value): return .success(adapt(value))
            case .pending: return .pending
            case .userCancelled: return .userCancelled
            @unknown default: throw AIError.invalidResponse
            }
        } catch StoreKitError.userCancelled { return .userCancelled }
    }
    func transactions() -> AsyncStream<TipTransaction> {
        AsyncStream { continuation in
            let unfinished = Task { [weak self] in
                for await value in StoreKit.Transaction.unfinished {
                    guard let self, !Task.isCancelled else { return }
                    continuation.yield(self.adapt(value))
                }
            }
            let updates = Task { [weak self] in
                for await value in StoreKit.Transaction.updates {
                    guard let self, !Task.isCancelled else { break }
                    continuation.yield(self.adapt(value))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in unfinished.cancel(); updates.cancel() }
        }
    }
    func finish(_ id: UInt64) async {
        guard let value = received.removeValue(forKey: id) else { return }
        await value.finish()
    }
}

@MainActor @Observable final class TipJar {
    static let productIDs = ["dev.moonread.tip.star", "dev.moonread.tip.tea", "dev.moonread.tip.snack", "dev.moonread.tip.book"]
    enum Catalog { case idle, loading, ready, unavailable }
    private(set) var catalog = Catalog.idle
    private(set) var products: [TipProduct] = []
    private(set) var purchasing: String?
    private(set) var pending: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var thanked = false
    private(set) var celebrationID = UUID()
    private let gateway: any PurchaseGateway
    private let thanksDelay: @Sendable () async throws -> Void
    private var loadTask: Task<Void, Never>?
    private var thanksTask: Task<Void, Never>?
    private var handledTransactions: Set<UInt64> = []
    private var pendingGeneration = UUID()
    private var listening = false
    init(gateway: (any PurchaseGateway)? = nil,
         thanksDelay: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(4)) }) {
        self.gateway = gateway ?? StoreKitPurchaseGateway(); self.thanksDelay = thanksDelay
    }
    isolated deinit { thanksTask?.cancel() }
    func enterPage() async { if catalog != .ready { await load() } }
    func load() async {
        if let loadTask { await loadTask.value; return }
        catalog = .loading
        let task = Task {
            defer { loadTask = nil }
            do {
                let loaded = try await gateway.products()
                products = Self.productIDs.compactMap { id in loaded.first { $0.id == id && $0.consumable } }
                catalog = products.count == Self.productIDs.count ? .ready : .unavailable
            } catch { catalog = .unavailable }
        }
        loadTask = task; await task.value
    }
    func listenForTransactions() async {
        guard !listening else { return }
        listening = true; defer { listening = false }
        for await result in gateway.transactions() {
            guard !Task.isCancelled else { break }
            await complete(result)
        }
    }
    func leavePage() { pending.removeAll(); pendingGeneration = UUID() }
    func buy(_ product: TipProduct) async {
        guard purchasing == nil, catalog == .ready, products.contains(where: { $0.id == product.id }) else { return }
        pending.remove(product.id)
        let generation = pendingGeneration
        purchasing = product.id; errors[product.id] = nil
        defer { purchasing = nil }
        do {
            switch try await gateway.purchase(product.id) {
            case .success(let transaction): await complete(transaction)
            case .pending: if generation == pendingGeneration { pending.insert(product.id) }
            case .userCancelled: break
            }
        } catch is CancellationError { }
        catch { errors[product.id] = String(localized: "暂时无法完成付款，请重试") }
    }
    private func complete(_ transaction: TipTransaction) async {
        guard transaction.verified, Self.productIDs.contains(transaction.productID), transaction.consumable,
              !transaction.revoked, handledTransactions.insert(transaction.id).inserted else { return }
        await gateway.finish(transaction.id)
        pending.remove(transaction.productID); errors[transaction.productID] = nil
        thanked = true; celebrationID = UUID()
        thanksTask?.cancel()
        let delay = thanksDelay
        thanksTask = Task { [weak self] in
            do { try await delay() } catch { return }
            guard !Task.isCancelled else { return }
            self?.thanked = false
        }
    }
}

struct TipJarView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(TipJar.self) private var store
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
        }.pageScrollMargins().themedPage().navigationTitle("支持月读").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("tipJar")
            .task { await store.enterPage() }
            .onDisappear { store.leavePage() }
    }
    private func row(_ product: TipProduct) -> some View {
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
    private func description(_ product: TipProduct) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(product.displayName).font(.headline).foregroundStyle(Color(uiColor: theme.ink))
                .accessibilityIdentifier("tipJarTitle-" + product.id)
            Text(product.description).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityIdentifier("tipJarDescription-" + product.id)
        }.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain).accessibilityIdentifier("tipJarText-" + product.id)
    }
    private func price(_ product: TipProduct) -> some View {
        Button {
            Task { await store.buy(product) }
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
