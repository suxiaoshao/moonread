import MoonreadAI
import MoonreadDesign
import MoonreadSearchText
import MoonreadData
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HostedLibraryCollection: View {
    let model: LibraryModel
    let host: LibraryBrowsingHost
    let sections: [LibraryCollectionSection]
    var folder: LibraryCollectionFolder?
    var matches: [String: LibraryQueryRules.SearchMatch] = [:]
    var accessibilityID: String?
    var isSearch = false
    var hasSearchDrawer = false
    var hasTopAccessory = false
    var beforeOpen: (() -> Void)?
    var onRefresh: (() async -> Void)?
    @Environment(AIHost.self) private var ai

    var body: some View {
        MoonreadLibrary.LibraryCollection(
            layout: model.layout, sections: sections, folder: folder, matches: matches, accessibilityID: accessibilityID,
            isSearch: isSearch, hasSearchDrawer: hasSearchDrawer, hasTopAccessory: hasTopAccessory, onRefresh: onRefresh,
            open: { host.open($0, in: model) }, delete: { model.deleteEntries([$0]) },
            canAcceptDrop: { model.canAcceptDrop(at: $0) }, acceptDrop: { _ = model.acceptDrop($0, at: $1) },
            coverSize: BookFileRowLayout.coverSize, textLeading: BookFileRowLayout.textLeading,
            renderFile: { entry, format, selecting, selected in
                let interaction: LibraryItemInteraction = selecting ? .selecting(selected: selected) : .browse(host, beforeOpen: beforeOpen)
                return AnyView(Group {
                    if format == .recent && format.usesGrid(model.layout) {
                        RecentBookItem(model: model, entry: entry, layout: model.layout, fullPage: true)
                    } else if format.usesGrid(model.layout) {
                        LibraryBookTile(model: model, entry: entry, showPath: format.showsPath, match: matches[entry.id], interaction: interaction)
                    } else {
                        LibraryFileRow(model: model, entry: entry, showPath: format.showsPath, recent: format == .recent,
                                       match: matches[entry.id], interaction: interaction)
                    }
                }.environment(ai))
            },
            attachEnvironment: { AnyView($0.environment(ai)) }
        )
    }
}
