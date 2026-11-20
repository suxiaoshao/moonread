import TipKit
import SwiftUI
import UIKit

extension ReaderScreen {
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

    func aiContext(selection: TextRange? = nil) -> AIEntryContext {
        let sha = readerSession.book?.readingKey.formalSHA256
        let title = readerSession.book?.title ?? route.title
        let visible = readerSession.viewportAccess.controller?.statisticsRange()
        let start = visible?.0 ?? readerSession.anchor
        var attachments: [AIReadingAttachment] = [
            .init(kind: .position, origin: "reader", bookRef: sha.map(AIReadingTools.bookRef), title: title,
                  chapter: readerSession.chapter?.title, startUtf8: start, endUtf8: visible?.1,
                  progress: readerSession.incomplete ? nil : readerSession.book.map { Double(start) / Double(max(1, $0.byteCount)) })
        ]
        if let selection {
            attachments.append(.init(kind: .selection, origin: "reader", bookRef: sha.map(AIReadingTools.bookRef), title: title,
                                     chapter: readerSession.chapter?.title, startUtf8: selection.startUtf8, endUtf8: selection.endUtf8, excerpt: selection.text))
        }
        return AIEntryContext(association: AIContext(contentSHA: sha, title: title, chapter: readerSession.chapter?.title), attachments: attachments)
    }

    var preparationView: some View {
        ReaderPreparationContent(session: readerSession, route: route, information: coverInformation, changeEncoding: changeEncoding)
    }
    var importStatus: some View {
        ReaderPreparationContent(session: readerSession, route: route, information: coverInformation, statusOnly: true, changeEncoding: changeEncoding)
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
