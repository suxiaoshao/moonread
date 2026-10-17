import Foundation
import Observation
import CryptoKit

/// Application-owned, local-only permission. No content or credentials enter this store.
@MainActor @Observable final class AIDataSharingConsent {
    enum Scope: String, Codable, CaseIterable, Hashable, Sendable {
        case conversation, reading, statistics, images, webSources
        var description: String {
            switch self {
            case .conversation: String(localized: "问题、相关会话历史及自动摘要")
            case .reading: String(localized: "阅读附件，以及工具可读取的书目、正文和批注")
            case .statistics: String(localized: "工具可读取的阅读时段、时长及活动")
            case .images: String(localized: "本次或历史中的图片附件")
            case .webSources: String(localized: "搜索查询；结果网页和图片站点也会收到 URL 请求与 IP 地址")
            }
        }
    }
    struct Destination: Codable, Hashable, Sendable {
        let connectionID: String
        let provider: String
        let protocolIdentity: String
        let endpoint: String
        let accountGeneration: String
        let accountFingerprint: String
        let disclosureVersion: Int
        var host: String { URL(string: endpoint)?.host ?? "" }
    }
    struct Request: Identifiable, Sendable {
        let id: UUID
        let owner: String
        let destination: Destination
        let service: String
        let purpose: String
        let scopes: Set<Scope>
        let gateway: Bool
    }
    private struct Grant: Codable { let destination: Destination; var scopes: Set<Scope> }
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let current: @MainActor () -> AIConnection?
    }
    private(set) var requests: [Request] = []
    @ObservationIgnored private var waiters: [UUID: Waiter] = [:]
    @ObservationIgnored private var grants: [Grant]
    @ObservationIgnored private var generations: [String: String]
    @ObservationIgnored private var owners: [String: Set<String>] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var waitingChanged: (String, Bool) -> Void = { _, _ in }
    @ObservationIgnored var revoked: (String, Set<String>) -> Void = { _, _ in }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        grants = AIPersistedJSON.readArray(Grant.self, data: defaults.data(forKey: "Moonread.ai.sharing.grants"), key: "Moonread.ai.sharing.grants")
        generations = defaults.dictionary(forKey: "Moonread.ai.sharing.generations") as? [String: String] ?? [:]
    }
    func destination(_ connection: AIConnection, accountFingerprint: String = "") throws -> Destination {
        guard var url = URLComponents(string: connection.baseURL), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AIError.noModel }
        url.scheme = url.scheme?.lowercased(); url.host = host.lowercased()
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let endpoint = url.string else { throw AIError.noModel }
        return .init(connectionID: connection.id, provider: connection.providerID,
                     protocolIdentity: connection.protocolIdentity, endpoint: endpoint,
                     accountGeneration: generations[connection.id] ?? "initial", accountFingerprint: accountFingerprint, disclosureVersion: 1)
    }
    static func chatScopes(tools: Bool, attachments: [AIReadingAttachment], entries: [AIAgentEntry]) -> Set<Scope> {
        var scopes: Set<Scope> = [.conversation]
        let hasToolHistory = entries.contains { $0.message.object["role"]?.string == "tool" }
        if tools || hasToolHistory || attachments.contains(where: { $0.kind != .image && $0.kind != .statistics }) { scopes.insert(.reading) }
        if tools || hasToolHistory || attachments.contains(where: { $0.kind == .statistics }) { scopes.insert(.statistics) }
        if attachments.contains(where: { $0.kind == .image }) || entries.contains(where: { !AIAssetReferences.entry($0).isEmpty }) { scopes.insert(.images) }
        return scopes
    }
    func permits(_ connection: AIConnection, scopes: Set<Scope>, accountFingerprint: String = "") -> Bool {
        guard let key = try? destination(connection, accountFingerprint: accountFingerprint) else { return false }
        return grants.contains { $0.destination == key && $0.scopes.isSuperset(of: scopes) }
    }
    func scopes(owner: String) -> Set<Scope> {
        grants.filter { owners[$0.destination.connectionID]?.contains(owner) == true }
            .reduce(into: Set<Scope>()) { $0.formUnion($1.scopes) }
    }
    func authorize(_ connection: AIConnection, owner: String, purpose: String, scopes: Set<Scope>,
                   accountFingerprint: String = "", current: @escaping @MainActor () -> AIConnection?) async throws {
        try Task.checkCancellation()
        let key = try destination(connection, accountFingerprint: accountFingerprint)
        guard current().flatMap({ try? destination($0, accountFingerprint: accountFingerprint) }) == key else { throw CancellationError() }
        owners[connection.id, default: []].insert(owner)
        if permits(connection, scopes: scopes, accountFingerprint: accountFingerprint) { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = .init(continuation: continuation, current: current)
                requests.append(.init(id: id, owner: owner, destination: key, service: connection.serviceName,
                                      purpose: purpose, scopes: scopes, gateway: connection.providerID == "openrouter" || connection.providerID == "custom"))
                waitingChanged(owner, true)
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
        try Task.checkCancellation()
        guard current().flatMap({ try? destination($0, accountFingerprint: accountFingerprint) }) == key, permits(connection, scopes: scopes, accountFingerprint: accountFingerprint) else { throw CancellationError() }
    }
    func answer(_ id: UUID, approved: Bool) {
        guard let request = requests.first(where: { $0.id == id }), let waiter = waiters[id] else { return }
        guard approved, waiter.current().flatMap({ try? destination($0, accountFingerprint: request.destination.accountFingerprint) }) == request.destination else { cancel(id); return }
        if let index = grants.firstIndex(where: { $0.destination == request.destination }) { grants[index].scopes.formUnion(request.scopes) }
        else { grants.append(.init(destination: request.destination, scopes: request.scopes)) }
        save()
        for candidate in requests.filter({ $0.destination == request.destination && request.scopes.isSuperset(of: $0.scopes) }) {
            guard let pending = waiters[candidate.id], pending.current().flatMap({ try? destination($0, accountFingerprint: candidate.destination.accountFingerprint) }) == candidate.destination else { cancel(candidate.id); continue }
            requests.removeAll { $0.id == candidate.id }
            waiters.removeValue(forKey: candidate.id)?.continuation.resume()
            waitingChanged(candidate.owner, requests.contains { $0.owner == candidate.owner })
        }
    }
    private func cancel(_ id: UUID) {
        let owner = requests.first { $0.id == id }?.owner
        requests.removeAll { $0.id == id }
        waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
        if let owner { waitingChanged(owner, requests.contains { $0.owner == owner }) }
    }
    func cancel(owner: String) { for id in requests.filter({ $0.owner == owner }).map(\.id) { cancel(id) } }
    func revoke(_ connectionID: String) {
        grants.removeAll { $0.destination.connectionID == connectionID }
        generations[connectionID] = UUID().uuidString
        save()
        for id in requests.filter({ $0.destination.connectionID == connectionID }).map(\.id) { cancel(id) }
        revoked(connectionID, owners.removeValue(forKey: connectionID) ?? [])
    }
    private func save() {
        do {
            let data = try AIPersistedJSON.encodeArray(grants, original: defaults.data(forKey: "Moonread.ai.sharing.grants"), id: \.destination)
            defaults.set(data, forKey: "Moonread.ai.sharing.grants")
        } catch { AIPersistedJSON.skipped("Moonread.ai.sharing.grants (write refused)", index: -1) }
        defaults.set(generations, forKey: "Moonread.ai.sharing.generations")
    }
}

@MainActor extension AIConnectionService {
    /// Match the selected endpoint and effective protocol, rather than a display name.
    func authorizeSharing(connection: AIConnection, model: AIModelOption, credential: AICredential,
                          owner: String, purpose: String, scopes: Set<AIDataSharingConsent.Scope>, accountGeneration: String) async throws {
        try availability.requireAvailable()
        guard try sharing.destination(connection).accountGeneration == accountGeneration else { throw CancellationError() }
        var recipient = connection
        recipient.wireProtocol = model.wireProtocol ?? connection.wireProtocol
        let target = recipient
        // Account identifiers are not credentials; retain only a pseudonymous equality key.
        let accountFingerprint = credential.accountID.isEmpty ? "" : SHA256.hash(data: Data(credential.accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        try await sharing.authorize(target, owner: owner, purpose: purpose, scopes: scopes, accountFingerprint: accountFingerprint) { [weak self] in
            guard let current = self?.connections.first(where: { $0.id == connection.id }),
                  current.baseURL == connection.baseURL, current.providerID == connection.providerID,
                  current.protocolIdentity == connection.protocolIdentity,
                  (try? self?.sharing.destination(current).accountGeneration) == accountGeneration else { return nil }
            return target
        }
    }
}
