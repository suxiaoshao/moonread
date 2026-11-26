import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDesign
import MoonreadSearchText
import Observation

public struct SearchKey: Hashable, Sendable {
    public let term: String
    public var configuration = BookSearchConfiguration()
    public var virtualShelf = false
    public let revision: Int
    public let retry: Int
    public let aiAvailable: Bool

    public init(term: String, configuration: BookSearchConfiguration = .init(), virtualShelf: Bool = false,
                revision: Int, retry: Int, aiAvailable: Bool) {
        self.term = term; self.configuration = configuration; self.virtualShelf = virtualShelf
        self.revision = revision; self.retry = retry; self.aiAvailable = aiAvailable
    }
}

/// Owns publication independently of the SwiftUI task's cancellation timing.
@MainActor @Observable public final class AppSearchResults {
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var matches: [String: LibraryQueryRules.SearchMatch] = [:]
    public private(set) var conversations: [AIConversationSearchHit] = []
    public private(set) var completedKey: SearchKey?
    public private(set) var unknownCount = 0
    public private(set) var error: String?
    public let loading = LoadingState()
    public private(set) var refreshing = false
    public private(set) var authorityRevision = 0
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var accountChange: AnyCancellable?
    private let describeError: (Error) -> String

    public init(observeAccount: (@escaping @MainActor () -> Void) -> AnyCancellable,
                describeError: @escaping (Error) -> String) {
        self.describeError = describeError
        accountChange = observeAccount { [weak self] in
            guard let self else { return }
            generation = UUID(); reset(); authorityRevision &+= 1
        }
    }

    private func reset() {
        if let request = loading.request { loading.finish(request) }
        completedKey = nil; error = nil; entries = []; matches = [:]; conversations = []; unknownCount = 0; refreshing = false
    }

    public func observe(_ key: SearchKey, hasCriteria: Bool,
                 invalidations: () async throws -> AsyncThrowingStream<Void, Error>,
                 search: () async throws -> LibraryQueryRules.SearchOutcome,
                 conversations: () async throws -> [AIConversationSearchHit]) async {
        guard !Task.isCancelled else { return }
        let token = UUID(); generation = token
        guard hasCriteria else { reset(); return }
        let request = loading.begin()
        defer {
            loading.finish(request)
            if generation == token { refreshing = false }
        }
        do {
            let stream = try await invalidations()
            var talks: [AIConversationSearchHit]?
            for try await _ in stream {
                guard generation == token, !Task.isCancelled else { return }
                refreshing = true
                let books = try await search()
                if talks == nil { talks = try await conversations() }
                guard generation == token, !Task.isCancelled else { return }
                entries = books.entries; unknownCount = books.unknownCount
                matches = books.matches
                self.conversations = talks ?? []
                error = nil; completedKey = key; refreshing = false
                loading.finish(request)
            }
        } catch is CancellationError { }
        catch { if generation == token, !Task.isCancelled { self.error = describeError(error) } }
    }
}
