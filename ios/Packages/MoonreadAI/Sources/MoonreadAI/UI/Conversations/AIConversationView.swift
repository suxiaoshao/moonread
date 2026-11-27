import MoonreadDesign
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import SwiftUI
import AISDKProvider
import AISDKProviderUtils

public struct AIConversationView: View {
    public init(conversationID: String, placement: AIChatPlacement = .page, taskObject: AITaskObject? = nil,
                anchor: AIConversationAnchor? = nil, host: AIConversationHost) {
        self.conversationID = conversationID
        self.placement = placement
        self.taskObject = taskObject
        self.anchor = anchor
        self.host = host
    }

    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.metadataCoverRenderer) private var renderCover
    public let conversationID: String
    public var placement: AIChatPlacement = .page
    public var taskObject: AITaskObject?
    public var anchor: AIConversationAnchor? = nil
    private let host: AIConversationHost
    @State private var anchored = false
    @State private var highlightedTurn: String?
    @State private var attachmentPreview: AIReadingAttachment?
    @State private var pickingKind: AIReadingAttachment.Kind?
    @State private var listRequest = AIMessageListRequest()
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var atBottom = true
    @State private var visible = false
    @FocusState private var inputFocused: Bool
    @State private var restoreInputFocus = false
    @State private var notice: AIActionNotice?
    @State private var feedbackPresenter = AIReplyFeedbackPresenter()
    private var background: UIColor { placement == .page ? theme.canvas : theme.surface }

    public var body: some View {
        let conversation = ai.conversation(conversationID)
        AIChatSurface(placement: placement, available: conversation != nil) {
            if let conversation { content(conversation) }
        }
        .toolbar(.hidden, for: .tabBar)
        .modifier(AIDataSharingPresentation(owner: conversationID))
        .sheet(item: $attachmentPreview) { AIReadingAttachmentPreview(attachment: $0, owner: conversationID) }
        .sheet(item: $pickingKind) {
            AIReadingObjectPicker(kind: $0, conversationID: conversationID)
        }
        .onAppear { visible = true; ai.selectedID = conversationID; ai.conversation(conversationID)?.beginMessagePresentation() }
        .onDisappear { visible = false; notice = nil; restoreInputFocus = false; ai.proposals.closeSession(conversationID) }
    }

    @ViewBuilder private func content(_ conversation: AIConversation) -> some View {
        let rows = (taskObject == nil ? [] : [AIMessageRow(id: "task/header", turnID: nil, content: .header)]) + conversation.messageRows
        let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        AIChatLayout(isEmpty: rows.isEmpty, atBottom: atBottom, queue: conversation.head.queue, showLatest: {
            await ai.showLatest(conversation.id)
            listRequest = .init(target: .bottom)
        }, cancelQueued: { ai.cancelQueued(conversation.id, inputID: $0) }) { bottomInset in
            AIMessageList(rows: rows.map(\.viewportRow), presentation: conversation.messagePresentation, background: background,
                          bottomInset: bottomInset, request: listRequest, highlightedTurn: highlightedTurn,
                          atBottom: $atBottom, dismissKeyboard: { inputFocused = false },
                          toggleProcess: { [weak conversation] in conversation?.toggleProcessItem($0) },
                          replyFeedback: { id in
                guard let row = indexed[id],
                      let feedback = AIReplyFeedback(row: row, conversation: conversation,
                                                     connections: ai.providers.connections,
                                                     recipient: host.replyFeedbackRecipient) else { return nil }
                return (feedback.text, { feedbackPresenter.present(feedback, from: $0, theme: $1) })
            }) { id, toggle in
                AnyView(Group {
                    if let row = indexed[id] {
                        AIMessageRowView(row: row, conversationID: conversationID, taskObject: taskObject,
                                         preview: { attachmentPreview = $0 }, loadEarlier: {
                            listRequest = .init(target: .preserve)
                            ai.loadEarlier(conversationID)
                        }, host: host, onHostAction: performHostAction, toggleProcessItem: toggle)
                        .background(row.turnID == highlightedTurn && highlightedTurn != nil ? Color(uiColor: theme.search) : .clear)
                        .environment(ai).environment(\.theme, theme).environment(\.dynamicTypeSize, typeSize)
                        .environment(\.colorScheme, theme.scheme)
                        .environment(\.metadataCoverRenderer, renderCover)
                    }
                })
            }.id(conversationID)
                .underNavigationBar()
        } composer: {
            AIComposer(conversation: conversation, placement: placement, modelTarget: .conversation(conversation.id),
                       pickingKind: $pickingKind, attachmentPreview: $attachmentPreview, inputFocused: $inputFocused,
                       onSend: {
                           restoreInputFocus = inputFocused
                           Task { await ai.showLatest(conversation.id); if visible { listRequest = .init(target: .bottom) } }
                       })
        }
        .task(id: anchor) {
            guard !anchored else { return }; anchored = true
            guard let anchor else { await ai.showLatest(conversationID); return }
            listRequest = .init(target: .preserve)
            await ai.showMessage(conversationID, around: anchor)
            conversation.processExpansion[anchor.turn] = true
            if let row = conversation.messageRowID(for: anchor) { listRequest = .init(target: .row(row)) }
            highlightedTurn = anchor.turn
            try? await Task.sleep(for: .seconds(1.5)); highlightedTurn = nil
        }
        .navigationTitle(conversation.title).navigationBarTitleDisplayMode(.inline)
        .onChange(of: conversation.submitting) { _, submitting in
            if !submitting, restoreInputFocus, visible { inputFocused = true; restoreInputFocus = false }
        }
        .onReceive(MainActorNotifications.publisher(for: .aiActionFailed)) { notification in
            guard visible, let event = notification.object as? AIActionNotice, event.sessionID == conversationID else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
        .task { await ai.providers.refreshCatalogsIfNeeded() }
    }

    private func performHostAction(_ action: AIConversationHostAction) {
        if host.onAction(action) { inputFocused = false }
    }
}
