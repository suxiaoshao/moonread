import SwiftUI

public struct MetadataReviewRows<Rows: RandomAccessCollection, Content: View>: View where Rows.Element: Identifiable {
    @Environment(\.theme) private var theme
    let rows: Rows
    @ViewBuilder let row: (Rows.Element) -> Content

    public init(rows: Rows, @ViewBuilder row: @escaping (Rows.Element) -> Content) { self.rows = rows; self.row = row }

    public var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { item in
                VStack(spacing: 0) {
                    row(item)
                    if item.id != rows.last?.id { ThemedDivider().padding(.leading, 16) }
                }
            }
        }.background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17)).clipShape(.rect(cornerRadius: 17))
    }
}
