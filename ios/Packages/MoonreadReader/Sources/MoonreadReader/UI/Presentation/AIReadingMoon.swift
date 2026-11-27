import MoonreadDesign
import SwiftUI

/// What the reading Moon can see of the conversation selected in this opening.
public struct AIMoonSnapshot: Equatable {
    let conversationID: String
    let running: Bool
    public enum Status: Equatable {
        case idle, waitingConfirmation, waitingDataSharing, completed, failed
    }

    let status: Status
    /// The live pose while the run is going.
    let pose: MoonPose
    let label: String

    public init(conversationID: String, running: Bool, status: Status, pose: MoonPose, label: String) {
        self.conversationID = conversationID
        self.running = running
        self.status = status
        self.pose = pose
        self.label = label
    }
}

/// Brief reading-time notices for one book opening. Notices come only from
/// transitions observed here, so reopening a book or refreshing state never
/// replays an old outcome; acknowledging an outcome never rewrites the task.
struct AIMoonPresence: Equatable {
    enum Notice: Equatable {
        case working, needsYou, outcome(MoonPose)
        var duration: Duration {
            switch self {
            case .working: .milliseconds(2500)
            case .needsYou: .seconds(6)
            case .outcome(.doneReview): .seconds(4)
            case .outcome(.failed): .seconds(5)
            case .outcome: .seconds(2)
            }
        }
    }
    struct Shown: Equatable {
        let id = UUID()
        let notice: Notice
    }

    private(set) var conversationID: String?
    private(set) var running = false
    private(set) var status = AIMoonSnapshot.Status.idle
    private(set) var queued: Notice?
    private(set) var shown: Shown?
    /// An outcome the person has not seen in the conversation yet, kept for the
    /// moment they open the reading controls.
    private(set) var unseen: MoonPose?

    /// `review` is only evaluated when a completion is observed.
    mutating func observe(_ snapshot: AIMoonSnapshot?, chatOpen: Bool, review: () -> Bool) {
        guard let snapshot else { self = .init(); return }
        guard snapshot.conversationID == conversationID else {
            // A newly selected conversation is a baseline, never an event.
            self = .init(); conversationID = snapshot.conversationID
            running = snapshot.running; status = snapshot.status
            return
        }
        defer { running = snapshot.running; status = snapshot.status }
        if snapshot.running && !running { unseen = nil }
        guard !chatOpen else { return }
        if snapshot.running, [.waitingConfirmation, .waitingDataSharing].contains(snapshot.status), status != snapshot.status { queued = .needsYou }
        guard running, !snapshot.running else { return }
        switch snapshot.status {
        case .completed:
            let pose: MoonPose = review() ? .doneReview : .done
            queued = .outcome(pose); unseen = pose == .doneReview ? pose : nil
        case .failed:
            queued = .outcome(.failed); unseen = .failed
        default:
            // Stopped by the person: nothing to announce.
            queued = nil; shown = nil
        }
    }
    mutating func chatOpened() { queued = nil; shown = nil; unseen = nil }
    mutating func chatClosed() {
        guard running else { return }
        queued = [.waitingConfirmation, .waitingDataSharing].contains(status) ? .needsYou : .working
    }
    /// Shows the queued notice; call only when the page can take one.
    mutating func reveal() -> Shown? {
        guard let queued else { return nil }
        self.queued = nil; shown = Shown(notice: queued)
        return shown
    }
    /// A panel, search or the background hides the Moon and ends its notice.
    mutating func conceal() { shown = nil }
    mutating func expire(_ id: UUID) { if shown?.id == id { shown = nil } }

    func pose(live: MoonPose) -> MoonPose {
        if running { return live }
        if case .outcome(let pose) = shown?.notice { return pose }
        return unseen ?? .idle
    }
}

extension MoonPose {
    public var outcomeLabel: String {
        switch self {
        case .done: String(localized: "已完成")
        case .doneReview: String(localized: "已完成，有建议待查看")
        case .failed: String(localized: "未完成")
        default: ""
        }
    }
}

struct AIReadingMoon: View {
    let pose: MoonPose
    let label: String
    let visible: Bool
    let reservedBottom: CGFloat
    @Binding var position: CGPoint?
    let action: () -> Void
    @Environment(\.moonreadReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var dragOrigin: CGPoint?
    private var reduced: Bool { appReduceMotion || systemReduceMotion }

    var body: some View {
        GeometryReader { geometry in
            let initial = CGPoint(x: geometry.size.width - 44, y: geometry.size.height - reservedBottom - 60)
            let point = clamp(position ?? initial, size: geometry.size)
            ZStack {
                if visible {
                    Button(action: action) { AIMoonMark(pose: pose) }
                        .buttonStyle(AIMoonPressStyle())
                        .accessibilityLabel("月读助手").accessibilityHint("打开对话").accessibilityValue(label)
                        .accessibilityIdentifier("readerAIMoon")
                        .transition(.opacity)
                        .position(point)
                        .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { value in
                            if dragOrigin == nil { dragOrigin = point }
                            if let origin = dragOrigin { position = clamp(CGPoint(x: origin.x + value.translation.width, y: origin.y + value.translation.height), size: geometry.size) }
                        }.onEnded { _ in dragOrigin = nil })
                }
            }
            .animation(.easeInOut(duration: reduced ? 0.15 : 0.3), value: visible)
        }
    }
    private func clamp(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(34, point.x), max(34, size.width - 34)), y: min(max(100, point.y), max(100, size.height - reservedBottom - 44)))
    }
}

private struct AIMoonPressStyle: ButtonStyle {
    @Environment(\.moonreadReduceMotion) private var appReduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let reduced = appReduceMotion || systemReduceMotion
        configuration.label
            .scaleEffect(configuration.isPressed && !reduced ? 0.92 : 1)
            .opacity(configuration.isPressed && reduced ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
