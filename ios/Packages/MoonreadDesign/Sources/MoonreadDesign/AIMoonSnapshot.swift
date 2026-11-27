/// What the reading Moon can see of the conversation selected in this opening.
public struct AIMoonSnapshot: Equatable {
    public let conversationID: String
    public let running: Bool
    public enum Status: Equatable {
        case idle, waitingConfirmation, waitingDataSharing, completed, failed
    }

    public let status: Status
    /// The live pose while the run is going.
    public let pose: MoonPose
    public let label: String

    public init(conversationID: String, running: Bool, status: Status, pose: MoonPose, label: String) {
        self.conversationID = conversationID
        self.running = running
        self.status = status
        self.pose = pose
        self.label = label
    }
}
