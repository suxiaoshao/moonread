import MoonreadDesign
import SwiftUI

extension AIConversation: Identifiable {}

/// One title menu for the conversation tab and the reading sheet.
struct AIConversationTitleMenu: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var renaming = false
    @State private var renamingID: String?
    @State private var name = ""
    let currentID: String?
    let create: () -> Void
    let select: (String) -> Void
    var body: some View {
        Menu {
            Button("新对话", systemImage: "square.and.pencil", action: create)
            if let conversation, conversation.hasSentMessage {
                Button("重命名…", systemImage: "pencil") {
                    renamingID = conversation.id
                    name = conversation.title
                    renaming = true
                }
            }
            if !ai.conversations.isEmpty {
                Divider()
                ForEach(ai.conversations) { value in
                    Button { select(value.id) } label: {
                        if value.id == currentID { Label(value.title, systemImage: "checkmark") } else { Text(value.title) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
            .foregroundStyle(Color(uiColor: theme.ink))
            .frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
        }
        .accessibilityLabel("选择对话").accessibilityValue(title).accessibilityIdentifier("aiConversationMenu")
        .alert("重命名对话", isPresented: $renaming, presenting: renamingID) { id in
            TextField("对话标题", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let title = name
                Task { await ai.renameConversation(id, title: title) }
            }
            .disabled(AIConversationTitle.manual(name).isEmpty)
        }
    }
    private var conversation: AIConversation? { currentID.flatMap { ai.conversation($0) } }
    private var title: String { conversation?.title ?? AIConversationTitle.untitled }
}
