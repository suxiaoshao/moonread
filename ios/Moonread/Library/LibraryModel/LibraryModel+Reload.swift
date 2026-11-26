import MoonreadCoreBindings
import SwiftUI
import UniformTypeIdentifiers

extension LibraryModel {
    @discardableResult
    func load() async -> Bool {
        if initialized { return true }
        if let initialization { return await initialization.value }
        // The model owns initialization; cancellation of one view/caller must
        // not cancel preparation needed by another caller (including Open URL).
        let task = Task<Bool, Never> { [self] in
            let request = loading.begin()
            defer { loading.finish(request); initialization = nil }
            do {
                try await prepareLibrary()
                try await reload()
                initialized = true
                self.error = nil
                Task { await service.startUserRecovery(); await refresh() }
                return true
            } catch is CancellationError { return false }
            catch { self.error = ReaderMessages.error(error); return false }
        }
        initialization = task
        return await task.value
    }
    func reload() async throws {
        let request = summaries.begin(); defer { summaries.finish(request) }
        let token = UUID(); homeRequest = token
        let structure = try await service.libraryStructure()
        let hasUserBooks = try await service.hasUserImportedBooks()
        let localShelves = try await service.shelves()
        if let discoveryRoot, discoveryRoot != (await service.cloudDiscoveryRoot()) {
            startCloudDiscovery(reset: true)
        }
        let next = HomeSnapshot(shelves: localShelves)
        try Task.checkCancellation()
        guard homeRequest == token else { return }
        let structuralChange = libraryStructure != nil && libraryStructure != structure
        libraryStructure = structure
        hasUserImportedBooks = hasUserBooks
        if hasUserBooks { Onboarding.shared.didImport() }
        if structuralChange { revision += 1 }
        readingInputRevision &+= 1
        publishHome(next)
        homeReady = true
        let ids = Set(localShelves.map(\.id))
        shelfIndexes = shelfIndexes.filter { ids.contains($0.key) }
        Task {
            await refreshShelfRecovery()
            for shelf in localShelves where shelfIndexes[shelf.id] == nil { await refreshIndexSummary(shelf.id) }
        }
    }
    private func publishHome(_ next: HomeSnapshot) {
        guard next != home else { return }
        let shelfChanged = next.shelves != home.shelves
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { home = next; if shelfChanged { revision += 1 } }
    }
    /// Readers still update legacy consumers that have not moved to
    /// observation. Recents follows the committed database on its own.
    func reloadBook(_ route: ReaderRoute) async {
        readingInputRevision &+= 1
    }
    func returnedToLibrary() {
        if automaticRefreshDeferred, !shell.path.contains(where: \.isReader) { automaticRefreshDeferred = false; scheduleRefresh() }
    }
    /// One library refresh at a time. A caller arriving while one runs asks for
    /// another pass and waits for the shared work, so a pull's spinner ends with it.
    func refresh(showIndicator: Bool = false, userInitiated: Bool = false) async {
        if userInitiated {
            recentReading.retryIfFailed()
            await service.scheduleRecentRestoration(retry: true)
        }
        guard !busy else { return }
        if !userInitiated, shell.path.contains(where: \.isReader) { automaticRefreshDeferred = true; return }
        guard initialized else { _ = await load(); return }
        if !showIndicator || !userInitiated { nativeRefreshing = true }
        if userInitiated { explicitRefresh = true }
        if let refreshWork { if userInitiated { refreshAgain = true }; await refreshWork.value; return }
        let request = showIndicator && userInitiated ? refreshing.begin() : nil
        let work = Task { [self] in
            do {
                repeat {
                    refreshAgain = false
                    try await refreshLibrary(); try await reload(); retryPendingCloudDiscovery()
                } while refreshAgain && !Task.isCancelled
            }
            catch is CancellationError { }
            catch { self.error = ReaderMessages.error(error) }
        }
        refreshWork = work
        await work.value
        refreshWork = nil; nativeRefreshing = false; explicitRefresh = false
        if let request { refreshing.finish(request) }
    }
    func scheduleRefresh() {
        refreshAgain = true
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250)); try Task.checkCancellation()
                refreshTask = nil
                await refresh()
            }
            catch { }
        }
    }
    func reloadBooks() async {
        do { revision += 1; try await reload() }
        catch is CancellationError { }
        catch { self.error = ReaderMessages.error(error) }
    }
}
