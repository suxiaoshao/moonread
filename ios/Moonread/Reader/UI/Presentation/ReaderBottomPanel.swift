import SwiftUI
import UIKit

/// The compact content and its fixed footer share one render and native sheet
/// transition. Only the content above the four tools needs measurement.
struct ReaderBottomPanel<Compact: View, Footer: View, Details: View, TaskContent: View>: View {
    @Binding var expanded: Bool
    @Binding var compactHeight: CGFloat
    let canExpand: Bool
    let input: ReaderInputAdmission
    let dismissing: Bool
    let taskID: String?
    let scope: ReaderNativeToolScope
    let token: ReaderHostToken?
    let confirm: (ReaderHostToken) -> Void
    let footerHeight: CGFloat
    let closeTask: () -> Void
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let details: (_ readyForInput: Bool) -> Details
    @ViewBuilder let taskContent: () -> TaskContent
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var nativeSheet = ReaderSheetReference()
    @State private var phase = PanelLayoutPhase.compact(.init())

    private var wantsExpanded: Bool { canExpand && expanded && taskID == nil }
    private var compactVisible: Bool { taskID == nil && !wantsExpanded }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                if let taskID {
                    taskContent()
                        .id(taskID)
                        .allowsHitTesting(input.enabled)
                        .accessibilityHidden(!input.enabled)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
                } else {
                    accessoryContent(in: geometry)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                        .transition(.identity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .overlay(ReaderSheetConfiguration(reference: nativeSheet, height: compactHeight, canExpand: canExpand,
            dismissing: dismissing, expanded: wantsExpanded, taskID: taskID, scope: scope, token: token, confirm: confirm) { large in
                guard input.enabled else { return }
                if taskID != nil { if !large { closeTask() }; return }
                if canExpand, expanded != large { expanded = large }
            }.allowsHitTesting(false).accessibilityHidden(true))
        .presentationBackground(Color(uiColor: theme.surface))
        .onPreferenceChange(ReaderPanelSize.self, perform: updateMeasurement)
        .onChange(of: wantsExpanded, initial: true) { _, expanded in setExpanded(expanded) }
        .animation(MotionTokens.accessoryResize(reduced: reduceMotion), value: taskID)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerBottomPanel")
    }

    private func accessoryContent(in geometry: GeometryProxy) -> some View {
        ZStack(alignment: .top) {
            if canExpand && (wantsExpanded || phase.retainsDetails) {
                details(phase.focusReady && input.enabled)
                    .frame(width: geometry.size.width, height: max(240, geometry.size.height), alignment: .top)
                    .opacity(wantsExpanded ? 1 : 0)
                    .allowsHitTesting(wantsExpanded && input.enabled)
                    .accessibilityHidden(!wantsExpanded || !input.enabled)
            }
            ScrollView {
                compact()
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(key: ReaderPanelSize.self,
                                value: .init(content: content.size.height, footer: footerHeight))
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize).scrollIndicators(.hidden)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer()
                    .frame(maxWidth: .infinity).frame(height: footerHeight)
                    .background(Color(uiColor: theme.surface))
            }
            .opacity(compactVisible ? 1 : 0)
            .animation(nil, value: compactVisible)
            .allowsHitTesting(compactVisible && input.enabled)
            .accessibilityHidden(!compactVisible || !input.enabled)
            .clipped()
        }
    }

    private func updateMeasurement(_ measurement: PanelMeasurement) {
        guard !dismissing, taskID == nil, measurement.content + measurement.footer > 0 else { return }
        phase = phase.measured(measurement)
        guard !wantsExpanded, abs(measurement.detent - compactHeight) > 1 else { return }
        if let controller = nativeSheet.controller {
            controller.resize(to: measurement.detent) { compactHeight = measurement.detent }
        } else { compactHeight = measurement.detent }
    }

    private func setExpanded(_ expanded: Bool) {
        let transition = UUID()
        withAnimation(MotionTokens.panel(reduced: reduceMotion), completionCriteria: .removed) {
            let measurement = phase.measurement
            if !expanded, measurement.content + footerHeight > 0 {
                compactHeight = PanelMeasurement(content: measurement.content, footer: footerHeight).detent
            }
            phase = expanded ? .expanding(measurement, transition) : .collapsing(measurement, transition)
        } completion: {
            guard phase.transition == transition else { return }
            phase = expanded ? .expanded(phase.measurement) : .compact(phase.measurement)
        }
    }
}

private struct PanelMeasurement: Equatable {
    var content: CGFloat = 0
    var footer: CGFloat = 0
    var detent: CGFloat { max(60, content + footer) }
}

private enum PanelLayoutPhase {
    case compact(PanelMeasurement), expanding(PanelMeasurement, UUID), expanded(PanelMeasurement), collapsing(PanelMeasurement, UUID)

    var measurement: PanelMeasurement {
        switch self {
        case .compact(let size), .expanded(let size), .expanding(let size, _), .collapsing(let size, _): size
        }
    }
    var transition: UUID? {
        switch self {
        case .expanding(_, let id), .collapsing(_, let id): id
        default: nil
        }
    }
    var focusReady: Bool { if case .expanded = self { return true }; return false }
    var retainsDetails: Bool { if case .compact = self { return false }; return true }
    func measured(_ size: PanelMeasurement) -> Self {
        switch self {
        case .compact: .compact(size)
        case .expanding(_, let id): .expanding(size, id)
        case .expanded: .expanded(size)
        case .collapsing(_, let id): .collapsing(size, id)
        }
    }
}

private struct ReaderPanelSize: PreferenceKey {
    static let defaultValue = PanelMeasurement()
    static func reduce(value: inout PanelMeasurement, nextValue: () -> PanelMeasurement) {
        let next = nextValue()
        if next.content + next.footer > 0 { value = next }
    }
}

