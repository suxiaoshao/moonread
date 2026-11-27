import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import Observation

/// One page owns one observation, with its lifetime tied to the page task.
@MainActor @Observable
public final class FolderStore {
    public typealias Updates = @Sendable (LibraryLocation, LibrarySort) async throws -> AsyncThrowingStream<[LibraryEntry], Error>
    public private(set) var snapshot: [LibraryEntry]?
    public private(set) var failed = false
    public private(set) var requestRevision = 0
    public let loading = LoadingState()

    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private let beforeRead: @Sendable () async throws -> Void
    @ObservationIgnored private var accountChange: AnyCancellable?

    public init(updates: @escaping Updates, beforeRead: @escaping @Sendable () async throws -> Void = {},
                observeAccount: (@escaping @MainActor @Sendable () -> Void) -> AnyCancellable? = { _ in nil }) {
        self.updates = updates
        self.beforeRead = beforeRead
        accountChange = observeAccount { [weak self] in
            guard let self else { return }
            snapshot = nil
            failed = false
            requestRevision &+= 1
        }
    }

    public func retryIfFailed() {
        if failed { requestRevision &+= 1 }
    }

    public func observe(_ location: LibraryLocation, sort: LibrarySort = .reading,
                 didLoad: ([LibraryEntry]) -> Void, didFail: (Error) -> Void) async {
        let revision = requestRevision
        let request = loading.begin(); defer { loading.finish(request) }
        failed = false
        do {
            try await beforeRead()
            let stream = try await updates(location, sort)
            for try await entries in stream {
                guard !Task.isCancelled, requestRevision == revision else { return }
                if snapshot != entries { snapshot = entries }
                loading.finish(request)
                didLoad(entries)
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            failed = true
            didFail(error)
        }
    }
}
