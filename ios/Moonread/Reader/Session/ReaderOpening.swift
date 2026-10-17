import SwiftUI
import UIKit

/// One request to enter reading; file identity and the route target stay independent.
struct OpeningRequest: Hashable, Sendable {
    let id: UUID
    let target: ReaderRoute
    let routeRequested: TimeInterval
    let tap: TimeInterval?
    init(target: ReaderRoute, tap: TimeInterval? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        id = UUID(); self.target = target; routeRequested = now; self.tap = tap
        ReaderOpenDiagnostics.begin(self)
    }
}

enum ReaderOpeningPhase: Equatable { case blank, titlePage, reading }

/// Only this opening's local content switch animates. Navigation remains native.
@MainActor @Observable
final class ReaderOpeningState {
    private(set) var request: OpeningRequest?
    private(set) var phase = ReaderOpeningPhase.blank
    private(set) var showsProgress = false
    private(set) var placeholderShown = false
    private(set) var fadesContent = false
    private(set) var navigationSettled = false
    private(set) var contentReady = false
    private var terminal = false
    private var reduced = false
    func reduceMotion(_ value: Bool) { reduced = value; evaluate() }
    private var active = false
    private var visible = false
    private var timer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var timingToken = UUID()
    private let now: () -> TimeInterval
    private let schedules: Bool
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, schedules: Bool = true) {
        self.now = now; self.schedules = schedules
    }
    func begin(_ request: OpeningRequest, navigationSettled: Bool = false) {
        ReaderOpenDiagnostics.mark(request.id, "pushViewMounted")
        cancelTimers(); self.request = request
        phase = ReaderOpenDiagnostics.deferredPage ? .blank : .titlePage
        showsProgress = !ReaderOpenDiagnostics.deferredPage
        placeholderShown = false; fadesContent = false; contentReady = false; terminal = false
        self.navigationSettled = navigationSettled
        schedule(); evaluate()
    }
    func update(ready: Bool, terminal: Bool, reduced: Bool? = nil) {
        self.contentReady = ready; self.terminal = terminal; if let reduced { self.reduced = reduced }
        evaluate()
    }
    func visibility(_ visible: Bool, active: Bool) {
        self.visible = visible; self.active = active
        cancelTimers()
        if visible && active { schedule(); evaluate() }
    }
    func settled(_ id: UUID, reason: String) {
        guard request?.id == id, !navigationSettled else { return }
        navigationSettled = true; watchdog?.cancel(); watchdog = nil
        ReaderOpenDiagnostics.mark(id, reason == "watchdog" ? "pushFallback" : "pushCompleted")
        evaluate()
    }
    func placeholderDisplayed(_ id: UUID) {
        guard request?.id == id, visible, active, phase == .titlePage, !placeholderShown else { return }
        placeholderShown = true; ReaderOpenDiagnostics.mark(id, "placeholderDisplayed")
    }
    /// Public to deterministic tests: state uses absolute deadlines, never timer order.
    func evaluate() {
        guard let request else { return }
        if contentReady {
            if phase != .reading {
                fadesContent = ReaderOpenDiagnostics.deferredPage && placeholderShown && !reduced && visible && active
                phase = .reading; showsProgress = false
                ReaderOpenDiagnostics.mark(request.id, fadesContent ? "readingFade" : "readingDirect")
            }
            cancelTimers(); return
        }
        guard visible && active else { return }
        if terminal { phase = .titlePage; showsProgress = false; return }
        if !ReaderOpenDiagnostics.deferredPage { phase = .titlePage; showsProgress = true; return }
        let elapsed = now() - request.routeRequested
        phase = navigationSettled && elapsed >= 0.3 ? .titlePage : .blank
        showsProgress = phase == .titlePage && elapsed >= 0.8
    }
    func leave() { visible = false; active = false; cancelTimers() }
    private func cancelTimers() {
        timingToken = UUID(); timer?.cancel(); timer = nil; watchdog?.cancel(); watchdog = nil
    }
    private func schedule() {
        guard schedules, visible, active, !contentReady, let request else { return }
        let token = timingToken
        timer = Task { [weak self] in
            for delay in [0.3, 0.8] {
                guard let self else { return }
                do { try await Task.sleep(for: .seconds(max(0, request.routeRequested + delay - self.now()))) }
                catch { return }
                guard !Task.isCancelled, self.timingToken == token, self.request?.id == request.id else { return }
                self.evaluate()
            }
        }
        if !navigationSettled {
            watchdog = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
                guard let self, self.timingToken == token, self.request?.id == request.id, self.visible, self.active else { return }
                self.settled(request.id, reason: "watchdog")
            }
        }
    }
}

/// A mounted title must reach an active display opportunity before enabling fade.
struct ReaderPlaceholderWitness: UIViewRepresentable {
    let displayed: () -> Void
    func makeUIView(context: Context) -> Witness { Witness() }
    func updateUIView(_ view: Witness, context: Context) { view.displayed = displayed }
    static func dismantleUIView(_ view: Witness, coordinator: ()) { view.link?.invalidate(); view.link = nil }
    final class Witness: UIView {
        var displayed: () -> Void = {}
        var link: CADisplayLink?
        override func didMoveToWindow() {
            super.didMoveToWindow(); link?.invalidate(); link = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(displayFrame)); self.link = link; link.add(to: .main, forMode: .common)
        }
        @objc private func displayFrame() {
            guard window != nil, UIApplication.shared.applicationState == .active else { return }
            link?.invalidate(); link = nil; displayed()
        }
    }
}
