import Foundation
import MoonreadAI

extension AIReplyFeedback {
    @MainActor init?(row: AIMessageRow, conversation: AIConversation, connections: [AIConnection]) {
        self.init(row: row, conversation: conversation, connections: connections, recipient: AppLinks.supportEmail)
    }
    init(provider: String, model: String, text: String, version: String? = nil) {
        self.init(provider: provider, model: model, text: text, recipient: AppLinks.supportEmail, version: version)
    }
}
