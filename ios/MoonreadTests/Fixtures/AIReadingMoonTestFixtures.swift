import SwiftUI
import XCTest

@testable import Moonread

@MainActor
class AIReadingMoonFixture: XCTestCase {
  func snapshot(_ status: AIAgentStatus, running: Bool, pose: MoonPose = .idle, id: String = "c1")
    -> AIMoonSnapshot
  {
    AIMoonSnapshot(conversationID: id, running: running, status: status, pose: pose, label: "")
  }

}

/// Renders the character through the production views so its small-size,
/// light/dark and still (Reduce Motion) frames can be inspected as images.
