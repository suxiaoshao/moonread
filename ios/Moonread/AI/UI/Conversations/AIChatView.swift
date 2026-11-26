import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadAI
import SwiftUI
import AISDKProvider
import AISDKProviderUtils

struct AIReadingSearchContext {
    let isOpenBook: (LibraryEntry) -> Bool
    let returnToBook: () -> Void
}

struct AIChatView: View {
    /// The tab page sits on the App canvas; the reading sheet keeps the panel
    /// surface shared by the other reading sheets. Both are the scope's roles.
    enum Placement { case page, sheet }
    @Environment(AIService.self) private var ai
    @Environment(LibraryModel.self) private var library
    @Environment(\.theme) private var theme
    @Environment(\.systemReadingRouter) private var systemReadingRouter
    let conversationID: String
    var placement: Placement = .page
    var taskObject: AITaskObject?
    /// A search match to open at, instead of the newest message.
    var anchor: AIConversationAnchor? = nil
    var readingSearch: AIReadingSearchContext?
    @State private var bookDetails: StatisticsRoute?
    @State private var filterSearch: BookSearchConfiguration?
    @State private var shelfChoice: FilterShelfRequest?
    @State private var resolvedShelfSearch: BookSearchConfiguration?
    @State private var anchored = false
    @State private var highlightedTurn: String?
    @State private var attachmentPreview: AIReadingAttachment?
    @State private var pickingKind: AIReadingAttachment.Kind?
    @State private var listRequest = AIMessageListRequest()
    @State private var queueHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var atBottom = true
    @State private var visible = false
    @FocusState private var inputFocused: Bool
    @State private var restoreInputFocus = false
    @State private var notice: AIActionNotice?
    private var background: UIColor { placement == .page ? theme.canvas : theme.surface }
    private var chat: some View {
        Group {
            if let conversation = ai.conversation(conversationID) { content(conversation) }
            else { ContentUnavailableView("对话不可用", systemImage: "exclamationmark.bubble") }
        }
        // Both placements keep their own canvas behind the system bar.
        .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
        .background(Color(uiColor: background), ignoresSafeAreaEdges: .all)
    }

