import UIKit
import SwiftUI

/// A navigation cancellation and a sheet dismissal can finish in either order.
/// Keep the session intact, and only re-present after both have completed.
@Observable @MainActor
final class NavigationPresentationState {
    private enum Phase { case active, moving, restoring, departed }
    private var phase = Phase.active
    private var awaitingDismissal = false
    var isSuspended: Bool { phase != .active }

    func begin(hasPresentation: Bool) {
        guard phase == .active else { return }
        awaitingDismissal = hasPresentation
        phase = .moving
    }
    func finish(cancelled: Bool) {
        phase = cancelled ? (awaitingDismissal ? .restoring : .active) : .departed
    }
    func appear() {
        guard phase == .departed else { return }
        phase = awaitingDismissal ? .restoring : .active
    }
    /// True means navigation requested this dismissal, not the user closing a tool.
    @discardableResult
    func presentationDismissed() -> Bool {
        guard awaitingDismissal else { return false }
        awaitingDismissal = false
        if phase == .restoring { phase = .active }
        return true
    }
}

/// Observe public UIKit transition callbacks without replacing navigation or its
/// gestures. SwiftUI onDisappear is too late to start hiding a presented sheet.
struct NavigationTransitionObserver: UIViewControllerRepresentable {
    var openingID: UUID? = nil
    var expectedDepth: Int? = nil
    var appeared: (UUID, String) -> Void = { _, _ in }
    var visibilityChanged: (Bool) -> Void = { _ in }
    var willLeave: (_ popping: Bool) -> Void
    var completed: (_ popping: Bool, _ cancelled: Bool) -> Void
    var removed: () -> Void = {}
    var becameCurrent: () -> Void = {}

    func makeUIViewController(context: Context) -> Controller { Controller() }
    // Unlike a modal's disappear, dismantling ends this navigation owner's
    // identity, including removal without an animated pop or scene teardown.
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.removed()
    }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.willLeave = willLeave; controller.completed = completed
        controller.visibilityChanged = visibilityChanged
        controller.removed = removed; controller.becameCurrent = becameCurrent
        controller.expectedDepth = expectedDepth
        controller.setOpening(openingID, appeared: appeared)
    }

    final class Controller: UIViewController {
        var willLeave: (Bool) -> Void = { _ in }
        var completed: (Bool, Bool) -> Void = { _, _ in }
        var removed: () -> Void = {}
        var becameCurrent: () -> Void = {}
        var expectedDepth: Int?
        private var openingID: UUID?
        private var appeared: (UUID, String) -> Void = { _, _ in }
        private var initialAppearanceCompleted = false
        private var visible = false
        private weak var observedNavigation: UINavigationController?
        private weak var observedDestination: UIViewController?
        var visibilityChanged: (Bool) -> Void = { _ in }
        func setOpening(_ id: UUID?, appeared: @escaping (UUID, String) -> Void) {
            self.appeared = appeared
            if openingID != id {
                openingID = id
                if initialAppearanceCompleted, visible, let id { appeared(id, "alreadyVisible") }
            }
        }
        private var destination: UIViewController? {
            guard let navigation = navigationController else { return nil }
            var owner: UIViewController = self
            while let parent = owner.parent, parent !== navigation { owner = parent }
            guard owner.parent === navigation else { return nil }
            if let expectedDepth {
                let index = navigation.viewControllers.firstIndex(of: owner)
                let popped = index == nil && owner.isMovingFromParent && navigation.viewControllers.count == expectedDepth - 1
                guard index == expectedDepth - 1 || popped else { return nil }
            }
            observedNavigation = navigation; observedDestination = owner
            return owner
        }
        private func finishAppearance(_ id: UUID?, reason: String) {
            guard !initialAppearanceCompleted, let owner = destination,
                  navigationController?.topViewController === owner else { return }
            initialAppearanceCompleted = true
            if let id, openingID == id { appeared(id, reason) }
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard !initialAppearanceCompleted, let transition = transitionCoordinator,
                  let owner = destination, transition.viewController(forKey: .to) === owner else { return }
            let id = openingID
            ReaderOpenDiagnostics.mark(id, "pushStarted")
            transition.animate(alongsideTransition: nil) { [weak self, weak owner] context in
                guard let self, !context.isCancelled, self.openingID == id, let owner,
                      self.navigationController?.viewControllers.contains(where: { $0 === owner }) == true else { return }
                self.finishAppearance(id, reason: "coordinator")
            }
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated); visible = true; visibilityChanged(true)
            finishAppearance(openingID, reason: "didAppear")
            if let owner = destination, let navigation = navigationController, navigation.topViewController === owner {
                ReaderSceneDiagnostics.record("native.sourceAppeared", opening: openingID, fields: [
                    "expectedDepth": expectedDepth ?? -1, "topTitle": owner.title ?? "",
                    "stack": navigation.viewControllers.map { ["type": String(describing: type(of: $0)), "title": $0.title ?? ""] }])
                becameCurrent()
            }
        }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated); visible = false; visibilityChanged(false)
            // Unanimated source suffix removal has no transition coordinator.
            // A covered page still belongs to its stack and must not release.
            if !tracking, let navigation = observedNavigation, let owner = observedDestination,
               !navigation.viewControllers.contains(where: { $0 === owner }) {
                completed(true, false)
            }
        }
        private var tracking = false
        override func loadView() {
            view = UIView(); view.isUserInteractionEnabled = false
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard !tracking, let navigation = navigationController,
                  let transition = transitionCoordinator,
                  let source = transition.viewController(forKey: .from) else { return }
            var ancestor: UIViewController? = self
            while let value = ancestor, value !== source { ancestor = value.parent }
            guard ancestor === source, source.parent === navigation,
                  destination === source else { return }
            let popping = source.isMovingFromParent || !navigation.viewControllers.contains(source)
            ReaderSceneDiagnostics.record("native.navigationWillDisappear", opening: openingID, fields: [
                "fromType": String(describing: type(of: source)), "fromTitle": source.title ?? "",
                "toType": transition.viewController(forKey: .to).map { String(describing: type(of: $0)) } ?? "none",
                "toTitle": transition.viewController(forKey: .to)?.title ?? "none", "popping": popping, "expectedDepth": expectedDepth ?? -1,
                "stack": navigation.viewControllers.map { ["type": String(describing: type(of: $0)), "title": $0.title ?? ""] }])
            tracking = true
            willLeave(popping)
            let finished = completed
            transition.animate(alongsideTransition: nil) { [weak self] context in
                self?.tracking = false
                finished(popping, context.isCancelled)
            }
        }
    }
}

