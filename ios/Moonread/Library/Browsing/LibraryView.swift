import MoonreadDesign
import MoonreadLibrary
import MoonreadDataTypes
import TipKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @State private var recentUse: RecentReadingUse?
    @Environment(ThemeStore.self) private var themes
    @Environment(\.theme) private var theme

    var body: some View {
        LibraryHomePage(
            homeSections: $model.homeSections, layout: model.layout, recents: model.recents,
            recentFailure: model.recentReading.failure, hasSavedFilters: !model.savedFilters.entries.isEmpty,
            ready: model.homeReady, error: model.error, processingFiles: model.processingFiles,
            hasShelves: !model.shelves.isEmpty, loading: loading, immediate: model.explicitRefresh,
            detent: homeEditorDetent, recentRoute: LibraryRoute.recent,
            load: {
                if recentUse == nil { recentUse = model.recentReading.use(limit: RecentReadingStore.homeLimit) }
                await model.load()
            }, refresh: { await model.refresh(showIndicator: false, userInitiated: true) },
            retryRecent: { model.recentReading.retry() },
            importNovels: { model.chooseFiles(.novels(LibraryLocation(shelfID: "builtin"))) },
            addShelf: { model.chooseFiles(.folder(nil)) }
        ) { entry in
            ContinueReadingRow(entry: entry, open: { model.openRecent(entry) }) {
                BookCoverView(title: entry.title, compact: true, cover: entry.displayMetadata?.cover,
                              contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.displayMetadata?.author)
                    .frame(width: 60, height: 84)
                    .overlay { LibraryFileAvailability(entry: entry, compact: true) }
            }
            .contextMenu { RecentBookActions(model: model, entry: entry) }
            .accessibilityActions { RecentBookActions(model: model, entry: entry) }
        } recovery: {
            ShelfRecoverySummary(model: model)
        } shelves: {
            shelves
        } saved: {
            SavedFilterSection(model: model, onHome: true)
        } recent: { entry, layout in
            RecentBookItem(model: model, entry: entry, layout: layout)
        } tip: {
            if model.showsImportTip, themes.loaded, model.shell.libraryPath.isEmpty, model.shell.selectedTab == .library {
                TipView(Onboarding.shared.imports).tipViewStyle(ThemedTipStyle()).padding(.horizontal)
                    .accessibilityIdentifier("libraryImportTip")
            }
        } debugToolbar: {
            #if DEBUG
            if ReaderSmokeFixture.enabled {
                Menu("测试接收") {
                    Button("导入TXT") { Task { await model.receiveSmokeTXT(shared: false) } }.accessibilityIdentifier("smokeImportTXT")
                    Button("分享TXT") { Task { await model.receiveSmokeTXT(shared: true) } }.accessibilityIdentifier("smokeShareTXT")
                }.accessibilityIdentifier("smokeReceive")
            }
            #endif
        }
    }

    private var loading: UUID? {
        guard themes.loaded, !model.busy, !model.nativeRefreshing else { return nil }
        return model.homeReady ? (model.explicitRefresh ? model.refreshing.request : nil) : model.loading.request
    }

    private var homeEditorDetent: PresentationDetent {
        #if DEBUG
        if let capture = StoreShotCapture.requested,
           capture.scene == StoreShotScene.homeEditor.rawValue, capture.group.hasPrefix("duo-") { return .large }
        #endif
        return .medium
    }

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.shelves, id: \.id) { shelf in
                NavigationLink(value: LibraryRoute.folder(LibraryLocation(shelfID: shelf.id))) {
                    HStack {
                        ShelfRow(shelf: shelf)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 18))
                        .contentShape(.rect)
                }.buttonStyle(.plain)
                    .contextMenu { ShelfMenu(model: model, shelf: shelf) }.accessibilityIdentifier("shelf-\(shelf.id)")
                    .modifier(LibraryShelfDropTarget(model: model, shelf: shelf))
                ShelfIndexGuidance(model: model, shelfID: shelf.id)
            }
        }
    }
}
