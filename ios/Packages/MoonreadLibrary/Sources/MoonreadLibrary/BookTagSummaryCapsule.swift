import MoonreadDesign
import SwiftUI

/// Read-only summary in the metadata form.
struct BookTagSummaryCapsule: View {
    let name: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(verbatim: name)
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .font(.subheadline)
            .foregroundStyle(Color(uiColor: theme.accent))
            .padding(.vertical, LayoutTokens.compact / 2)
            .padding(.horizontal, LayoutTokens.control)
            .background(Color(uiColor: theme.accentSurface), in: .capsule)
    }
}
