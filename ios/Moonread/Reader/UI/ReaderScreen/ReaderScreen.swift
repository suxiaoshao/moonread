import MoonreadAI
import MoonreadCoreBindings
import MoonreadDesign
import MoonreadReader
import SwiftUI
import TipKit

/// Connect the reader to the source stack and the features that open above it.
struct ReaderScreen: View {
    let route: ReaderRoute
    var openingRequest: OpeningRequest? = nil
    let onExit: (String?, UInt64) -> Void
    @Environment(LibraryModel.self) private var library
    @Environment(AIHost.self) private var ai
    @Environment(ThemeStore.self) private var themes
    @State private var returnToReading = ReturnToReading()

    var body: some View {
        ReaderPage(route: route, openingRequest: openingRequest, service: AppDataService.shared,
                   settingsStore: .shared, host: host, onExit: onExit)
    }

    private var quickPaletteChoices: ReaderQuickPaletteChoices {
        let appearance = themes.reader.plan.appearance
        let snapshot = themes.snapshot
        let selected = appearance == .light ? snapshot.preferences.readerLight : snapshot.preferences.readerDark
        return ReaderQuickPaletteChoices(selected: selected, palettes: snapshot.palettes.filter { $0.appearance == appearance },
                                         title: paletteDisplayName) { source in
            themes.update { value in
                if appearance == .light { value.readerLight = source } else { value.readerDark = source }
            }
        }
    }

    private var host: ReaderPageHost {
        ReaderPageHost(
            source: { id in
                let location = id.flatMap { library.shell.readerDestinationLocation($0) }
                return ReaderSourceNavigation(selected: location.map { $0.tab == library.shell.selectedTab } ?? true,
                    containsReader: id.map { library.shell.containsReaderDestination($0) } ?? true, depth: location?.depth,
                    tab: String(describing: library.shell.selectedTab), routeCount: library.shell.path.count)
            },
            register: { session, id, edits in
                let router = library.systemReading
                router.register(session, navigationID: id)
                router.savingEdits = edits.saving
                router.hasUnsavedEdits = edits.unsaved
                router.hasEditor = edits.hasEditor
                router.discardEdits = edits.discard
            },
            unregister: { library.systemReading.unregister($0) },
            storageReader: { id, book, close in
                library.shell.storageReaders[id] = book.map { .init(bookID: $0, close: close) }
            },
            removeReader: { library.shell.removeReaderDestination($0) },
            pendingSystemRead: library.systemReading.pending.map(AnyHashable.init),
            details: { details, close in
                AnyView(StatisticsView(library: library, target: StatisticsRoute(target: details.target, title: details.title,
                    origin: .reader(fileID: details.fileID)))
                    .environment(\.returnToReading, returnToReading)
                    .onAppear { returnToReading.close = close })
            },
            settings: { view in
                AnyView(ReaderSettingsView(settings: view.settings, preview: view.preview, encoding: view.encoding,
                    isRestartingEncoding: view.restartingEncoding, changeEncoding: view.changeEncoding,
                    editing: view.editing, editorClosed: view.editorClosed))
            },
            quickPaletteChoices: { quickPaletteChoices },
            cover: { title, cover, sha, author in
                AnyView(BookCoverView(title: title, cover: cover, contentSHA256: sha, author: author))
            },
            listeningCover: { title, sha, author, image in
                AnyView(SystemBookCover(title: title, contentSHA256: sha, author: author, userImage: image, rendersSynchronously: true))
            },
            aiAvailable: ai.availability.isAvailable,
            aiSnapshot: { ai.runtime?.conversation($0)?.moonSnapshot },
            aiProposes: { ai.runtime?.conversation($0)?.latestTurnProposes == true },
            aiPage: { request in
                AnyView(AIEntry {
                    AIReadingConversation(context: request.context, close: request.close, selected: request.selected,
                        openingIsActive: request.openingIsActive,
                        readingSearch: .init(isOpenBook: request.isOpenBook, returnToBook: request.close))
                })
            },
            bookReference: AIReadingTools.bookRef,
            showsControlsTip: Onboarding.shared.enabled && !Onboarding.shared.revealedControls,
            showsSelectionTip: Onboarding.shared.enabled && Onboarding.shared.revealedControls && !Onboarding.shared.selectedText,
            controlsTip: { AnyView(TipView(Onboarding.shared.controls).tipViewStyle(ThemedTipStyle())) },
            selectionTip: {
                AnyView(TipView(Onboarding.shared.selection).tipViewStyle(ThemedTipStyle(titleOverride:
                    ai.availability.isAvailable ? nil : Text("长按文字可以标注、写批注或拷贝"))))
            },
            didShowControls: { Onboarding.shared.didShowControls() },
            didSelectText: { Onboarding.shared.didSelectText() },
            smokeEnabled: smokeEnabled, annotationWitness: annotationWitness,
            bodyDisplayed: { session in
                #if DEBUG
                showStoreShotListening(in: session)
                #endif
            }
        )
    }

    private var smokeEnabled: Bool {
        #if DEBUG
        ReaderSmokeFixture.enabled
        #else
        false
        #endif
    }

    private var annotationWitness: String? {
        #if DEBUG
        if StoreShotScene.requested == .annotation, let capture = StoreShotCapture.requested,
           let fixture = try? StoreShotFixture.localized(capture.language) { return fixture.notes[0][0] }
        #endif
        return nil
    }
}
