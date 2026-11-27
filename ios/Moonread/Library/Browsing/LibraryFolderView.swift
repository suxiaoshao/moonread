import MoonreadAI
import MoonreadDesign
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import TipKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryFolderView: View {
    @Bindable var model: LibraryModel
    let location: LibraryLocation
    let host: LibraryBrowsingHost
    @Environment(AIHost.self) private var ai

    private var shelf: LibraryShelf? { model.shelves.first { $0.id == location.shelfID } }
    private var title: String { location.path.isEmpty ? model.shelfTitle(location.shelfID) : URL(fileURLWithPath: location.path).lastPathComponent }

    var body: some View {
        LibraryFolderPage(
            location: location, layout: $model.layout,
            status: .init(shelf: shelf, title: title, canWrite: model.canAcceptFileWork, aiAvailable: ai.availability.isAvailable,
                          discoveryGeneration: model.discoveryGeneration, discoveryRevision: model.discoveryRevision,
                          adoptedDiscoveryRevision: model.adoptedDiscoveryRevision, discoveryUnavailable: model.builtinDiscovery == .unavailable,
                          scan: model.shelfScans[location.shelfID], refresh: model.refreshing.request,
                          processingFiles: model.processingFiles, nativeRefreshing: model.nativeRefreshing,
                          explicitRefresh: model.explicitRefresh),
            actions: .init(menu: menu, selection: selection, copy: { entries, copied in
                model.runBatch(entries.map { .copy($0) }) { command in
                    if case let .copy(entry) = command { copied(entry.id) }
                }
            }, didLoad: { model.builtinDirectoryLoaded(generation: $0, snapshotRevision: $1) },
               didFail: { error, generation in
                   if let generation { model.failCloudDiscovery(generation) }
                   model.error = ReaderMessages.error(error)
               },
               refresh: { await model.refresh(showIndicator: false) }),
            folder: FolderStore(service: .shared)
        ) { sections, folder, refresh in
            HostedLibraryCollection(model: model, host: host, sections: sections, folder: folder, onRefresh: refresh)
        } overview: {
            FolderOverview(model: model, host: host, location: location, shelf: shelf)
        } emptyFolder: {
            LibraryEmptyFolder(model: model, location: location)
        } metadataExport: {
            MetadataExportView(task: MetadataExchangeModel.shared.exportTask, shelfID: location.shelfID,
                               shelfName: model.shelfTitle(location.shelfID),
                               loadShelves: { try await AppDataService.shared.shelves() })
                .metadataCoverPresentation().presentationSizing(.page)
        }
    }

    private func menu(_ action: LibraryFolderMenuAction) {
        switch action {
        case .index: Task { await model.openShelfIndex(location.shelfID) }
        case .create: model.sheet = .create(location)
        case .receive: model.chooseFiles(.novels(location))
        case .organizeFolder: model.shell.aiRequest = .folder(location, title: title)
        case .catalogue: host.navigate(.allBooks(location.shelfID), in: model)
        case .search: host.navigate(.search(AppSearchScope(seeds: [.shelf(location.shelfID)])), in: model)
        }
    }

    private func selection(_ action: LibraryFolderSelectionAction, _ entries: [LibraryEntry]) {
        switch action {
        case .share: model.export(entries, sharing: true)
        case .export: model.export(entries, sharing: false)
        case .move: model.sheet = .move(entries)
        case .metadata: model.shell.aiRequest = .library(entries, family: .metadata)
        case .organize: model.shell.aiRequest = .library(entries, family: .organization)
        case .delete: model.deleteEntries(entries)
        }
    }
}

private struct FolderOverview: View {
    let model: LibraryModel
    let host: LibraryBrowsingHost
    let location: LibraryLocation
    let shelf: LibraryShelf?
    @Environment(\.theme) private var theme

    var body: some View {
        LibraryFolderOverview(
            isRoot: location.path.isEmpty, bookCount: shelf?.bookCount ?? 0, error: shelf?.error,
            accent: Color(uiColor: theme.accent), secondary: Color(uiColor: theme.secondary),
            reconnect: { model.chooseFiles(.folder(location.shelfID)) },
            showAll: { host.navigate(.allBooks(location.shelfID), in: model) }
        ) {
            ShelfIndexGuidance(model: model, shelfID: location.shelfID)
        }
    }
}
