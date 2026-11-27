import MoonreadLibrary
import MoonreadDataTypes
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
    /// Captures the current period and optional book at sheet opening. A book page
    /// cannot silently fall back to an all-books attachment before its identity is ready.
    @MainActor static func statistics(window: StatisticsWindow, target: StatisticsRoute?, information: BookInformationModel) -> AIQuickTaskRequest? {
        let sha = target.flatMap { information.contentSHA(for: $0.informationTarget) }
        guard target == nil || sha != nil else { return nil }
        let bounds = window.bounds(today: StatisticsDates.day(StatisticsClock.now))
        return .statistics(bounds: bounds, bookSHA: sha, bookTitle: target?.title)
    }
}
