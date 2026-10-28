import SwiftUI

/// Natural-height search/accessory content inside the opening’s one root flow.
/// This component owns detents/focus geometry, never the foreground task.
struct ReaderBottomPanel<Compact: View, Footer: View, Details: View>: View {
    @Binding var expanded: Bool
    @Binding var compactHeight: CGFloat
    let canExpand: Bool
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let details: (_ readyForInput: Bool) -> Details
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.theme) private var theme
    @State private var previousHeight: CGFloat?
    @State private var resizing = false
    @State private var presentedExpanded = false
    @State private var readyForInput = false
    @State private var measuredCompactHeight: CGFloat?
    @State private var expansionRevision = 0

    private var detents: Set<PresentationDetent> {
        var values: Set<PresentationDetent> = [.height(compactHeight)]
        if canExpand { values.insert(.large) }
        if let previousHeight { values.insert(.height(previousHeight)) }
        return values
    }

    var body: some View {
        GeometryReader { geometry in
            accessoryContent(in: geometry)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - compactHeight) < 2 { resizing = false }
            }
            .clipped()
        }
        .presentationSizing(.page)
        .presentationDetents(detents, selection: Binding(get: {
            presentedExpanded && canExpand ? .large : .height(compactHeight)
        }, set: { value in
            // The system writes this binding when the person drags the sheet.
            // Height measurement changes do not feed back into search state.
            if canExpand, value == .large || (value == .height(compactHeight) && !resizing) {
                // Accept a dragged detent synchronously. Waiting for onChange
                // would briefly return the old detent and snap the sheet back.
                presentedExpanded = value == .large
                expanded = value == .large
            }
        }))
        .presentationBackgroundInteraction(.enabled(upThrough: .height(max(compactHeight, previousHeight ?? compactHeight))))
        .presentationContentInteraction(.scrolls)
                .presentationCornerRadius(sizeClass == .compact ? nil : 32)
        .presentationBackground(Color(uiColor: theme.surface))
        .presentationDragIndicator(.visible)
        .onChange(of: expanded && canExpand, initial: true) { _, value in setExpanded(value) }
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerAccessories")
    }

    private func accessoryContent(in geometry: GeometryProxy) -> some View {
        // Animate the first reveal in the same transaction as the detent, so
        // its completion can hand off focus. Afterwards geometry drives drags.
        let fraction = !canExpand || (resizing && !expanded) ? 0
            : presentedExpanded && !readyForInput ? 1
            : min(1, max(0, (geometry.size.height - compactHeight) / 100))
        return ZStack(alignment: .top) {
            if canExpand && (expanded || fraction > 0.01) {
                details(readyForInput)
                    .frame(width: geometry.size.width, height: max(240, geometry.size.height), alignment: .top)
                    .opacity(fraction).allowsHitTesting(fraction > 0.8)
                    .accessibilityHidden(fraction <= 0.8)
            }
            ScrollView {
                compact()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ReaderPanelHeight.self, value: content.size.height)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer().fixedSize(horizontal: false, vertical: true)
                    .background { GeometryReader { footer in Color.clear.preference(key: ReaderPanelHeight.self, value: footer.size.height) } }
                    .background(Color(uiColor: theme.surface))
            }
            .onPreferenceChange(ReaderPanelHeight.self) { measured in
                let height = max(60, measured)
                guard measured > 0 else { return }
                measuredCompactHeight = height
                // Keep the expansion's starting detent and crossfade baseline
                // fixed. The hidden capsule's new height is used on collapse.
                guard !expanded, !presentedExpanded, abs(height - compactHeight) > 1 else { return }
                resizing = !expanded; previousHeight = compactHeight
                withAnimation(MotionTokens.accessoryResize(reduced: reduceMotion), completionCriteria: .removed) {
                    compactHeight = height
                } completion: {
                    if compactHeight == height { previousHeight = nil }
                }
            }
            .opacity(1 - fraction).allowsHitTesting(fraction < 0.2)
            .accessibilityHidden(fraction >= 0.2)
        }
    }

    private func setExpanded(_ value: Bool) {
        expansionRevision += 1
        let revision = expansionRevision
        readyForInput = false
        if value { resizing = false }
        withAnimation(MotionTokens.panel(reduced: reduceMotion), completionCriteria: .removed) {
            if !value, let measuredCompactHeight {
                previousHeight = compactHeight
                compactHeight = measuredCompactHeight
            }
            presentedExpanded = value
        } completion: {
            guard expansionRevision == revision else { return }
            previousHeight = nil
            readyForInput = value && expanded
        }
    }
}

/// Measure the accessory once; commands live in the system toolbar.
private struct ReaderPanelHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
