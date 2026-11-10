import SwiftUI
import UIKit

/// All reading accessories share one presentation. Changing tools resizes this
/// sheet instead of dismissing one surface and presenting another.
struct ReaderBottomPanel<Compact: View, Footer: View, Details: View, TaskContent: View>: View {
    @Binding var expanded: Bool
    @Binding var compactHeight: CGFloat
    let canExpand: Bool
    let dismissing: Bool
    let taskID: String?
    let closeTask: () -> Void
    @ViewBuilder let compact: () -> Compact
    @ViewBuilder let footer: () -> Footer
    @ViewBuilder let details: (_ readyForInput: Bool) -> Details
    @ViewBuilder let taskContent: () -> TaskContent
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @State private var nativeSheet = ReaderSheetReference()
    @State private var footerHeight: CGFloat = 0
    @State private var availableHeight: CGFloat = 0
    @State private var resizing = false
    @State private var presentedExpanded = false
    @State private var readyForInput = false
    @State private var measuredCompactHeight: CGFloat?
    @State private var expansionRevision = 0
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
                        .transition(MotionTokens.accessoryContent(reduced: reduceMotion))
                }
            }
            // GeometryReader reports this sheet's available safe-area proposal.
            // Fill it explicitly so asymmetric host insets cannot leave the
            // natural-height accessory anchored to the leading/top corner.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                availableHeight = height
                if abs(height - compactHeight) < 2 { resizing = false }
            }
        }
        .overlay(ReaderSheetConfiguration(reference: nativeSheet, height: compactHeight, canExpand: canExpand, dismissing: dismissing,
            expanded: presentedExpanded, taskID: taskID,
            footer: AnyView(footer().frame(maxWidth: .infinity).background(Color(uiColor: theme.surface))),
            footerHeight: footerHeight, footerOpacity: taskID == nil ? 1 - expansionFraction(availableHeight) : 0) { large in
                if taskID != nil { if !large { closeTask() }; return }
                guard canExpand else { return }
                presentedExpanded = large; expanded = large
            }.accessibilityElement(children: .contain))
        .presentationBackground(Color(uiColor: theme.surface))
        .onPreferenceChange(ReaderFooterHeight.self) { value in
            if abs(value - footerHeight) > 1 { footerHeight = value }
        }
        .onChange(of: expanded && canExpand && taskID == nil, initial: true) { _, value in setExpanded(value) }
        .onChange(of: taskID) { old, new in
            if new != nil { readyForInput = false }
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
        let fraction = expansionFraction(geometry.size.height)
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
                                .preference(key: ReaderFooterHeight.self, value: footer.size.height)
                        }
                    }
                    // Keep outgoing content behind the fixed controls.
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(Color(uiColor: theme.surface))
                    // This copy only measures/reserves layout. The live footer
                    // is pinned by UIKit, so its position joins native resizing
                    // instead of jumping to SwiftUI's final bounds first.
                    .hidden().accessibilityHidden(true).allowsHitTesting(false)
            }
            .onPreferenceChange(ReaderPanelHeight.self) { measured in
                let height = max(60, measured)
                guard !dismissing, taskID == nil, measured > 0 else { return }
                measuredCompactHeight = height
                // Keep the expansion's starting detent and crossfade baseline
                // fixed. The hidden capsule's new height is used on collapse.
                guard !expanded, !presentedExpanded, abs(height - compactHeight) > 1 else { return }
                resizing = !expanded
                // UIKit owns the one stable compact detent and animates its
                // resolver change; there is no old height identifier to remove.
                if let controller = nativeSheet.controller {
                    controller.resize(to: height) { compactHeight = height }
                } else { compactHeight = height }
            }
            .opacity(1 - fraction).allowsHitTesting(fraction < 0.2)
            .accessibilityHidden(fraction >= 0.2)
            .clipped()
        }
    }

    private func expansionFraction(_ height: CGFloat) -> CGFloat {
        !canExpand || (resizing && !expanded) ? 0
            : presentedExpanded && !readyForInput ? 1
            : min(1, max(0, (height - compactHeight) / 100))
    }

    private func setExpanded(_ value: Bool) {
        expansionRevision += 1
        let revision = expansionRevision
        readyForInput = false
        if value { resizing = false }
        withAnimation(MotionTokens.panel(reduced: reduceMotion), completionCriteria: .removed) {
            if !value, let measuredCompactHeight {
                compactHeight = measuredCompactHeight
            }
            presentedExpanded = value
        } completion: {
            guard expansionRevision == revision else { return }
            readyForInput = value && expanded
        }
    }
}

