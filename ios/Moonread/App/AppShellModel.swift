import MoonreadSettings
import MoonreadAI
import MoonreadLibrary
import SwiftUI

@MainActor @Observable
final class AppShellModel {
    var selectedTab = AppTab.library {
        didSet {
            if selectedTab == .search && oldValue != .search { searchOrigin = oldValue }
        }
    }
    /// Search is a quick entry: leaving it returns to the tab it was entered from.
    var searchOrigin = AppTab.library
    var libraryPath: [LibraryRoute] = []
    var statisticsPath: [LibraryRoute] = []
    var searchPath: [LibraryRoute] = []
    let settingsNavigation: SettingsNavigation
    var path: [LibraryRoute] {
        get {
            return switch selectedTab {
            case .library, .conversations: libraryPath
            case .statistics: statisticsPath
            case .settings: settingsNavigation.path
            case .search: searchPath
            }
        }
        set {
            switch selectedTab {
            case .library, .conversations: libraryPath = newValue
            case .statistics: statisticsPath = newValue
            case .settings: settingsNavigation.path = newValue
            case .search: searchPath = newValue
            }
        }
    }
    let search = AppSearch()
    var searchPresented = false
    let dataManagement: DataManagementModel
    /// A reader that closed with an error reports it here, after its position is saved.
    var readerExitError: String?
    struct StorageReader {
        let bookID: String
        let close: @MainActor () async -> Bool
    }
    var storageReaders: [UUID: StorageReader] = [:]
    var reviewCandidate: ReadingReviewCandidate?
    /// An AI quick task opened from the library; the session itself lives in AIService.
    var aiRequest: AIQuickTaskRequest?

    init(service: AppDataService) {
        settingsNavigation = SettingsNavigation(service: service)
        dataManagement = DataManagementModel(service: service)
    }

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

    func openNewSavedFilter(_ id: UUID, replacing source: UUID?) {
        if let source, path.last == .savedFilter(source) {
            path[path.count - 1] = .savedFilter(id)
        } else {
            libraryPath = [.savedFilter(id)]
            selectedTab = .library
            searchPresented = false
        }
    }

    func readerDestinationLocation(_ id: UUID) -> (tab: AppTab, depth: Int)? {
        for (tab, path) in [(AppTab.library, libraryPath), (.statistics, statisticsPath),
                            (.search, searchPath), (.settings, settingsNavigation.path)] {
            if let index = path.firstIndex(where: { $0.readerOpeningID == id }) { return (tab, index + 2) }
        }
        return nil
    }
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
}
