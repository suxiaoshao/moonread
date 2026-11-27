import MoonreadDesign
import SwiftUI

extension AIConversation: Identifiable {}

/// One title menu for the conversation tab and the reading sheet.
struct AIConversationTitleMenu: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let currentID: String?
    let create: () -> Void
    let select: (String) -> Void
    var body: some View {
        Menu {
            Button("新对话", systemImage: "square.and.pencil", action: create)
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
    }
    private var title: String { currentID.flatMap { ai.conversation($0)?.title } ?? String(localized: "新对话") }
}