/// Scope native interactive navigation to this reader. UIKit owns the transition
/// and its cancellation; no copied gesture targets or navigation delegates.
@MainActor
final class ReaderBackNavigation: NSObject, UIGestureRecognizerDelegate {
    private struct Registration {
        let gesture: UIGestureRecognizer
        let delegate: (any UIGestureRecognizerDelegate)?
        let wasEnabled: Bool
    }

    private weak var owner: UIViewController?
    private var registrations: [Registration] = []
    var canBegin: () -> Bool = { false }
    var allowsContentGesture: () -> Bool = { true }
    var readingPan: (() -> UIPanGestureRecognizer?)?

    func install(on owner: UIViewController) {
        guard registrations.isEmpty, let navigation = owner.navigationController else { return }
        self.owner = owner
        var gestures = [navigation.interactivePopGestureRecognizer].compactMap { $0 }
        if #available(iOS 26, *), let content = navigation.interactiveContentPopGestureRecognizer {
            gestures.append(content)
        }
        for gesture in gestures {
            registrations.append(Registration(gesture: gesture, delegate: gesture.delegate, wasEnabled: gesture.isEnabled))
            gesture.delegate = self
            // The hidden navigation bar may disable native recognition. Eligibility
            // remains in the delegate, including the reading-mode restriction.
            gesture.isEnabled = true
        }
    }

    func uninstall() {
        for registration in registrations {
            if registration.gesture.delegate === self {
                registration.gesture.delegate = registration.delegate
                registration.gesture.isEnabled = registration.wasEnabled
            }
        }
        registrations.removeAll()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard canBegin(), let owner, let navigation = owner.navigationController,
              navigation.viewControllers.count > 1, navigation.transitionCoordinator == nil else { return false }
        var destination = owner
        while let parent = destination.parent, parent !== navigation { destination = parent }
        guard destination === navigation.topViewController else { return false }
        if #available(iOS 26, *), gestureRecognizer === navigation.interactiveContentPopGestureRecognizer,
           !allowsContentGesture() { return false }
        // UIKit's native edge/content recognizers determine direction and motion
        // thresholds. Adding another velocity cone rejects otherwise valid pans.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Reject vertical movement before allowing the text view to scroll, and
        // keep a horizontal back gesture from also moving the reading position.
        otherGestureRecognizer === readingPan?()
    }

}
