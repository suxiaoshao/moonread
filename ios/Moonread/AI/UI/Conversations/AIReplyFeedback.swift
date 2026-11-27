import Foundation
import MoonreadAI

extension AIReplyFeedback {
    @MainActor init?(row: AIMessageRow, conversation: AIConversation, connections: [AIConnection]) {
        guard let turn = row.turnID else { return nil }
        let text: String
        if let native = row.nativeText, !native.streaming { text = native.text }
        else if case .actions(let answer, _) = row.content { text = answer }
        else { return nil }
        guard !text.isEmpty, let entry = conversation.entries.last(where: {
            $0.turn == turn && $0.message.object["role"]?.string == "assistant"
                && (row.id == turn + "/actions" || row.id.hasPrefix("\(turn)/s\($0.step)/"))
        }) else { return nil }
        let connection = connections.first { entry.provider == $0.id || entry.provider.hasPrefix($0.id + ":") }
        let model = connection?.models.first { $0.id == entry.model }?.name ?? entry.model
        self.init(provider: connection?.name ?? String(localized: "已删除的连接"), model: model, text: text)
    }
    init(provider: String, model: String, text: String, version: String? = nil) {
        self.init(provider: provider, model: model, text: text, recipient: AppLinks.supportEmail, version: version)
    }
}
