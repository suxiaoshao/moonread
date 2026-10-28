import SwiftUI

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
