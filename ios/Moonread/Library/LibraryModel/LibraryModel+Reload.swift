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
        let localRecents = try await service.recentLibrary(UInt32(Self.homeRecentLimit), cold: !homeReady)
        let next = HomeSnapshot(shelves: localShelves, recents: localRecents)
        if !homeReady { await warmHomeCovers(next.recents) }
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
    private func warmHomeCovers(_ entries: [LibraryEntry]) async {
        // The resume card and the covers visible in the first screen of the recent row.
        homeCovers = entries.prefix(4).compactMap { $0.metadata?.cover }.map { CoverImageLoader.shared.subscribe($0, pixels: 320) }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(150))
        while homeCovers.contains(where: { $0.presentation.phase == .loading }), ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
    private func publishHome(_ next: HomeSnapshot) {
        homeIndex = next
        guard next != home else { return }
        let shelfChanged = next.shelves != home.shelves
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { home = next; if shelfChanged { revision += 1 } }
    }
    /// Called only after the reader's existing final-save contract completes.
    func reloadBook(_ route: ReaderRoute) async {
        defer { readingInputRevision &+= 1 }
        do {
            guard let entry = try await service.recentBook(route) else { return }
            var next = homeIndex
            next.recents.removeAll { $0.id == entry.id || (entry.readingKey != nil && $0.readingKey == entry.readingKey) }
            next.recents.append(entry)
            next.recents.sort { $0.lastRead == $1.lastRead ? $0.id < $1.id : $0.lastRead > $1.lastRead }
            next.recents = Array(next.recents.prefix(Self.homeRecentLimit))
            publishHome(next)
        } catch { self.error = ReaderMessages.error(error) }
    }
    func returnedToLibrary() {
        if automaticRefreshDeferred, !path.contains(where: \.isReader) { automaticRefreshDeferred = false; scheduleRefresh() }
    }
    /// One library refresh at a time. A caller arriving while one runs asks for
    /// another pass and waits for the shared work, so a pull's spinner ends with it.
    func refresh(showIndicator: Bool = false, userInitiated: Bool = false) async {
        if userInitiated { await service.scheduleRecentRestoration(retry: true) }
        guard !busy else { return }
        if !userInitiated, openingFileID != nil || path.contains(where: \.isReader) { automaticRefreshDeferred = true; return }
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
    func reloadBooks() async { do { revision += 1; try await reload() } catch { self.error = ReaderMessages.error(error) } }
}
