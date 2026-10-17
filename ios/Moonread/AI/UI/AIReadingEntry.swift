import SwiftUI

struct AIReadingConversation: View {
    @Environment(AIService.self) private var ai
    let context: AIEntryContext
    let close: () -> Void
    @Binding var selected: String?
    let openingIsActive: () -> Bool
    @State private var visible = false
    @State private var notice: AIActionNotice?
    var body: some View {
        NavigationStack {
            Group {
                if let id = selected { AIChatView(conversationID: id, placement: .sheet) }
                else { ContentUnavailableView("新对话", systemImage: "bubble.left.and.bubble.right") }
            }.toolbar {
                ToolbarItem(placement: .principal) {
                    AIConversationTitleMenu(currentID: selected, create: { Task { await createConversation() } },
                                            select: { selected = $0; seed() })
                }
                ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark", action: close).labelStyle(.iconOnly).toolbarGlyph().accessibilityIdentifier("closeAIChat") }
            }
        }
        .onAppear { visible = true }.onDisappear { visible = false; notice = nil }
        .onReceive(NotificationCenter.default.publisher(for: .aiActionFailed)) { notification in
            guard visible, selected == nil, let event = notification.object as? AIActionNotice, event.sessionID == nil else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
        .task {
            await ai.load()
            guard !Task.isCancelled, openingIsActive() else { return }
            if selected.flatMap({ ai.conversation($0) }) == nil { await createConversation() }
            seed()
        }
    }
    private func createConversation() async {
        guard !Task.isCancelled, openingIsActive() else { return }
        let previous = selected
        guard let value = await ai.create(context: context.association, noticeOwner: previous),
              !Task.isCancelled, openingIsActive(), selected == previous else { return }
        selected = value.id; seed()
    }
    private func seed() {
        if let selected { ai.seedReadingDraft(selected, attachments: context.attachments) }
    }

}
