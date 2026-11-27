import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import TipKit
import SwiftUI
import UIKit

extension ReaderPage {
    var readerContent: some View {
        Group {
            if readerSession.opening.phase == .reading, let window = readerSession.window, let settings = readerSession.settings {
                readingView(window: window, settings: settings)
            } else if readerSession.opening.phase == .titlePage || !ReaderOpenDiagnostics.deferredPage {
                preparationView
                    .background(ReaderPlaceholderWitness {
                        if let id = readerSession.opening.request?.id { readerSession.opening.placeholderDisplayed(id) }
                    })
                    .transition(.opacity)
            } else { Color(uiColor: theme.paper) }
        }
        .modifier(ReaderOpenContentFade(phase: readerSession.opening.phase, enabled: readerSession.opening.fadesContent && !reduceMotion))
    }

    func assistantContext(selection: TextRange?) -> ReaderPassageContext {
        let book = readerSession.book
        let visible = readerSession.viewportAccess.controller?.statisticsRange()
        let start = visible?.0 ?? readerSession.anchor
        let progress = readerSession.incomplete ? nil : book.map { ReadingProgress.fraction(start, of: $0.byteCount) }
        return ReaderPassageContext(contentSHA: book?.readingKey.formalSHA256, title: book?.title ?? route.title,
                                    chapter: readerSession.chapter?.title, start: start, end: visible?.1,
                                    progress: progress, selection: selection)
    }

    var preparationView: some View {
        ReaderPreparationContent(session: readerSession, route: route, information: coverInformation, changeEncoding: changeEncoding, renderCover: host.cover)
    }
    var importStatus: some View {
        ReaderPreparationContent(session: readerSession, route: route, information: coverInformation, statusOnly: true, changeEncoding: changeEncoding, renderCover: host.cover)
    }
}

struct ReaderOpenLegacyFade: ViewModifier {
    let ready: Bool
    let reduced: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if ReaderOpenDiagnostics.deferredPage { content }
        else { content.animation(.easeOut(duration: reduced ? 0.1 : 0.2), value: ready) }
    }
}

struct ReaderOpenContentFade: ViewModifier {
    let phase: ReaderOpeningPhase
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if ReaderOpenDiagnostics.deferredPage { content.animation(enabled ? .easeOut(duration: 0.2) : nil, value: phase) }
        else { content }
    }
}

struct ReaderImportDiagnosticStatus: ViewModifier {
    let complete: Bool
    func body(content: Content) -> some View {
        #if READER_OPEN_DIAGNOSTICS
        content.accessibilityValue(complete ? "import-complete" : "import-pending")
        #else
        content
        #endif
    }
}
