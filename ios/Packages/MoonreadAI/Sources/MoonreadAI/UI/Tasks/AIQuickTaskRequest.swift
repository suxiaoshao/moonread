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
public enum AIQuickTaskDates {
    public static func iso(_ day: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = StatisticsDates.civilCalendar
        formatter.timeZone = StatisticsDates.civilCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: StatisticsDates.date(day))
    }
}

public enum AIQuickTaskAttachments {
    public static func statistics(from: String, to: String, bookSHA: String?, title: String) -> [AIReadingAttachment] {
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
