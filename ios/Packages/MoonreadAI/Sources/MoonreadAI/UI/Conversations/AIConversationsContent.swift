import MoonreadDesign
import SwiftUI

public struct AIConversationsContent<Chat: View, Route: Hashable, Destination: View>: View {
    private let openSettings: () -> Void
    private let chat: (String) -> Chat
    private let libraryDestination: (Route) -> Destination

    public init(openSettings: @escaping () -> Void, @ViewBuilder chat: @escaping (String) -> Chat,
                @ViewBuilder libraryDestination: @escaping (Route) -> Destination) {
        self.openSettings = openSettings
        self.chat = chat
        self.libraryDestination = libraryDestination
    }

    @Environment(AIService.self) private var ai
    @State private var path = NavigationPath()
    @State private var visible = false
    @State private var notice: AIActionNotice?
    public var body: some View {
        NavigationStack(path: $path) {
            AIConversationList(
                conversations: ai.conversations.map { item in
                    AIConversationListItem(id: item.id, title: item.title, preview: item.preview,
                        updated: item.updated, status: item.head.status, awaitingConfirmation: item.head.status == .waitingConfirmation
                            || item.activity.status == .waitingDataSharing, running: item.running)
                },
                error: ai.error, loaded: ai.loaded, reload: { await ai.load() },
                delete: { ai.delete($0) }, openSettings: openSettings,
                openDraft: { Task { if let value = await ai.openDraft() { path.append(value.id) } } }
            )
                .navigationDestination(for: Route.self, destination: libraryDestination)
                .navigationDestination(for: String.self) { id in
                    chat(id)
                        .modifier(AIConversationTitleMenu(currentID: id, create: { createConversation(after: id) },
                            select: { path = NavigationPath([$0]) }))
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("新对话", systemImage: "square.and.pencil") { createConversation(after: id) }
                                    .toolbarGlyph()
                            }
                        }
                }
        }.task { await ai.load(); await ai.providers.refreshCatalogsIfNeeded() }
        .onAppear { visible = true }.onDisappear { visible = false; notice = nil }
        .onReceive(MainActorNotifications.publisher(for: .aiActionFailed)) { notification in
            guard visible, path.isEmpty, let event = notification.object as? AIActionNotice, event.sessionID == nil else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
    }

    private func createConversation(after id: String) {
        Task {
            if let value = await ai.create(noticeOwner: id) { path = NavigationPath([value.id]) }
        }
    }
}