private struct ReaderFooterHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    // Nonmeasuring branches contribute zero, not a replacement measurement.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Sum the accessory's natural height and the independently anchored footer in
/// one layout pass, so a content swap requests only one new sheet height.
private struct ReaderPanelHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
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
    var footer: AnyView
    var footerHeight: CGFloat
    var footerOpacity: CGFloat
    var selectionChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(); reference.controller = controller; return controller
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configuration = self
        controller.footer.view.isUserInteractionEnabled = !dismissing && footerOpacity > 0.8
        controller.footer.view.accessibilityElementsHidden = dismissing || footerOpacity <= 0.8
        controller.footer.rootView = AnyView(footer
            .themeScope(context.environment.theme)
            .environment(\.locale, context.environment.locale)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
            .environment(\.layoutDirection, context.environment.layoutDirection)
            .environment(\.moonreadReduceMotion, context.environment.moonreadReduceMotion))
        controller.configure()
    }
    // Fill the sheet's content proposal for the live UIKit controls, including
    // their hit-testing and accessibility container.
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: Controller, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController, UISheetPresentationControllerDelegate {
        private static let compactID = UISheetPresentationController.Detent.Identifier("readerCompact")
        var configuration: ReaderSheetConfiguration?
        let footer = UIHostingController(rootView: AnyView(EmptyView()))
        private var footerHeight: NSLayoutConstraint?
        private weak var sheet: UISheetPresentationController?
        private weak var forwardedDelegate: (any UISheetPresentationControllerDelegate)?
        private var resolverHeight: CGFloat = 220
        private var mode: Mode?
        private var requestedLarge = false
        private var applying = false
        private lazy var compact = UISheetPresentationController.Detent.custom(identifier: Self.compactID) { [weak self] context in
            min(self?.resolverHeight ?? 220, context.maximumDetentValue)
        }
        private enum Mode: Equatable { case compact, expandable, task, conversation }

        override func loadView() { view = FooterContainerView() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); configure() }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated); configure()
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews(); configure()
        }

        func configure() {
            guard !applying, let configuration, !configuration.dismissing else { return }
            var owner: UIViewController? = self
            while let current = owner, current.presentingViewController == nil { owner = current.parent }
            guard let owner, !owner.isBeingDismissed, let sheet = owner.sheetPresentationController else { return }
            applying = true
            defer { applying = false }
            if self.sheet !== sheet { detach(); self.sheet = sheet; mode = nil }
            if sheet.delegate !== self { forwardedDelegate = sheet.delegate; sheet.delegate = self }
            if footer.parent !== self {
                removeFooter()
                addChild(footer)
                footer.safeAreaRegions = []
                footer.view.backgroundColor = .clear
                footer.view.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(footer.view)
                let height = footer.view.heightAnchor.constraint(equalToConstant: configuration.footerHeight)
                NSLayoutConstraint.activate([
                    footer.view.leadingAnchor.constraint(equalTo: owner.view.leadingAnchor),
                    footer.view.trailingAnchor.constraint(equalTo: owner.view.trailingAnchor),
                    footer.view.bottomAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.bottomAnchor), height,
                ])
                footerHeight = height
                footer.didMove(toParent: self)
            }
            footerHeight?.constant = configuration.footerHeight
            let next: Mode = configuration.taskID == "ai" ? .conversation
                : configuration.taskID != nil ? .task : configuration.canExpand ? .expandable : .compact
            let large = next == .task || (next == .expandable && configuration.expanded)
            let changedMode = mode != next
            let changedHeight = abs(resolverHeight - configuration.height) > 1
            let changedSelection = next != .conversation && requestedLarge != large
            guard changedMode || changedHeight || changedSelection else {
                footer.view.alpha = configuration.footerOpacity
                return
            }
            let first = mode == nil
            mode = next; requestedLarge = large
            let changes = {
                self.resolverHeight = configuration.height
                self.footer.view.alpha = configuration.footerOpacity
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
        /// Keep the footer in this represented UIKit subtree, so its native
        /// buttons participate in SwiftUI's accessibility hierarchy. Only its
        /// constraints refer to the system sheet; it is not an unmanaged sibling.
        private final class FooterContainerView: UIView {
            override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
                let hit = super.hitTest(point, with: event)
                return hit === self ? nil : hit
            }
        }
        private func removeFooter() {
            guard footer.parent != nil else { return }
            footer.willMove(toParent: nil)
            footer.view.removeFromSuperview(); footer.removeFromParent()
            footerHeight = nil
        }
        func detach() {
            removeFooter()
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
