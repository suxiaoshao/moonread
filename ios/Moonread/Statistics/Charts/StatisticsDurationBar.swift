import SwiftUI
import Charts

/// A bar without a track whose written value follows its end.
struct StatisticsDurationBar<Value: View>: View {
    let fraction: Double
    let color: Color
    @ViewBuilder let value: () -> Value
    var body: some View {
        BarWithValueLayout(fraction: min(1, max(0, fraction))) {
            Capsule().fill(color).frame(height: 5).accessibilityHidden(true)
            value()
        }
    }
}
private struct BarWithValueLayout: Layout {
    let fraction: Double
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let label = subviews[1].sizeThatFits(.unspecified)
        return CGSize(width: proposal.width ?? label.width * 3, height: max(label.height, 5))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let label = subviews[1].sizeThatFits(.unspecified)
        let barWidth = max(3, (bounds.width - label.width - spacing) * fraction)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: barWidth, height: 5))
        subviews[1].place(at: CGPoint(x: bounds.minX + barWidth + spacing, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(label))
    }
}
