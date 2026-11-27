import MoonreadDesign
import MoonreadLibrary
import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadStatistics
import MoonreadAI
import SwiftUI

/// App host wrapper for task conversations, whose navigation remains in the app.
struct AIQuickTaskSheet: View {
    let request: AIQuickTaskRequest

    var body: some View {
        AIQuickTaskSheetContent(request: request) { id, object in
            AIChatView(conversationID: id, placement: .sheet, taskObject: object)
        }
    }
}

extension AIQuickTaskRequest {
    /// Library files: one file keeps the book origin shared with its detail page;
    /// several selected files form one task over exactly that selection.
    static func library(_ entries: [LibraryEntry], family: Family) -> AIQuickTaskRequest {
        let files = entries.filter { !$0.directory }
        let refs = files.map { AIReadingTools.ref("f", $0.id) }
        let attachments = zip(files, refs).map { entry, ref in
            AIReadingAttachment(kind: .book, origin: "library", fileRef: ref, title: entry.title)
        }
        if files.count == 1, family == .metadata, let entry = files.first {
            return AIQuickTaskRequest(family: family, origin: AITaskOrigin(bookSHA: nil, fileRef: refs[0]),
                                      object: AITaskObject(title: entry.title, cover: entry.displayMetadata?.cover, contentSHA256: entry.readingIdentity?.formalSHA256, author: entry.displayMetadata?.author), attachments: attachments)
        }
        var selection = AIReadingAttachment(kind: .files, origin: "library", title: String(localized: "已选 \(files.count) 项"))
        selection.fileRefs = refs
        return AIQuickTaskRequest(family: family, origin: AITaskOrigin(fileRefs: Set(refs)),
                                  object: AITaskObject(title: selection.title, symbol: "books.vertical"),
                                  attachments: family == .organization ? [selection] : attachments)
    }
}

extension AIQuickTaskRequest {
    /// Captures the current period and optional book at sheet opening. A book page
    /// cannot silently fall back to an all-books attachment before its identity is ready.
    @MainActor static func statistics(window: StatisticsWindow, target: StatisticsRoute?, information: BookInformationModel) -> AIQuickTaskRequest? {
        let sha = target.flatMap { information.contentSHA(for: $0.informationTarget) }
        guard target == nil || sha != nil else { return nil }
        let bounds = window.bounds(today: StatisticsDates.day(StatisticsClock.now))
        let from = AIQuickTaskDates.iso(bounds.lowerBound), to = AIQuickTaskDates.iso(bounds.upperBound)
        let range = "\(StatisticsDates.dateLabel(bounds.lowerBound, full: true)) – \(StatisticsDates.dateLabel(bounds.upperBound, full: true))"
        return AIQuickTaskRequest(family: .statistics, origin: AITaskOrigin(from: from, to: to, bookSHA: sha),
                                  object: AITaskObject(title: target?.title ?? String(localized: "阅读统计"), subtitle: range, symbol: "chart.bar"),
                                  attachments: AIQuickTaskAttachments.statistics(from: from, to: to, bookSHA: sha, title: range))
    }
    /// A folder or shelf root, referenced the same way the reading tools resolve it.
    static func folder(_ location: LibraryLocation, title: String) -> AIQuickTaskRequest {
        let scopeRef = AIReadingTools.scopeRef(shelfID: location.shelfID, path: location.path)
        var scope = AIReadingAttachment(kind: .folder, origin: "library", title: title)
        scope.scopeRef = scopeRef
        return AIQuickTaskRequest(family: .organization, origin: AITaskOrigin(scopeRef: scopeRef),
                                  object: AITaskObject(title: title, symbol: "folder"), attachments: [scope])
    }
}
