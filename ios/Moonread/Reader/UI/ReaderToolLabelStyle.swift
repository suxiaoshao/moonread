import SwiftUI
import UIKit

/// The content above the reader's anchored tools: progress (or search/browse), quick settings, or 更多.
enum ReaderDock {
    case progress, settings, more
    mutating func toggle(_ destination: Self) { self = self == destination ? .progress : destination }
}

struct ReaderToolLabelStyle: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var iconSize = 22.0
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon.font(.system(size: iconSize)).frame(width: iconSize + 4, height: iconSize + 4)
            configuration.title.font(.caption).lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
