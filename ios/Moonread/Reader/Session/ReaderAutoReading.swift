import SwiftUI
import UIKit

/// One reading opening's explicit automatic-motion intent. Only speed persists.
@MainActor @Observable final class ReaderAutoReading {
    enum Phase: Equatable { case idle, starting, running, paused, preparing, ready, failed, finished }
    private(set) var phase = Phase.idle
    private(set) var failure: String?
    private(set) var panelRequest = 0
    @ObservationIgnored private weak var viewport: ReadingViewportAccess?
    @ObservationIgnored var readable: () -> Bool = { false }
    @ObservationIgnored var motionChanged: () -> Void = {}
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var target: DisplayTarget?
    @ObservationIgnored private var lastFrame: TimeInterval?
    @ObservationIgnored private var lastCheckpoint: TimeInterval?
    @ObservationIgnored private var opening: UUID?
    @ObservationIgnored private var pointsPerSecond: CGFloat = 0
    @ObservationIgnored private var preparationFailure: String?
    @ObservationIgnored private var advancedMilliseconds: Double = 0
    var milliseconds: UInt64 { UInt64(max(0, advancedMilliseconds)) }
    var running: Bool { phase == .running }
    var hidingTools: Bool { phase == .starting || running }

    init(viewport: ReadingViewportAccess) { self.viewport = viewport }

    func requestStart() { failure = nil; transition(.starting) }
    struct Geometry {
        let bodyWidth: CGFloat
        let fontPointSize: CGFloat
        let lineAdvance: CGFloat
    }
    static func velocity(emPerMinute: Double, geometry: Geometry) -> CGFloat? {
        let values = [CGFloat(emPerMinute), geometry.bodyWidth, geometry.fontPointSize, geometry.lineAdvance]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let points = CGFloat(emPerMinute) / (geometry.bodyWidth / geometry.fontPointSize) * geometry.lineAdvance / 60
        return points.isFinite && points > 0 ? points : nil
    }
    enum BodyTapAction: Equatable { case pause, resume, ordinary }
    func bodyTapAction(wasRunning: Bool) -> BodyTapAction {
        if wasRunning, phase == .paused { return .pause }
        return phase == .paused || phase == .ready ? .resume : .ordinary
    }

    func startAfterDismissal(opening: UUID?, speed: Double) {
        guard phase == .starting else { return }
        guard let opening, let controller = viewport?.controller, controller.openingID == opening,
              readable(), let geometry = controller.automaticReadingGeometry(),
              let em = try? autoReadingEmPerMinute(speed: speed),
              let velocity = Self.velocity(emPerMinute: em, geometry: geometry) else {
            transition(.paused); return
        }
        self.opening = opening; pointsPerSecond = velocity
        lastFrame = nil; lastCheckpoint = nil
        transition(.running)
        let target = DisplayTarget(self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayTarget.frame(_:)))
        self.target = target; displayLink = link
        link.add(to: .main, forMode: .common)
    }
    func pause(showPanel: Bool = false) {
        if phase == .running || phase == .starting { transition(.paused) }
        if showPanel { panelRequest &+= 1 }
    }
    func waiting() {
        if let preparationFailure { failed(preparationFailure) } else { transition(.preparing) }
        panelRequest &+= 1
    }
    func updatePreparationFailure(_ message: String?) {
        preparationFailure = message
        if phase == .preparing, let message { failed(message) }
    }
    func prepared() { if phase == .preparing || phase == .failed { failure = nil; transition(.ready) } }
    func failed(_ message: String) { failure = message; transition(.failed) }
    func reachedEnd() { transition(.finished); panelRequest &+= 1 }
    func end() { failure = nil; transition(.idle) }
    func retrying() { failure = nil; preparationFailure = nil; transition(.preparing) }

    private func transition(_ next: Phase) {
        guard phase != next else { return }
        let wasRunning = running
        if next != .running {
            displayLink?.invalidate(); displayLink = nil; target = nil; lastFrame = nil
        }
        phase = next
        viewport?.controller?.deviceControls.setAutomaticReading(running)
        if wasRunning { viewport?.controller?.reportScroll(settled: true) }
        motionChanged()
        viewport?.controller?.visibleTextViews.forEach { viewport?.controller?.configureAccessibility($0) }
    }

    func frame(at timestamp: TimeInterval) {
        guard running else { return }
        guard let controller = viewport?.controller, controller.openingID == opening, readable() else { pause(); return }
        defer { if running { lastFrame = timestamp } }
        guard let previous = lastFrame else { return }
        // Keep sub-pixel progress, but never catch up a background interval or a
        // stalled main thread in one frame. Only accepted advancing time counts.
        let elapsed = min(0.05, max(0, timestamp - previous))
        switch controller.advanceAutomaticReading(by: pointsPerSecond * elapsed) {
        case .advanced(let fraction):
            advancedMilliseconds += elapsed * fraction * 1000
            if lastCheckpoint == nil || timestamp - lastCheckpoint! >= 1 {
                lastCheckpoint = timestamp
                controller.reportScroll(settled: false)
                controller.reevaluateWindowRequests()
            }
        case .preparing: controller.requestMore(.forward); waiting()
        case .end: reachedEnd()
        case .blocked: pause()
        }
    }

    @MainActor private final class DisplayTarget: NSObject {
        weak var owner: ReaderAutoReading?
        init(_ owner: ReaderAutoReading) { self.owner = owner }
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.frame(at: link.timestamp)
        }
    }
}

enum AutomaticReadingStep { case advanced(Double), preparing, end, blocked }

/// Observe touch-down without cancelling or delaying UIKit's own gestures.
@MainActor final class ReaderTouchObserver: UIGestureRecognizer {
    var began: () -> Void = {}
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        began(); state = .failed
    }
}
