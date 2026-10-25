import AppIntents
import Foundation

struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "继续阅读"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let message: String
        do {
            guard let recent = try await AppDataService.shared.recentLibrary(1).first else {
                try SystemReadingIntentDelivery.submit(.resume)
                return .result(dialog: "\(SystemReadingRouteError.noRecent.errorDescription!)")
            }
            let title: String
            if let id = try recent.systemReadingIdentity { title = try await AppDataService.shared.resolveSystemReadingBook(id).title }
            else { title = recent.title }
            message = String(localized: "正在打开《\(title)》。")
        } catch { message = ReaderMessages.error(error) }
        try SystemReadingIntentDelivery.submit(.resume)
        return .result(dialog: "\(message)")
    }
}

enum SystemStatisticsPeriod: String, AppEnum {
    case today, week
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "统计时段")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [.today: "今天", .week: "本周"]
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Int64> {
        StatisticsDates.systemReadingBounds(week: self == .week, now: now, calendar: calendar)
    }
}
struct ReadingStatisticsIntent: AppIntent {
    static let title: LocalizedStringResource = "查看阅读统计"
    @Parameter(title: "时段", default: .today) var period: SystemStatisticsPeriod
    static var parameterSummary: some ParameterSummary { Summary("查看 \(\.$period) 的阅读统计") }
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let service = AppDataService.shared
        // A partially understood projection must never be reported as zero reading.
        if let message = try await service.statisticsCompatibilityNotice() { throw SystemStatisticsError(message: message) }
        let bounds = period.bounds()
        let overview = try await service.statistics(first: bounds.lowerBound, last: bounds.upperBound)
        let duration = StatisticsDates.duration(overview.totalDurationMs)
        let answer = period == .today
            ? String(localized: "今天读了 \(duration)。", table: "SystemReading")
            : String(localized: "本周读了 \(duration)。", table: "SystemReading")
        return .result(value: answer, dialog: "\(answer)")
    }
}
private struct SystemStatisticsError: LocalizedError { let message: String; var errorDescription: String? { message } }

struct MoonreadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ContinueReadingIntent(), phrases: ["用\(.applicationName)继续阅读"], shortTitle: "继续阅读", systemImageName: "book")
        AppShortcut(intent: OpenSystemBookIntent(), phrases: ["用\(.applicationName)打开\(\.$target)"], shortTitle: "打开书籍", systemImageName: "books.vertical")
        AppShortcut(intent: ReadingStatisticsIntent(), phrases: ["查看\(.applicationName)阅读统计"], shortTitle: "阅读统计", systemImageName: "chart.bar.xaxis")
    }
}

extension SystemReadingRouter {
    func receiveIntent() {
        guard let request = SystemReadingIntentDelivery.take() else { return }
        do {
            switch request {
            case .resume: submit(.continueReading)
            case .statistics: submit(.showStatistics)
            case .book(let id): submit(.openBook(try SystemReadingBookID(rawValue: id)))
            }
        } catch { /* Malformed entity IDs never become paths or file imports. */ }
    }
}
