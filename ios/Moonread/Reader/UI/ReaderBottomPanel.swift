import SwiftUI
import UIKit

/// All reading accessories share one presentation. Changing tools resizes this
/// sheet instead of dismissing one surface and presenting another.
struct ReaderBottomPanel<Compact: View, Footer: View, Details: View, TaskContent: View>: View {
    @Binding var expanded: Bool
    @Binding var compactHeight: CGFloat
    let canExpand: Bool
    let taskID: String?
    let closeTask: () -> Void
    let compactID: ReaderDock
    @ViewBuilder let compact: (ReaderDock, Bool) -> Compact
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
    @State private var swap = ReaderCompactSwap()
    @State private var panelGeometry = ReaderPanelGeometry()
    @State private var compactFrame = CGRect.zero
    @State private var footerFrame = CGRect.zero
    @State private var measuredParts = ReaderPanelMeasurement()
    @State private var startingGeometryHeight: CGFloat = 0
    @State private var startingDetentHeight: CGFloat = 0
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
            .onGeometryChange(for: ReaderPanelGeometry.self) {
                ReaderPanelGeometry(size: $0.size, frame: $0.frame(in: .global))
            } action: { value in
                if swap.sequencing, panelGeometry.size.width > 0,
                   abs(value.size.width - panelGeometry.size.width) > 1 {
                    swap.reset(to: compactID)
                }
                panelGeometry = value
                if abs(value.size.height - compactHeight) < 2 { resizing = false }
            }
        }
        .onChange(of: compactID, initial: true) { _, next in
            if !swap.sequencing {
                startingGeometryHeight = panelGeometry.size.height
                startingDetentHeight = compactHeight
            }
            if swap.request(next, compact: !expanded && !presentedExpanded && taskID == nil) {
                let revision = swap.generation
                withAnimation(MotionTokens.accessoryRemoval, completionCriteria: .removed) {
                    swap.opacity = 0
                } completion: {
                    var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                    withTransaction(transaction) { swap.didFadeOut(revision) }
                }
            }
        }
        .onChange(of: expanded || taskID != nil) { _, active in
            if active { swap.reset(to: compactID) }
        }
        .onDisappear { swap.reset(to: compactID) }
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
                compact(swap.displayed ?? compactID, swap.sequencing)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        ReaderCompactPresentationProbe(generation: swap.phase == .resizing ? swap.generation : nil) { revision in
                            guard revision == swap.generation else { return }
                            revealCompactIfReady()
                        }
                    }
                    .opacity(swap.opacity)
                    .allowsHitTesting(!swap.sequencing)
                    .accessibilityHidden(swap.sequencing)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        compactFrame = frame
                    }
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ReaderPanelHeight.self,
                                value: ReaderPanelMeasurement(compact: content.size.height,
                                    generation: swap.generation, dock: swap.displayed ?? compactID))
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The actions belong to the sheet's bottom edge, never to
                // the scrolling accessory whose height is being replaced.
                footer()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        footerFrame = frame
                    }
                    .background {
                        GeometryReader { footer in
                            Color.clear.preference(key: ReaderPanelHeight.self, value: ReaderPanelMeasurement(footer: footer.size.height))
                        }
                    }
                    // Keep outgoing content behind the fixed controls.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color(uiColor: theme.surface))
                    .transaction { $0.animation = nil }
            }
            .onPreferenceChange(ReaderPanelHeight.self) { measured in
                let height = max(60, measured.compact + measured.footer)
                guard taskID == nil, measured.compact + measured.footer > 0 else { return }
                if swap.sequencing {
                    guard measured.generation == swap.generation, measured.dock == swap.displayed else { return }
                    measuredParts = measured
                    guard swap.measured(height: height, generation: measured.generation) else { return }
                    measuredCompactHeight = height
                    resizeCompact(to: height, generation: swap.generation)
                } else {
                    measuredCompactHeight = height
                    // Preserve the existing expansion and ordinary compact transitions.
                    guard !expanded, !presentedExpanded, abs(height - compactHeight) > 1 else { return }
                    resizeCompact(to: height)
                }
            }
            .opacity(1 - fraction).allowsHitTesting(fraction < 0.2)
            .accessibilityHidden(fraction >= 0.2)
        }
    }

    private func resizeCompact(to height: CGFloat, generation: UInt64? = nil) {
        if abs(height - compactHeight) <= 1 {
            if let generation { swap.didResize(generation) }
            return
        }
        resizing = !expanded; previousHeight = compactHeight
        withAnimation(MotionTokens.accessoryResize(reduced: reduceMotion), completionCriteria: .removed) {
            compactHeight = height
        } completion: {
            guard generation == nil || generation == swap.generation else { return }
            if compactHeight == height { previousHeight = nil }
            if let generation { swap.didResize(generation) }
        }
    }

    private func revealCompactIfReady() {
        guard swap.phase == .resizing, let height = swap.targetHeight else { return }
        let panel = panelGeometry.frame
        let scale = panel.height / max(1, panelGeometry.size.height)
        // A detent completion can precede UIKit layout. Wait for the actual
        // target proposal AND the content/footer boundaries in that proposal.
        // Oversized accessories retain the existing scrolling behavior when
        // UIKit clamps the requested detent to the available window height.
        let proposalReady = ReaderCompactSwap.proposalArrived(target: height,
            actual: panelGeometry.size.height, previous: startingGeometryHeight,
            previousDetent: startingDetentHeight)
        let ready = proposalReady
            && panel.width > 0 && compactFrame.width > 0 && footerFrame.width > 0
            && abs(compactFrame.width - panel.width) < 1 && abs(footerFrame.width - panel.width) < 1
            && abs(compactFrame.minX - panel.minX) < 1 && abs(footerFrame.minX - panel.minX) < 1
            && abs(compactFrame.minY - panel.minY) < 1
            && compactFrame.maxY >= footerFrame.minY - 1
            && abs(footerFrame.maxY - panel.maxY) < 1
            && abs(compactFrame.height - measuredParts.compact * scale) < 1
            && abs(footerFrame.height - measuredParts.footer * scale) < 1
        guard swap.beginFadeIn(geometryReady: ready) else { return }
        let generation = swap.generation
        withAnimation(MotionTokens.accessoryInsertion(reduced: reduceMotion), completionCriteria: .removed) {
            swap.opacity = 1
        } completion: { swap.didFadeIn(generation) }
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

private struct ReaderPanelGeometry: Equatable {
    var size = CGSize.zero
    var frame = CGRect.zero
}

/// One compact subtree plus the independently anchored footer. The tag rejects
/// a departing subtree's measurement during an ordered More handoff.
private struct ReaderPanelMeasurement: Equatable {
    var compact: CGFloat = 0
    var footer: CGFloat = 0
    var generation: UInt64 = 0
    var dock: ReaderDock?
}
private struct ReaderPanelHeight: PreferenceKey {
    static let defaultValue = ReaderPanelMeasurement()
    static func reduce(value: inout ReaderPanelMeasurement, nextValue: () -> ReaderPanelMeasurement) {
        let next = nextValue()
        value.compact += next.compact; value.footer += next.footer
        if let dock = next.dock { value.dock = dock; value.generation = next.generation }
    }
}

/// Rendering-only handoff. Selection/exposure remain owned by the reader's
/// presentation state; this never queues navigation or creates another sheet.
@MainActor @Observable final class ReaderCompactSwap {
    enum Phase { case idle, fadingOut, measuring, resizing, fadingIn }
    private(set) var displayed: ReaderDock?
    private(set) var target: ReaderDock = .progress
    private(set) var phase = Phase.idle
    private(set) var generation: UInt64 = 0
    private(set) var targetHeight: CGFloat?
    private var resized = false
    var opacity: Double = 1
    var sequencing: Bool { phase != .idle }

    /// Retarget a hidden swap immediately; while fading out the completion
    /// installs the latest target, rather than replaying intermediate choices.
    func request(_ next: ReaderDock, compact: Bool) -> Bool {
        target = next
        guard let displayed else { self.displayed = next; return false }
        guard compact, sequencing || displayed == .more || next == .more else {
            reset(to: next); return false
        }
        if phase == .fadingOut { return false }
        generation &+= 1; targetHeight = nil; resized = false
        if phase == .measuring || phase == .resizing {
            self.displayed = next; phase = .measuring
            return false
        }
        phase = .fadingOut
        return true
    }
    func didFadeOut(_ revision: UInt64) {
        guard generation == revision, phase == .fadingOut else { return }
        generation &+= 1; displayed = target; phase = .measuring
    }
    func measured(height: CGFloat, generation revision: UInt64) -> Bool {
        guard revision == generation, phase == .measuring else { return false }
        targetHeight = height; phase = .resizing; resized = false
        return true
    }
    func didResize(_ revision: UInt64) {
        guard revision == generation, phase == .resizing else { return }
        resized = true
    }
    func beginFadeIn(geometryReady: Bool) -> Bool {
        guard phase == .resizing, resized, geometryReady else { return false }
        phase = .fadingIn
        return true
    }
    static func proposalArrived(target: CGFloat, actual: CGFloat, previous: CGFloat, previousDetent: CGFloat) -> Bool {
        if abs(actual - target) < 2 { return true }
        // A smaller proposal is final only after native presentation has
        // settled AND it changed, or the previous accessory was already clipped.
        return actual > 0 && actual < target
            && (abs(actual - previous) > 1 || previousDetent > previous + 2)
    }
    func didFadeIn(_ revision: UInt64) {
        guard revision == generation, phase == .fadingIn else { return }
        phase = .idle
    }
    func reset(to next: ReaderDock) {
        generation &+= 1; displayed = next; target = next
        phase = .idle; opacity = 1; targetHeight = nil; resized = false
    }
}

/// SwiftUI geometry reports target layout before the sheet's UIKit animation
/// finishes. Sample only during a More handoff; do not reveal until the native
/// ancestor layers have actually reached that layout on consecutive frames.
private struct ReaderCompactPresentationProbe: UIViewRepresentable {
    let generation: UInt64?
    let ready: (UInt64) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.ready = ready
        guard coordinator.generation != generation else { return }
        coordinator.stop(); coordinator.generation = generation
        guard generation != nil else { return }
        let link = CADisplayLink(target: coordinator, selector: #selector(Coordinator.frame))
        coordinator.link = link; link.add(to: .main, forMode: .common)
    }
    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator: NSObject {
        weak var view: UIView?
        var link: CADisplayLink?
        var generation: UInt64?
        var ready: (UInt64) -> Void = { _ in }
        private var stableFrames = 0
        func stop() { link?.invalidate(); link = nil; stableFrames = 0 }
        @objc func frame() {
            guard let generation, let view, view.window != nil else { stableFrames = 0; return }
            var layer: CALayer? = view.layer
            while let current = layer {
                if let presented = current.presentation(), !Self.aligned(current, presented) {
                    stableFrames = 0; return
                }
                layer = current.superlayer
            }
            stableFrames += 1
            if stableFrames >= 2 { ready(generation) }
        }
        private static func aligned(_ target: CALayer, _ actual: CALayer) -> Bool {
            let targetTransform = target.transform, actualTransform = actual.transform
            let a = [targetTransform.m11,targetTransform.m12,targetTransform.m13,targetTransform.m14,
                     targetTransform.m21,targetTransform.m22,targetTransform.m23,targetTransform.m24,
                     targetTransform.m31,targetTransform.m32,targetTransform.m33,targetTransform.m34,
                     targetTransform.m41,targetTransform.m42,targetTransform.m43,targetTransform.m44]
            let b = [actualTransform.m11,actualTransform.m12,actualTransform.m13,actualTransform.m14,
                     actualTransform.m21,actualTransform.m22,actualTransform.m23,actualTransform.m24,
                     actualTransform.m31,actualTransform.m32,actualTransform.m33,actualTransform.m34,
                     actualTransform.m41,actualTransform.m42,actualTransform.m43,actualTransform.m44]
            return abs(target.position.x - actual.position.x) < 0.25
                && abs(target.position.y - actual.position.y) < 0.25
                && abs(target.bounds.minX - actual.bounds.minX) < 0.25
                && abs(target.bounds.minY - actual.bounds.minY) < 0.25
                && abs(target.bounds.width - actual.bounds.width) < 0.25
                && abs(target.bounds.height - actual.bounds.height) < 0.25
                && zip(a,b).allSatisfy { abs($0 - $1) < 0.0001 }
        }
    }
}
