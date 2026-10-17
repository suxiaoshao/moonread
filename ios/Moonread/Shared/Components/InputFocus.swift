import SwiftUI

private struct InputRegionPreference: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private struct InputFramePreference: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value += nextValue()
    }
}

private struct OutsideInputFocus: ViewModifier {
    let focus: FocusState<Bool>.Binding
    @State private var inputFrames: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .overlayPreferenceValue(InputRegionPreference.self) { regions in
                GeometryReader { geometry in
                    Color.clear.preference(key: InputFramePreference.self, value: regions.map { geometry[$0] })
                }.allowsHitTesting(false)
            }
            .onPreferenceChange(InputFramePreference.self) { inputFrames = $0 }
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                guard focus.wrappedValue, !inputFrames.contains(where: { $0.contains(tap.location) }) else { return }
                // Only the local field gives up focus. Buttons keep their tap,
                // input selection keeps its gestures, and other sheets are untouched.
                focus.wrappedValue = false
            })
    }
}

extension View {
    /// Include the field's own accessories (such as clear) in this region.
    func keyboardInputRegion() -> some View {
        anchorPreference(key: InputRegionPreference.self, value: .bounds) { [$0] }
    }

    func dismissKeyboardOnOutsideTap(_ focus: FocusState<Bool>.Binding) -> some View {
        modifier(OutsideInputFocus(focus: focus))
    }
}
