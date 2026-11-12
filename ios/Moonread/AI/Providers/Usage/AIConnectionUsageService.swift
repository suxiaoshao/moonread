import Foundation
import Observation

enum AIUsageQueryState: Equatable {
    case idle(AIUsageSnapshot?)
    case loading(AIUsageSnapshot?)
    case ready(AIUsageSnapshot)
    case failed(AIUsageFailure, previous: AIUsageSnapshot?)

    var snapshot: AIUsageSnapshot? {
        switch self {
        case .idle(let value), .loading(let value), .failed(_, let value): value
        case .ready(let value): value
        }
    }

    var retryAt: Date? {
        if case .failed(let error, _) = self { error.retryAt } else { nil }
    }

    func canRefresh(at date: Date) -> Bool {
        if case .loading = self { return false }
        return retryAt.map { date >= $0 } ?? true
    }
}

enum AIUsagePresentation: Equatable {
    case hidden
    case linkOnly(URL, name: String?)
    case configure(console: URL)
    case query(AIUsageQueryState, console: URL)
}

/// Owns detail visits and transient billing data. Connection and AI admission stay with their existing owners.
@MainActor @Observable final class AIConnectionUsageService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Record {
        let identity: String
        let state: AIUsageQueryState
    }

    private struct Request {
        let id: UUID
        let nativeToken: UUID
        let task: Task<Void, Never>
    }

    private let availability: AIAvailability
    private let transport: Transport?
    private let now: @Sendable () -> Date
    @ObservationIgnored private weak var providers: AIConnectionService?
    @ObservationIgnored private var visits: [String: Set<UUID>] = [:]
    @ObservationIgnored private var requests: [String: Request] = [:]
    private var records: [String: Record] = [:]

    init(availability: AIAvailability, now: @escaping @Sendable () -> Date = { .now }, transport: Transport? = nil) {
        self.availability = availability
        self.now = now
        self.transport = transport
    }

    func bind(_ providers: AIConnectionService) { self.providers = providers }

    /// Pure presentation read. A navigation destination can be constructed without initiating a query.
    func presentation(for connection: AIConnection) -> AIUsagePresentation {
        guard availability.isAvailable else { return .hidden }
        switch AIUsageAdapter.capability(for: connection) {
        case .linkOnly(.console(let url, let name)): return .linkOnly(url, name: name)
        case .linkOnly(.chatGPT), .linkOnly(.kimiAccount), .unavailable: return .hidden
        case .query(_, let console):
            guard providers?.canQueryUsage(connection) == true else { return .configure(console: console) }
            return .query(state(for: connection), console: console)
        }
    }

    func enterDetail(_ connectionID: String, visit: UUID) {
        let wasVisible = visits[connectionID] != nil
        visits[connectionID, default: []].insert(visit)
        if !wasVisible { refresh(connectionID) }
    }

    func leaveDetail(_ connectionID: String, visit: UUID) {
        guard visits[connectionID]?.remove(visit) != nil, visits[connectionID]?.isEmpty == true else { return }
        visits[connectionID] = nil
        suspend(connectionID)
    }

    /// Pause old admission during a credential write; the last success still belongs to it until the write succeeds.
    func suspend(_ connectionID: String) {
        stopRequest(connectionID, cancel: true)
        if let record = records[connectionID], case .loading(let previous) = record.state {
            records[connectionID] = Record(identity: record.identity, state: .idle(previous))
        }
    }

    func invalidate(_ connectionID: String) {
        stopRequest(connectionID, cancel: true)
        records[connectionID] = nil
    }

    func cancelAllAndClear() {
        for id in Array(requests.keys) { stopRequest(id, cancel: true) }
        records.removeAll()
    }

    func refresh(_ connectionID: String) {
        guard availability.isAvailable, visits[connectionID] != nil, requests[connectionID] == nil,
              let providers, let connection = providers.connections.first(where: { $0.id == connectionID }),
              case .query(let adapter, _) = AIUsageAdapter.capability(for: connection),
              providers.canQueryUsage(connection) else { return }
        let previous = state(for: connection)
        guard previous.canRefresh(at: now()) else { return }

        let id = UUID(), identity = connection.catalogIdentity, generation = availability.generation
        let task = Task { [weak self, weak providers] in
            guard let self, let providers, self.isCurrent(connectionID, request: id, identity: identity, generation: generation) else { return }
            let result: AIUsageQueryState
            do {
                let credential = try await providers.credential(connection)
                try Task.checkCancellation()
                guard self.isCurrent(connectionID, request: id, identity: identity, generation: generation) else { return }
                guard case .apiKey(let secret) = credential else { throw AIUsageFailure.unauthorized }
                let request = adapter.request(credential: secret)
                let (data, response) = if let transport = self.transport {
                    try await transport(request)
                } else {
                    try await providers.auth.requestData(request, delegate: AIUsageRedirectPolicy())
                }
                let receivedAt = self.now()
                let usage = try adapter.decode(data, response: response, receivedAt: receivedAt)
                result = .ready(.init(usage: usage, fetchedAt: receivedAt))
            } catch is CancellationError {
                result = .idle(previous.snapshot)
            } catch let error as AIUsageFailure {
                result = .failed(error, previous: previous.snapshot)
            } catch AIError.loginRequired {
                result = .failed(.unauthorized, previous: previous.snapshot)
            } catch {
                result = .failed(.temporary, previous: previous.snapshot)
            }

            guard self.isCurrent(connectionID, request: id, identity: identity, generation: generation) else { return }
            self.stopRequest(connectionID, cancel: false)
            self.records[connectionID] = Record(identity: identity, state: Task.isCancelled ? .idle(previous.snapshot) : result)
        }

        do {
            let token = try providers.trackNativeRequest(connectionID: connectionID, kind: .usage, cancel: { task.cancel() })
            requests[connectionID] = Request(id: id, nativeToken: token, task: task)
            records[connectionID] = Record(identity: identity, state: .loading(previous.snapshot))
        } catch { task.cancel() }
    }

    private func state(for connection: AIConnection) -> AIUsageQueryState {
        guard let record = records[connection.id], record.identity == connection.catalogIdentity else { return .idle(nil) }
        return record.state
    }

    private func isCurrent(_ connectionID: String, request: UUID, identity: String, generation: UUID) -> Bool {
        availability.isAvailable && availability.generation == generation && visits[connectionID] != nil &&
            requests[connectionID]?.id == request && providers?.connections.first(where: { $0.id == connectionID })?.catalogIdentity == identity
    }

    private func stopRequest(_ connectionID: String, cancel: Bool) {
        guard let request = requests.removeValue(forKey: connectionID) else { return }
        if cancel { request.task.cancel() }
        providers?.finishNativeRequest(request.nativeToken)
    }
}
