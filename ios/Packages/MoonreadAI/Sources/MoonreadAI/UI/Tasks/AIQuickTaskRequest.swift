import MoonreadCoreBindings
import Foundation
import MoonreadDataTypes
import SwiftUI

/// An AI task request assembled by the host from the selected library, reader, or statistics context.
public struct AIQuickTaskRequest: Identifiable {
    public enum Family: Hashable { case metadata, cover, organization, statistics }

    public let family: Family
    public let origin: AITaskOrigin
    public let object: AITaskObject
    public let attachments: [AIReadingAttachment]
    public var id: String { "\(family)-\(origin.hashValue)" }
    public var title: LocalizedStringKey {
        switch family { case .metadata: "完善资料"; case .cover: "封面"; case .organization: "整理"; case .statistics: "分析阅读" }
    }
    public var runningLabel: LocalizedStringKey {
        switch family { case .metadata: "正在完善"; case .cover: "正在处理封面"; case .organization: "正在整理"; case .statistics: "正在分析" }
    }

    public init(family: Family, origin: AITaskOrigin, object: AITaskObject, attachments: [AIReadingAttachment]) {
        self.family = family; self.origin = origin; self.object = object; self.attachments = attachments
    }

    @MainActor public func task(_ ai: AIService) -> AISessionSummary? {
        ai.session(origin: origin, family: family)
    }

    public static func family(_ kind: AITaskKind) -> Family {
        switch kind { case .metadata: .metadata; case .cover: .cover; case .organization: .organization; case .statistics: .statistics }
    }
}

/// Date labels for statistics-backed task origins use the app's shared civil-day rules.
enum AIQuickTaskDates {
    static func iso(_ day: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = StatisticsDates.civilCalendar
        formatter.timeZone = StatisticsDates.civilCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: StatisticsDates.date(day))
    }
}

enum AIQuickTaskAttachments {
    static func statistics(from: String, to: String, bookSHA: String?, title: String) -> [AIReadingAttachment] {
        var period = AIReadingAttachment(kind: .statistics, origin: "statistics", bookRef: bookSHA.map(AIReadingTools.bookRef), title: title)
        period.fromDate = from
        period.toDate = to
        return [period]
    }
}

public enum AIQuickTaskRemoval {
    /// States only what removal changes for this task; applied changes are never reverted.
    @MainActor public static func message(_ task: AISessionSummary) -> String {
        var parts: [String] = []
        if task.running { parts.append(String(localized: "正在进行的请求会停止。")) }
        parts.append(String(localized: "任务及其结果会删除。"))
        parts.append(String(localized: "已应用的修改会保留。"))
        return parts.joined(separator: "")
    }
}

public extension AIQuickTaskRequest {
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
    static func statistics(bounds: ClosedRange<Int64>, bookSHA: String?, bookTitle: String?) -> AIQuickTaskRequest {
        let from = AIQuickTaskDates.iso(bounds.lowerBound), to = AIQuickTaskDates.iso(bounds.upperBound)
        let range = "\(StatisticsDates.dateLabel(bounds.lowerBound, full: true)) – \(StatisticsDates.dateLabel(bounds.upperBound, full: true))"
        return AIQuickTaskRequest(family: .statistics, origin: AITaskOrigin(from: from, to: to, bookSHA: bookSHA),
                                  object: AITaskObject(title: bookTitle ?? String(localized: "阅读统计"), subtitle: range, symbol: "chart.bar"),
                                  attachments: AIQuickTaskAttachments.statistics(from: from, to: to, bookSHA: bookSHA, title: range))
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
