import SwiftUI

struct ReadingContinuationBanner: View {
    let message: String
    let busy: Bool
    let accept: () -> Void
    let stay: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message).font(.subheadline).foregroundStyle(Color(uiColor: theme.ink))
            HStack {
                Button("跳过去", action: accept).buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("acceptSyncedProgress")
                Button("留在这里", action: stay).buttonStyle(.bordered)
                    .accessibilityIdentifier("stayAtLocalProgress")
            }.disabled(busy).tint(Color(uiColor: theme.accent))
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 16))
            .accessibilityElement(children: .contain).accessibilityIdentifier("syncedReadingProgress")
    }
}
