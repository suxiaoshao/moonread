import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Combine
import Foundation
import GRDB
import Observation

struct CatalogueTagSection: Sendable {
    let kind: LibraryTagGroupKind
    let tag: String
    let fileIDs: [String]
}

/// Only the grouping in use is assembled. Tag sections refer to one
/// physical-file card map; counting books never counts memberships.
struct CatalogueSnapshot: Sendable {
    enum Content: Sendable {
        case names([LibraryNameGroup])
        case tags([CatalogueTagSection], cards: [String: LibraryEntry])
    }

    let shelfID: String
    let content: Content
    let bookCount: UInt64

    init(_ ordered: CatalogueRead.Ordered, shelfID: String) throws {
        self.shelfID = shelfID
        bookCount = UInt64(ordered.entries.count)
        if let tags = ordered.groups {
            let sections = try tags.shelfTagGroups.map { group in
                try CatalogueTagSection(kind: CatalogueRead.sectionKind(group), tag: group.tag, fileIDs: group.fileIDs)
            }
            content = .tags(sections, cards: Dictionary(uniqueKeysWithValues: ordered.entries.map { ($0.id,$0) }))
        } else {
            content = .names(LibraryNameGroup.group(ordered.entries))
        }
    }

    var grouping: LibraryGrouping {
        if case .tags = content { return .tags }
        return .name
    }
}

extension AppDataService {
    func catalogueUpdates(_ shelfID: String, grouping: LibraryGrouping) throws -> AsyncThrowingStream<CatalogueSnapshot, Error> {
        try Task.checkCancellation()
        let index = try relationalUserIndex(), scope = index.lease.scope
        let (stream, sink) = AsyncThrowingStream.makeStream(of: CatalogueSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let observation = ValueObservation.tracking { try CatalogueRead.fetch($0, scope: scope, shelfID: shelfID, grouping: grouping) }
            .removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            do { sink.yield(try CatalogueSnapshot(CatalogueRead.order(result.get()), shelfID: shelfID)) }
            catch { sink.finish(throwing: error) }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }
}

@MainActor @Observable
final class CatalogueStore {
    typealias Updates = @Sendable (String, LibraryGrouping) async throws -> AsyncThrowingStream<CatalogueSnapshot, Error>
    private(set) var snapshot: CatalogueSnapshot?
    private(set) var failed = false
    private(set) var requestRevision = 0
    let loading = LoadingState()

    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private var accountChange: AnyCancellable?

    init(service: AppDataService) {
        updates = { try await service.catalogueUpdates($0, grouping: $1) }
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            guard let self else { return }
            snapshot = nil
            failed = false
            requestRevision &+= 1
        }
    }

    init(updates: @escaping Updates) { self.updates = updates }

    func retryIfFailed() {
        if failed { requestRevision &+= 1 }
    }

    func observe(shelfID: String, grouping: LibraryGrouping, didFail: (Error) -> Void) async {
        let revision = requestRevision
        let request = loading.begin(); defer { loading.finish(request) }
        failed = false
        do {
            try await AppDataService.libraryTestLatency()
            let stream = try await updates(shelfID, grouping)
            for try await value in stream {
                guard !Task.isCancelled, requestRevision == revision else { return }
                snapshot = value
                loading.finish(request)
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            failed = true
            didFail(error)
        }
    }
}
