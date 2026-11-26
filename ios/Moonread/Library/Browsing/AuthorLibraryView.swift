import MoonreadLibrary
import SwiftUI

struct AuthorLibraryView: View {
    @Bindable var model: LibraryModel
    let credit: AuthorCredit
    let host: LibraryBrowsingHost

    var body: some View {
        AuthorLibraryPage(credit: credit, layout: $model.layout, processingFiles: model.processingFiles,
                          results: AppSearchResults(service: model.service), statistics: model.service.statisticsDataSource(),
                          now: { StatisticsClock.now },
                          observeWorks: { await $0.observeLibrary($1, service: model.service) },
                          openFilter: { host.navigate(.search(.init(seeds: [.author(credit.name)])), in: model) },
                          openBook: { host.open($0, in: model) }) { sections in
            HostedLibraryCollection(model: model, host: host, sections: sections, accessibilityID: "authorWorks")
        }
    }
}
