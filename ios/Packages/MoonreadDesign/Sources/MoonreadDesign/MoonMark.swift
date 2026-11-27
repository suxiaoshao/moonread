import SwiftUI

/// A 40pt moonlight disc inside its 56pt tappable canvas.
/// Animation runs only while shown, in the foreground and with motion allowed;
/// otherwise each pose is its still key frame.
public struct AIMoonMark: View {
    let pose: MoonPose
    @State private var shown: MoonPose
    @State private var since = Date.now
    @State private var completionFinished = false
    @Environment(\.moonreadReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.scenePhase) private var scenePhase

    public init(pose: MoonPose) { self.pose = pose; _shown = State(initialValue: pose == .answering ? .idle : pose) }
    private var reduced: Bool { appReduceMotion || systemReduceMotion }

    public var body: some View {
        let animating = !reduced && scenePhase == .active && (shown == .answering || (shown.completed && !completionFinished))
        ZStack {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
                MoonCharacter(pose: shown, discSize: 40,
                              time: animating ? max(0, context.date.timeIntervalSince(since)) : nil, floating: true)
            }
            .id(shown)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: reduced ? 0.15 : 0.2), value: shown)
        .contentShape(Rectangle())
        .task(id: shown) {
            completionFinished = false
            guard shown.completed else { return }
            do { try await Task.sleep(for: .milliseconds(900)); try Task.checkCancellation(); completionFinished = true } catch { }
        }
        .task(id: pose) {
            guard pose != shown else { return }
            if ![.needsYou, .done, .doneReview, .failed].contains(pose) {
                // Under 300ms a pose is never shown; a shown pose holds 1.2s.
                let hold = shown == .answering ? 1.2 - Date.now.timeIntervalSince(since) : 0
                let wait = max(0.3, hold)
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
            shown = pose; since = .now
        }
    }
}
