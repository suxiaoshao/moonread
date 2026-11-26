import MoonreadReader
import MoonreadDesign
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI

struct LibraryAllBooksView: View {
    @Bindable var model: LibraryModel
    let shelfID: String
    let host: LibraryBrowsingHost

    var body: some View {
        LibraryCataloguePage(
            shelfID: shelfID, layout: $model.layout, grouping: $model.grouping,
            status: .init(scan: model.shelfScans[shelfID], refresh: model.refreshing.request,
                          processingFiles: model.processingFiles, nativeRefreshing: model.nativeRefreshing,
                          explicitRefresh: model.explicitRefresh),
            catalogue: CatalogueStore(service: .shared), shelfTitle: model.shelfTitle,
            reportError: { model.error = ReaderMessages.error($0) },
            selectTag: { host.navigate(.search(AppSearchScope(seeds: [.shelf($0), .tag($1)])), in: model) },
            refresh: { await model.refresh(showIndicator: false, userInitiated: true) }
        ) { sections, accessibilityID, onRefresh in
            HostedLibraryCollection(model: model, host: host, sections: sections, accessibilityID: accessibilityID, onRefresh: onRefresh)
        }
    }
}
