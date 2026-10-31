import SwiftUI

/// All reading accessories share one presentation. Changing tools resizes this
/// sheet instead of dismissing one surface and presenting another.
struct ReaderBottomPanel<Compact: View, Footer: View, Details: View, TaskContent: View>: View {
    @Binding var expanded: Bool
    @Binding var compactHeight: CGFloat
    let canExpand: Bool
    let taskID: String?
    let closeTask: () -> Void
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let details: (_ readyForInput: Bool) -> Details
    @ViewBuilder let taskContent: () -> TaskContent
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var previousHeight: CGFloat?
    @State private var resizing = false
    @State private var presentedExpanded = false
    @State private var readyForInput = false
    @State private var measuredCompactHeight: CGFloat?
    @State private var expansionRevision = 0
    @State private var conversationDetent: PresentationDetent = .medium

    private var detents: Set<PresentationDetent> {
        if taskID == "ai" { return [.medium, .large] }
        if taskID != nil {
            // Keep the selected starting detent while expanding; removing it
            // makes UIKit snap to large instead of animating from the dock.
            return [.height(compactHeight), .large]
        }
        var values: Set<PresentationDetent> = [.height(compactHeight)]
        if canExpand { values.insert(.large) }
        if let previousHeight { values.insert(.height(previousHeight)) }
        return values
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let taskID {
                    taskContent()
                        .id(taskID)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
                } else {
                    // Clip only accessory animations. System navigation/toolbar
                    // backgrounds may draw beyond the safe-area layout proposal.
                    accessoryContent(in: geometry)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                        .clipped()
                        .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
                }
            }
            // GeometryReader reports this sheet's available safe-area proposal.
            // Fill it explicitly so asymmetric host insets cannot leave the
            // natural-height accessory anchored to the leading/top corner.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if abs(height - compactHeight) < 2 { resizing = false }
            }
        }
        .presentationSizing(.page)
        .presentationDetents(detents, selection: Binding(get: {
            taskID == "ai" ? conversationDetent : (taskID != nil || (presentedExpanded && canExpand) ? .large : .height(compactHeight))
        }, set: { value in
            if taskID == "ai" { conversationDetent = value; return }
            if taskID != nil {
                if value == .height(compactHeight) { closeTask() }
                return
            }
            // The system writes this binding when the person drags the sheet.
            // Height measurement changes do not feed back into search state.
            if canExpand, value == .large || (value == .height(compactHeight) && !resizing) {
                // Accept a dragged detent synchronously. Waiting for onChange
                // would briefly return the old detent and snap the sheet back.
                presentedExpanded = value == .large
                expanded = value == .large
            }
        }))
        .presentationBackgroundInteraction(taskID == nil ? .enabled(upThrough: .height(max(compactHeight, previousHeight ?? compactHeight))) : .disabled)
        .presentationContentInteraction(.scrolls)
        .presentationCornerRadius(32)
        .presentationBackground(Color(uiColor: theme.surface))
        .presentationDragIndicator(.visible)
        .onChange(of: expanded && canExpand && taskID == nil, initial: true) { _, value in setExpanded(value) }
        .onChange(of: taskID) { old, new in
            if new != nil { readyForInput = false }
            if new == "ai" { conversationDetent = .medium }
            // Collapsing a task should reveal the search capsule, not briefly
            // interpret the departing large height as expanded search results.
            if old != nil, new == nil, !expanded { resizing = true }
        }
        .animation(MotionTokens.accessoryResize(reduced: reduceMotion), value: taskID)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerBottomPanel")
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
                // The actions belong to the sheet's bottom edge, never to
                // the scrolling accessory whose height is being replaced.
                footer()
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { footer in
                            Color.clear.preference(key: ReaderPanelHeight.self, value: footer.size.height)
                        }
                    }
                    // Keep outgoing content behind the fixed controls.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color(uiColor: theme.surface))
                    .transaction { $0.animation = nil }
            }
            .onPreferenceChange(ReaderPanelHeight.self) { measured in
                let height = max(60, measured)
                guard taskID == nil, measured > 0 else { return }
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

/// Sum the accessory's natural height and the independently anchored footer in
/// one layout pass, so a content swap requests only one new sheet height.
private struct ReaderPanelHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}
