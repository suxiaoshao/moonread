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
        guard isCurrent() else { return }
        if entry.directory {
            if let push { push(.folder(entry.location)) } else { path.append(.folder(entry.location)) }
            return
        }
        let target = ReaderRoute.source(entry.source)
        if push == nil, case .reader(let previous) = path.last,
           case .source(let source) = previous.target, source.id == entry.id,
           previous.expectedContentSHA == expectedContentSHA { return }

        let route = LibraryRoute.reader(OpeningRequest(target: target, tap: ProcessInfo.processInfo.systemUptime,
            expectedContentSHA: expectedContentSHA, metadataHint: entry.metadata,
            coverHint: entry.bookRow?.cardMetadata.map { .init(sha: entry.readingIdentity?.formalSHA256, card: $0) }))
        if let push { push(route) }
        // A second tap queued during the push supersedes its destination,
        // rather than stacking two readers. Destinations own their own tasks.
        else if path.last?.isReader == true { path[path.count - 1] = route }
        else { path.append(route) }
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
    func hideRecent(_ entry: LibraryEntry) async {
        guard let id = entry.readingKey else { return }
        do { try await service.hideRecent(id); try await reload() }
        catch { self.error = ReaderMessages.error(error) }
    }
}
