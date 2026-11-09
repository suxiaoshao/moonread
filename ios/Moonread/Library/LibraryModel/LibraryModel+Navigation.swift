import SwiftUI
import UniformTypeIdentifiers

extension LibraryModel {
    func updateAvailableTabs(aiAvailable: Bool) {
        func existing(_ tab: AppTab) -> AppTab {
            if tab == .conversations && !aiAvailable { return .library }
            return tab
        }
        settingsNavigation.aiAvailabilityChanged(aiAvailable)
        selectedTab = existing(selectedTab)
        searchOrigin = existing(searchOrigin)
        if !aiAvailable { dismissAIPaths() }
    }
    func dismissAIPaths() {
        func withoutAI(_ path: [LibraryRoute]) -> [LibraryRoute] {
            Array(path.prefix { if case .conversation = $0 { return false }; return true })
        }
        libraryPath = withoutAI(libraryPath); statisticsPath = withoutAI(statisticsPath); searchPath = withoutAI(searchPath)
        settingsNavigation.path = withoutAI(settingsNavigation.path)
        aiRequest = nil
    }
    func openSettings(target: SettingsTask? = nil) {
        selectedTab = .settings
        // An external entry must not replace an unsaved palette edit.
        guard !settingsNavigation.hasDraft else { return }
        if let target { settingsNavigation.select(target) }
    }
    /// The one search session, owned here so library pages can open it with a scope.
    func setSearchPresented(_ value: Bool) {
        defer { searchPresented = value }
        guard searchPresented, !value, selectedTab == .search, searchPath.isEmpty else { return }
        selectedTab = searchOrigin
    }
    func openIndexFailure(_ id: String) {
        Task {
            do { open(try await service.libraryEntry(id)) }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    func open(_ entry: LibraryEntry, expectedContentSHA: String? = nil, push: ((LibraryRoute) -> Void)? = nil, isCurrent: @escaping () -> Bool = { true }) {
        let tap = ProcessInfo.processInfo.systemUptime
        if entry.id == openingFileID { return }
        cancelOpening()
        if entry.directory { if let push { push(.folder(entry.location)) } else { path.append(.folder(entry.location)) }; return }
        let origin = path, tab = selectedTab
        let request = UUID()
        openingRequest = request
        openingOrigin = (tab, origin)
        openingFileID = entry.id
        openingSource = entry.source
        showsFileLoading = entry.needsDownload; fileProgress = nil
        openingTask = Task { [self] in
            let indicator = Task {
                try? await Task.sleep(for: LoadingTiming.inlineDelay)
                guard !Task.isCancelled, openingRequest == request else { return }
                showsFileLoading = true
            }
            defer {
                indicator.cancel()
                if openingRequest == request { openingFileID = nil; openingSource = nil; showsFileLoading = false; fileProgress = nil; openingTask = nil; openingRequest = nil }
            }
            do {
                try await prepareSource(entry.source) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.openingRequest == request, !Task.isCancelled else { return }
                        self.fileProgress = fraction
                        if fraction != nil { self.showsFileLoading = true }
                    }
                }
                try Task.checkCancellation()
                if let push {
                    guard isCurrent() else { return }
                    push(.reader(OpeningRequest(target: .source(entry.source), tap: tap, expectedContentSHA: expectedContentSHA, metadataHint: entry.metadata))); return
                }
                guard selectedTab == tab, path == origin else { return }
                path.append(.reader(OpeningRequest(target: .source(entry.source), tap: tap, expectedContentSHA: expectedContentSHA, metadataHint: entry.metadata)))
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, openingRequest == request, push == nil ? (selectedTab == tab && path == origin) : isCurrent() else { return }
                self.error = ReaderMessages.error(error)
            }
        }
    }
    func readerDestinationLocation(_ id: UUID) -> (tab: AppTab, depth: Int)? {
        for (tab, path) in [(AppTab.library, libraryPath), (.statistics, statisticsPath),
                            (.search, searchPath), (.settings, settingsNavigation.path)] {
            if let index = path.firstIndex(where: { $0.readerOpeningID == id }) { return (tab, index + 2) }
        }
        return nil
    }
    func readerDestinationDepth(_ id: UUID) -> Int? { readerDestinationLocation(id)?.depth }
    func containsReaderDestination(_ id: UUID) -> Bool { readerDestinationLocation(id) != nil }
    func removeReaderDestination(_ id: UUID) {
        func removing(_ path: [LibraryRoute]) -> [LibraryRoute] {
            guard let index = path.firstIndex(where: { route in
                route.readerOpeningID == id
            }) else { return path }
            return Array(path[..<index])
        }
        libraryPath = removing(libraryPath); statisticsPath = removing(statisticsPath)
        settingsNavigation.path = removing(settingsNavigation.path); searchPath = removing(searchPath)
    }
    func cancelOpeningForNavigationChange() {
        guard let (tab, origin) = openingOrigin, selectedTab != tab || path != origin else { return }
        cancelOpening()
    }
    func cancelOpening() {
        openingOrigin = nil
        openingTask?.cancel(); openingTask = nil
        openingFileID = nil; openingSource = nil; showsFileLoading = false; fileProgress = nil; openingRequest = nil
    }
    func cancelOpening(deleting entry: LibraryEntry) {
        guard let source = openingSource, source.shelfID == entry.shelfId else { return }
        let opened = source.relativePath.split(separator: "/")
        let deleted = entry.relativePath.split(separator: "/")
        guard opened == deleted || (entry.directory && opened.count > deleted.count && opened.starts(with: deleted)) else { return }
        cancelOpening()
    }
    func hideRecent(_ entry: LibraryEntry) async {
        guard let id = entry.readingKey else { return }
        do { try await service.hideRecent(id); try await reload() }
        catch { self.error = ReaderMessages.error(error) }
    }
}
