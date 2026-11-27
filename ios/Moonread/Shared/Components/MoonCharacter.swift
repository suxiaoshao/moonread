import MoonreadDesign
import MoonreadAI
import SwiftUI

extension MoonPose {
    static func live(running: Bool, status: AIAgentStatus, hasTools: Bool, reasoning: Bool) -> Self {
        guard running else { return .idle }
        if status == .waitingConfirmation || status == .waitingDataSharing { return .needsYou }
        if status == .compacting { return .idle }
        return hasTools || reasoning ? .answering : .idle
    }
}
