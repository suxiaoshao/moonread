import Combine
import Foundation
import GRDB
import Observation

extension AppDataService {
    func recentReadingUpdates(limit: UInt32) throws -> AsyncThrowingStream<RecentReadingRead.Output, Error> {
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        let (stream, sink) = AsyncThrowingStream.makeStream(of: RecentReadingRead.Output.self, bufferingPolicy: .bufferingNewest(1))
        let scope = index.lease.scope
        let observation = ValueObservation.tracking { try RecentReadingRead.fetch($0, scope: scope, limit: limit) }
            .removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            switch result {
            case .success(let value): sink.yield(value)
            case .failure(let error): sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}

/// Held in a page's State. A push or a tab change need not end the page's
/// identity. The result is released only after the last page releases its use.
final class RecentReadingUse: Sendable {
    let id: UUID
    private let onRelease: @Sendable (UUID) -> Void

    init(id: UUID, onRelease: @escaping @Sendable (UUID) -> Void) {
        self.id = id; self.onRelease = onRelease
    }

    deinit { onRelease(id) }
}

@MainActor @Observable
final class RecentReadingStore {
    typealias Updates = @Sendable (UInt32) async throws -> AsyncThrowingStream<RecentReadingRead.Output, Error>
    static let homeLimit: UInt32 = 10
    static let fullLimit: UInt32 = 1000

    private(set) var value: RecentReadingRead.Output?
    private(set) var failure: String?
    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private var uses = [UUID: UInt32]()
    @ObservationIgnored private var limit: UInt32 = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var accountChange: AnyCancellable?

    init(service: AppDataService) {
        updates = { try await service.recentReadingUpdates(limit: $0) }
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            self?.rebind()
        }
    }

    // Deterministic boundary for the real store's parameter/lifetime tests.
    init(updates: @escaping Updates) { self.updates = updates }

    func use(limit: UInt32) -> RecentReadingUse {
        let id = UUID()
        uses[id] = limit
        adjust()
        return RecentReadingUse(id: id) { [weak self] id in
            Task { @MainActor in self?.release(id) }
        }
    }

    private func release(_ id: UUID) {
        uses[id] = nil
        adjust()
    }

    func retry() {
        guard limit > 0 else { return }
        replaceObservation()
    }

    func retryIfFailed() {
        if failure != nil { retry() }
    }

    private func rebind() {
        // Never show data from a different authority while its query starts.
        value = nil
        replaceObservation()
    }

    private func adjust() {
        let next = uses.values.max() ?? 0
        guard next != limit else { return }
        limit = next
        if next == 0 { value = nil }
        else if let value, value.recentReading.count > Int(next) {
            self.value = .init(recentReading: Array(value.recentReading.prefix(Int(next))))
        }
        replaceObservation()
    }

    private func replaceObservation() {
        work?.cancel(); work = nil
        generation = UUID()
        failure = nil
        guard limit > 0 else { return }
        let parameter = limit, ticket = generation, updates = updates
        work = Task { [weak self] in
            do {
                let stream = try await updates(parameter)
                for try await result in stream {
                    guard !Task.isCancelled, let self, generation == ticket else { break }
                    if value != result { value = result }
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, let self, generation == ticket else { return }
                failure = ReaderMessages.error(error)
            }
        }
    }
}
