import SwiftUI
import UniformTypeIdentifiers

extension LibraryModel {
    func startCloudDiscovery(reset: Bool = false) {
        if reset { resetCloudDiscovery() }
        guard builtinDiscovery != .notRequired else { cloudDiscoverySource.stop(); return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-cloud") { return }
        #endif
        cloudDiscoverySource.start(generation: discoveryGeneration,
            receive: { [weak self] in self?.receiveCloudDiscovery($0) },
            failed: { [weak self] generation in if self?.builtinDiscovery != .ready { self?.failCloudDiscovery(generation) } })
        armDiscoveryTimeout()
    }
    private func armDiscoveryTimeout() {
        let generation = discoveryGeneration, snapshotRevision = discoveryRevision, wait = waitForDiscoveryTimeout
        discoveryTimeout?.cancel()
        discoveryTimeout = Task { [weak self] in
            do { try await wait(); try Task.checkCancellation() } catch { return }
            guard let self, generation == discoveryGeneration, snapshotRevision == discoveryRevision,
                  builtinDiscovery != .ready else { return }
            failCloudDiscovery(generation)
        }
    }
    func resetCloudDiscovery() {
        cloudDiscoverySource.stop()
        discoveryTask?.cancel(); discoveryTask = nil
        discoveryTimeout?.cancel(); discoveryTimeout = nil
        discoveryGeneration = UUID(); discoveryRevision = 0; adoptedDiscoveryRevision = nil
        discoveryRoot = nil; pendingCloudSnapshot = nil
        builtinDiscovery = requiresCloudDiscovery() ? .discovering : .notRequired
    }
    func retryPendingCloudDiscovery() {
        guard builtinDiscovery == .unavailable, discoveryTask == nil, let pendingCloudSnapshot else { return }
        adoptCloudSnapshot(pendingCloudSnapshot)
    }
    func failCloudDiscovery(_ generation: UUID) {
        guard generation == discoveryGeneration, builtinDiscovery != .notRequired else { return }
        builtinDiscovery = .unavailable
    }
    func receiveCloudDiscovery(_ snapshot: CloudDocumentSnapshot) {
        guard snapshot.generation == discoveryGeneration, snapshot.gathered, snapshot.revision > discoveryRevision else { return }
        discoveryRevision = snapshot.revision; adoptedDiscoveryRevision = nil
        pendingCloudSnapshot = snapshot
        adoptCloudSnapshot(snapshot)
    }
    private func adoptCloudSnapshot(_ snapshot: CloudDocumentSnapshot) {
        builtinDiscovery = .discovering; armDiscoveryTimeout()
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision { discoveryTask = nil }
            }
            do {
                try await adoptCloudDocuments(snapshot.items)
                try Task.checkCancellation()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                try await reload()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                let root = await service.cloudDiscoveryRoot()
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                discoveryRoot = root
                adoptedDiscoveryRevision = snapshot.revision
                revision += 1 // Even an equal/empty home must reload the directory before ready.
            } catch is CancellationError { }
            catch {
                guard snapshot.generation == discoveryGeneration, snapshot.revision == discoveryRevision else { return }
                failCloudDiscovery(snapshot.generation)
            }
        }
    }
    func builtinDirectoryLoaded(generation: UUID, snapshotRevision: Int) {
        guard generation == discoveryGeneration, snapshotRevision == discoveryRevision,
              adoptedDiscoveryRevision == snapshotRevision else { return }
        builtinDiscovery = .ready; discoveryTimeout?.cancel(); discoveryTimeout = nil
    }
    func retryCloudDiscovery() { startCloudDiscovery(reset: true) }

    /// The introduction participates in the same directory acknowledgement as
    /// LibraryFolderView. It never treats an unadopted metadata result as empty.
    func welcomeStoryForIntroduction() async throws -> LibraryEntry? {
        guard homeReady, builtinDiscovery == .ready || builtinDiscovery == .notRequired else {
            throw LibraryFileError.missingShelf
        }
        let generation = discoveryGeneration
        let root = await service.cloudDiscoveryRoot()
        guard generation == discoveryGeneration,
              builtinDiscovery == .ready || builtinDiscovery == .notRequired else { throw CancellationError() }
        let entry = try await service.welcomeStory(expectedRoot: root)
        guard generation == discoveryGeneration else { throw CancellationError() }
        try await reload()
        return entry
    }

}
