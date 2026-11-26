import MoonreadDesign
import MoonreadCoreBindings
import MoonreadAI
import SwiftUI
import AISDKProvider
import AISDKProviderUtils

struct AIConversationsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var path = NavigationPath()
    @State private var visible = false
    @State private var notice: AIActionNotice?
    var body: some View {
        NavigationStack(path: $path) {
            AIConversationList(
                conversations: ai.conversations.map { item in
                    AIConversationListItem(id: item.id, title: item.title, preview: item.preview, book: item.context.title,
                        updated: item.updated, status: item.head.status, awaitingConfirmation: item.head.status == .waitingConfirmation
                            || item.activity.status == .waitingDataSharing, running: item.running)
                },
                error: ai.error, loaded: ai.loaded, reload: { await ai.load() },
                delete: { ai.delete($0) }, openSettings: { library.shell.openSettings(target: .ai) },
                openDraft: { Task { if let value = await ai.openDraft() { path.append(value.id) } } }
            )
                .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
                .navigationDestination(for: String.self) { id in
                    AIChatView(conversationID: id).toolbar {
                        ToolbarItem(placement: .principal) {
                            AIConversationTitleMenu(currentID: id, create: { Task { if let value = await ai.create(noticeOwner: id) { path = NavigationPath([value.id]) } } },
                                                    select: { path = NavigationPath([$0]) })
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("新对话", systemImage: "square.and.pencil") { Task { if let value = await ai.create(noticeOwner: id) { path = NavigationPath([value.id]) } } }
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
}
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