    @ViewBuilder private var chatWithNavigation: some View {
        if #available(iOS 26, *) {
            chat
        } else {
            chat
                .toolbarBackground(Color(uiColor: background), for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    var body: some View {
        chatWithNavigation
        .toolbar(.hidden, for: .tabBar)
        .modifier(AIDataSharingPresentation(owner: conversationID))
        .sheet(item: $attachmentPreview) { AIReadingAttachmentPreview(attachment: $0, owner: conversationID) }
        .sheet(item: $pickingKind) { AIReadingObjectPicker(kind: $0, conversationID: conversationID) }
        .sheet(item: $shelfChoice, onDismiss: showResolvedShelfSearch) { request in
            AIFilterShelfChoiceSheet(suggestion: request.suggestion) { resolvedShelfSearch = $0 }.themeScope(theme)
        }
        .navigationDestination(item: $bookDetails) { route in
            AIChatSearchPage(model: library, destination: .book(route), reading: readingSearch)
        }
        .navigationDestination(item: $filterSearch) { configuration in
            AIChatSearchPage(model: library, destination: .suggestion(configuration), reading: readingSearch)
        }
        .onAppear { visible = true; ai.selectedID = conversationID; ai.conversation(conversationID)?.beginMessagePresentation() }
        .onDisappear { visible = false; notice = nil; restoreInputFocus = false; ai.proposals.closeSession(conversationID) }
    }
    @ViewBuilder private func content(_ conversation: AIConversation) -> some View {
        let rows = (taskObject == nil ? [] : [AIMessageRow(id: "task/header", turnID: nil, content: .header)]) + conversation.messageRows
        let indexed = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        ZStack(alignment: .bottom) {
            AIMessageList(rows: rows, conversation: conversation, background: background,
                          bottomInset: composerHeight + (conversation.head.queue.isEmpty || queueHeight == 0 ? 0 : queueHeight + LayoutTokens.compact), request: listRequest, highlightedTurn: highlightedTurn,
                          atBottom: $atBottom, dismissKeyboard: { inputFocused = false }) { id, toggle in
                AnyView(Group {
                    if let row = indexed[id] {
                        AIMessageRowView(row: row, conversationID: conversationID, taskObject: taskObject,
                                         preview: { attachmentPreview = $0 }, loadEarlier: {
                            listRequest = .init(target: .preserve)
                            ai.loadEarlier(conversationID)
                        }, openFilter: openFilter, openBook: { route in
                            guard visible, bookDetails == nil else { return }
                            inputFocused = false
                            bookDetails = route
                        }, toggleProcessItem: toggle)
                        .background(row.turnID == highlightedTurn && highlightedTurn != nil ? Color(uiColor: theme.search) : .clear)
                        .environment(ai).environment(\.theme, theme).environment(\.dynamicTypeSize, typeSize)
                        .environment(library)
                        .environment(\.systemReadingRouter, systemReadingRouter)
                        .environment(\.colorScheme, theme.scheme)
                    }
                })
            }.id(conversationID)
                .underNavigationBar()
            if rows.isEmpty {
                VStack(spacing: LayoutTokens.control) {
                    MoonView(size: 40)
                    Text("想聊点什么？").foregroundStyle(Color(uiColor: theme.secondary))
                }.padding(.bottom, composerHeight + LayoutTokens.section * 2).allowsHitTesting(false)
            }
            VStack(spacing: LayoutTokens.compact) {
                VStack(spacing: LayoutTokens.compact) {
                    if !atBottom {
                        Button("回到底部", systemImage: "arrow.down") {
                            Task { await ai.showLatest(conversation.id); listRequest = .init(target: .bottom) }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
                        .background(Color(uiColor: theme.raised), in: .circle)
                        .overlay { Circle().strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
                        .accessibilityIdentifier("aiScrollToBottom")
                    }
                    if !conversation.head.queue.isEmpty {
                        AIQueuedStatus(queue: conversation.head.queue) { ai.cancelQueued(conversation.id, inputID: $0) }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { queueHeight = $0 }
                            .opacity(queueHeight > 0 ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: queueHeight > 0)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: conversation.head.queue.isEmpty)
                AIComposer(conversation: conversation, placement: placement, modelTarget: .conversation(conversation.id),
                           pickingKind: $pickingKind, attachmentPreview: $attachmentPreview, inputFocused: $inputFocused,
                           onSend: {
                               restoreInputFocus = inputFocused
                               Task { await ai.showLatest(conversation.id); if visible { listRequest = .init(target: .bottom) } }
                           })
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
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
        .onChange(of: conversation.head.queue.isEmpty) { _, empty in
            if empty { queueHeight = 0 }
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

    private struct FilterShelfRequest: Identifiable {
        let id = UUID()
        let suggestion: AIBookFilterSuggestion
    }

    private func openFilter(_ suggestion: AIBookFilterSuggestion) {
        guard visible, filterSearch == nil, shelfChoice == nil else { return }
        let resolution = suggestion.resolveShelves(library.shelves)
        guard resolution.unavailable.isEmpty else { return }
        inputFocused = false
        if resolution.complete {
            filterSearch = try? resolution.configuration(suggestion)
        } else {
            shelfChoice = .init(suggestion: suggestion)
        }
    }

    private func showResolvedShelfSearch() {
        defer { resolvedShelfSearch = nil }
        if let resolvedShelfSearch { filterSearch = resolvedShelfSearch }
    }
}

/// Search and a newly saved shelf stay in the stack that already owns this chat.
private struct AIChatSearchPage: View {
    enum Destination { case suggestion(BookSearchConfiguration), savedShelf(UUID), book(StatisticsRoute) }
    let model: LibraryModel
    let destination: Destination
    let reading: AIReadingSearchContext?
    @State private var pushed: LibraryRoute?
    @State private var visible = false

    var body: some View {
        let host = LibraryBrowsingHost(push: { pushed = $0 }, isCurrent: { visible }, allowsFileBrowsing: reading == nil,
                                       isOpenBook: { reading?.isOpenBook($0) ?? false }, returnToOpenBook: { reading?.returnToBook() })
        Group {
            switch destination {
            case .suggestion(let configuration): AppSearchPage(model: model, configuration: configuration, host: host)
            case .savedShelf(let id): SavedFilterDestination(model: model, id: id, host: host)
            case .book(let route): StatisticsView(library: model, target: route, host: host)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationDestination(item: $pushed) { route in
            if case .savedFilter(let id) = route {
                AIChatSearchPage(model: model, destination: .savedShelf(id), reading: reading)
            } else {
                HostedLibraryDestination(route: route, host: host)
            }
        }
        .onAppear { visible = true }.onDisappear { visible = false }
    }
}

/// Queue controls float above the composer without resizing the message viewport.
private struct AIQueuedStatus: View {
    let queue: [AIAgentInput]
    let cancel: (String) -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: LayoutTokens.control) {
            if queue.count == 1, let input = queue.first {
                Text(input.mode == .steering ? "调整当前任务" : "完成后发送")
                Button("取消") { cancel(input.id) }
                    .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .accessibilityLabel("取消发送")
            } else {
                Menu {
                    ForEach(queue) { input in
                        Button("取消：\(input.text)") { cancel(input.id) }
                    }
                } label: {
                    Label("\(queue.count) 条排队中", systemImage: "clock")
                        .frame(minHeight: LayoutTokens.hit)
                }
            }
        }
        .font(.footnote)
        .padding(.horizontal, LayoutTokens.content)
        .foregroundStyle(Color(uiColor: theme.ink))
        .background(Color(uiColor: theme.raised), in: .capsule)
        .overlay { Capsule().strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
        .accessibilityIdentifier("aiQueueStatus")
    }
}
