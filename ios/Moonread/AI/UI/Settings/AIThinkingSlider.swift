import SwiftUI

enum AIThinkingLabel {
    static func label(_ value: String) -> String {
        switch value {
        case "none": String(localized: "关闭")
        case "minimal": String(localized: "极低")
        case "low": String(localized: "低")
        case "medium": String(localized: "中")
        case "high": String(localized: "高")
        case "xhigh": String(localized: "极高")
        case "max": String(localized: "最高")
        case "ultra": String(localized: "极致")
        default: value
        }
    }
}
/// System slider handles tracking, discrete steps and accessibility.
struct AIThinkingSlider: View {
    @Environment(\.theme) private var theme
    let levels: [String]
    @Binding var selection: String
    @State private var feedbackChange = 0

    static func index(_ value: Double, count: Int) -> Int {
        max(0, min(max(0, count - 1), Int(value.rounded())))
    }

    private var value: Binding<Double> {
        Binding(get: { Double(levels.firstIndex(of: selection) ?? 0) }, set: { value in
            guard !levels.isEmpty else { return }
            let next = levels[Self.index(value, count: levels.count)]
            guard next != selection else { return }
            selection = next
            feedbackChange += 1
        })
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Slider(value: value, in: 0...Double(max(1, levels.count - 1)), step: 1) {
                    Text("思考强度")
                } tick: { SliderTick($0) }
            } else {
                Slider(value: value, in: 0...Double(max(1, levels.count - 1)), step: 1) {
                    Text("思考强度")
                }
            }
        }
        .tint(Color(uiColor: theme.accent))
        .disabled(levels.count < 2)
        .accessibilityIdentifier("aiThinkingSlider")
        .accessibilityValue(AIThinkingLabel.label(selection))
        .sensoryFeedback(.selection, trigger: feedbackChange)
        .frame(minHeight: 44)
    }
}
