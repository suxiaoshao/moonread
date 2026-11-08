import SwiftUI

struct ReadingContinuationBanner: View {
    let message: String
    let busy: Bool
    let accept: () -> Void
    let stay: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: message)
                .font(.footnote).lineLimit(1)
                .foregroundStyle(Color(uiColor: theme.ink))
            HStack(spacing: 12) {
                Button("跳过去", action: accept)
                    .buttonStyle(ThemedProminentButtonStyle())
                    .accessibilityIdentifier("acceptSyncedProgress")
                Button("留在这里", action: stay)
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityIdentifier("stayAtLocalProgress")
            }
            .font(.footnote.weight(.medium)).controlSize(.small).disabled(busy)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: theme.separator), lineWidth: 0.5) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("syncedReadingProgress")
    }
}
