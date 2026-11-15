import Combine
import Foundation
import GRDB
import Observation

extension AppDataService {
    func fixedFolderEntries(_ location: LibraryLocation, sort: LibrarySort) async throws -> [LibraryEntry] {
        try validateFolderRead(location)
        return try await fixedReaderRead { try $0.folderEntries(location, sort: sort) }
    }

    func fixedFolderDestinations(_ location: LibraryLocation) async throws -> [LibraryEntry] {
        try validateFolderRead(location)
        return try await fixedReaderRead { try $0.folderDestinations(location) }
    }

    func folderUpdates(_ location: LibraryLocation, sort: LibrarySort) throws -> AsyncThrowingStream<[LibraryEntry], Error> {
        try Task.checkCancellation()
        try validateFolderRead(location)
        let index = try relationalUserIndex()
        let scope = index.lease.scope
        let (stream, sink) = AsyncThrowingStream.makeStream(of: [LibraryEntry].self, bufferingPolicy: .bufferingNewest(1))
        let observation = ValueObservation.tracking { try FolderRead.page($0, scope: scope, location: location) }
            .removeDuplicates()
        let token = try index.session.observeUsers(index.lease, observation) { result in
            do {
                // The observation receiver runs outside the database writer.
                sink.yield(try FolderRead.entries(result.get(), sort: sort))
            } catch {
                sink.finish(throwing: error)
            }
        }
        sink.onTermination = { _ in token.cancel() }
        return stream
    }

    private func validateFolderRead(_ location: LibraryLocation) throws {
        #if DEBUG
        if testSession != nil, ProcessInfo.processInfo.arguments.contains("--ui-test-introduction-directory-failure") {
            throw CocoaError(.fileReadNoPermission)
        }
        #endif
        do { try validateRelativePath(path: location.path, allowRoot: true) }
        catch { throw ReaderError.InvalidSettings }
    }
}

/// One page owns one observation, with its lifetime tied to the page task.
@MainActor @Observable
final class FolderStore {
    typealias Updates = @Sendable (LibraryLocation, LibrarySort) async throws -> AsyncThrowingStream<[LibraryEntry], Error>
    private(set) var snapshot: [LibraryEntry]?
    private(set) var failed = false
    private(set) var requestRevision = 0
    let loading = LoadingState()

    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private var accountChange: AnyCancellable?

    init(service: AppDataService) {
        updates = { try await service.folderUpdates($0, sort: $1) }
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            guard let self else { return }
            generation = UUID()
            snapshot = nil
            failed = false
            requestRevision &+= 1
        }
    }

    func retryIfFailed() {
        if failed { requestRevision &+= 1 }
    }

    func observe(_ location: LibraryLocation, sort: LibrarySort = .reading,
                 didLoad: ([LibraryEntry]) -> Void, didFail: (Error) -> Void) async {
        let ticket = UUID(); generation = ticket
        let request = loading.begin(); defer { loading.finish(request) }
        failed = false
        do {
            try await AppDataService.libraryTestLatency()
            let stream = try await updates(location, sort)
            for try await entries in stream {
                guard !Task.isCancelled, generation == ticket else { return }
                if snapshot != entries { snapshot = entries }
                loading.finish(request)
                didLoad(entries)
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == ticket else { return }
            failed = true
            didFail(error)
        }
    }
}
