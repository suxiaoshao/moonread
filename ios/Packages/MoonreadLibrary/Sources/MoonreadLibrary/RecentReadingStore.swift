import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import Observation

/// Held in a page's State. A push or a tab change need not end the page's
/// identity. The result is released only after the last page releases its use.
public final class RecentReadingUse: Sendable {
    let id: UUID
    private let onRelease: @Sendable (UUID) -> Void

    init(id: UUID, onRelease: @escaping @Sendable (UUID) -> Void) {
        self.id = id; self.onRelease = onRelease
    }

    deinit { onRelease(id) }
}

@MainActor @Observable
public final class RecentReadingStore {
    public typealias Updates = @Sendable (UInt32) async throws -> AsyncThrowingStream<RecentReadingRead.Output, Error>
    public static let homeLimit: UInt32 = 10
    public static let fullLimit: UInt32 = 1000

    public private(set) var value: RecentReadingRead.Output?
    public private(set) var failure: String?
    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private let errorMessage: (Error) -> String
    @ObservationIgnored private var uses = [UUID: UInt32]()
    @ObservationIgnored private var limit: UInt32 = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var accountChange: AnyCancellable?

    public init(updates: @escaping Updates,
                observeAccount: (@escaping @MainActor @Sendable () -> Void) -> AnyCancellable?,
                errorMessage: @escaping (Error) -> String) {
        self.updates = updates
        self.errorMessage = errorMessage
        accountChange = observeAccount { [weak self] in
            self?.rebind()
        }
    }

    public func use(limit: UInt32) -> RecentReadingUse {
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

    public func retry() {
        guard limit > 0 else { return }
        replaceObservation()
    }

    public func retryIfFailed() {
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
                failure = errorMessage(error)
            }
        }
    }
}
