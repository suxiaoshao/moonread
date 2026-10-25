import AppIntents
import SwiftUI
import WidgetKit

@main struct MoonreadWidgets: WidgetBundle {
    var body: some Widget { ContinueReadingControl() }
}

struct ContinueReadingControl: ControlWidget {
    static let kind = "dev.moonread.Moonread.continue-reading"
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenReadingDestinationIntent(target: .resume)) {
                Label("继续阅读", systemImage: "book")
            }
        }.displayName("继续阅读").description("打开月读，接着读最近的一本书。")
    }
}