/// Only the incoming accessory supplies the next natural height. Departing
/// content is still laid out for its opacity transition, but cannot delay a
/// shrink or add a second height to the measurement.
struct ReaderCompactIdentity: LayoutValueKey {
    static let defaultValue = ReaderCompactContent.none
}
struct ReaderCompactLayout: Layout {
    let selection: ReaderCompactContent
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let target = subviews.first { $0[ReaderCompactIdentity.self] == selection }
        return target?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

private final class ReaderSheetReference {
    weak var controller: ReaderSheetConfiguration.Controller?
}

/// The existing SwiftUI sheet keeps its native presentation/dismissal. This is
/// its only detent owner: ordinary tools change a stable resolver, never a set
/// of value-identified heights. No timer or SwiftUI completion acknowledges a
/// native animation.
/// https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/invalidatedetents()
private struct ReaderSheetConfiguration: UIViewControllerRepresentable {
    let reference: ReaderSheetReference
    var height: CGFloat
    var canExpand: Bool
    var dismissing: Bool
    var expanded: Bool
    var taskID: String?
    var scope: ReaderNativeToolScope
    var token: ReaderHostToken?
    var confirm: (ReaderHostToken) -> Void
    var selectionChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(); reference.controller = controller; return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configuration = self
        controller.configure()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController, UISheetPresentationControllerDelegate {
        private static let compactID = UISheetPresentationController.Detent.Identifier("readerCompact")
        var configuration: ReaderSheetConfiguration?
        private weak var sheet: UISheetPresentationController?
        private weak var forwardedDelegate: (any UISheetPresentationControllerDelegate)?
        private var resolverHeight: CGFloat = 220
        private var mode: Mode?
        private var requestedLarge = false
        private var applying = false
        private var confirmedID: UUID?
        private var appeared = false
        private lazy var compact = UISheetPresentationController.Detent.custom(identifier: Self.compactID) { [weak self] context in
            min(self?.resolverHeight ?? 220, context.maximumDetentValue)
        }
        private enum Mode: Equatable { case compact, expandable, task, conversation }

        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); configure() }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated); configure()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews(); configure()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); appeared = true; configure()
        }
        private func confirmInstallation() {
            guard sheet != nil, let configuration, let token = configuration.token, confirmedID != token.id else { return }
            confirmedID = token.id
            Task { @MainActor in configuration.confirm(token) }
        }

        func configure() {
            guard !applying, let configuration, !configuration.dismissing else { return }
            guard let owner = ReaderNativeLayerRegistry.presentedRoot(containing: self),
                  !owner.isBeingDismissed, let sheet = owner.sheetPresentationController else { return }
            if configuration.scope.registry.origin(for: owner) != configuration.scope.origin {
                configuration.scope.attach(owner)
            }
            applying = true
            defer { applying = false }
            if self.sheet !== sheet { detach(); self.sheet = sheet; mode = nil }
            if sheet.delegate !== self { forwardedDelegate = sheet.delegate; sheet.delegate = self }
            if appeared { confirmInstallation() }
            let next: Mode = configuration.taskID == "ai" ? .conversation
                : configuration.taskID != nil ? .task : configuration.canExpand ? .expandable : .compact
            let large = next == .task || (next == .expandable && configuration.expanded)
            let changedMode = mode != next
            let changedHeight = abs(resolverHeight - configuration.height) > 1
            let changedSelection = next != .conversation && requestedLarge != large
            guard changedMode || changedHeight || changedSelection else { return }
            let first = mode == nil
            mode = next; requestedLarge = large
            let changes = {
                self.resolverHeight = configuration.height
                if changedMode {
                    sheet.detents = next == .conversation ? [.medium(), .large()]
                        : next == .compact ? [self.compact] : [self.compact, .large()]
                    sheet.largestUndimmedDetentIdentifier = next == .compact || next == .expandable ? Self.compactID : nil
                    sheet.prefersScrollingExpandsWhenScrolledToEdge = false
                    sheet.prefersGrabberVisible = true
                    sheet.preferredCornerRadius = 32
                }
                if changedMode || changedSelection {
                    sheet.selectedDetentIdentifier = next == .conversation ? .medium : large ? .large : Self.compactID
                }
                sheet.invalidateDetents()
            }
            if first { changes() } else { sheet.animateChanges(changes) }
        }
        func resize(to height: CGFloat, alongside: () -> Void) {
            guard let sheet, mode != nil, !sheet.presentedViewController.isBeingDismissed else { alongside(); return }
            // A native invalidation can lay out this child synchronously,
            // before SwiftUI sends the updated configuration. Do not let that
            // re-enter configure() with the previous height.
            applying = true
            defer { applying = false }
            configuration?.height = height
            // Commit SwiftUI's new layout and the native resolver in the same
            // resize context, before the next representable update.
            sheet.animateChanges {
                resolverHeight = height
                alongside()
                sheet.invalidateDetents()
            }
        }
        func detach() {
            if let sheet, sheet.delegate === self { sheet.delegate = forwardedDelegate }
            sheet = nil; forwardedDelegate = nil
        }
        func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheetPresentationController: UISheetPresentationController) {
            if !applying, mode != .conversation {
                let large = sheetPresentationController.selectedDetentIdentifier == .large
                requestedLarge = large
                configuration?.selectionChanged(large)
            }
            forwardedDelegate?.sheetPresentationControllerDidChangeSelectedDetentIdentifier?(sheetPresentationController)
        }
        // SwiftUI still receives its adaptive-presentation callbacks (including
        // shouldDismiss/didDismiss); this bridge never owns the sheet binding.
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            forwardedDelegate?.responds(to: selector) == true ? forwardedDelegate : super.forwardingTarget(for: selector)
        }
    }
}
