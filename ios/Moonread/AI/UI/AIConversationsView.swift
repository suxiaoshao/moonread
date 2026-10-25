import SwiftUI
import AISDKProvider
import AISDKProviderUtils

struct AIConversationsView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @State private var path = NavigationPath()
    @State private var visible = false
    @State private var notice: AIActionNotice?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = ai.error {
                    HStack(spacing: LayoutTokens.compact) {
                        Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                            .foregroundStyle(Color(uiColor: theme.destructive))
                        Spacer(minLength: 0)
                        if !ai.loaded { Button("重试") { Task { await ai.load() } }.font(.footnote) }
                    }.listRowBackground(Color(uiColor: theme.canvas))
                }
                ForEach(ai.conversations) { conversation in
                    NavigationLink(value: conversation.id) { AIConversationRow(conversation: conversation) }
                        .listRowBackground(Color(uiColor: theme.canvas))
                        .listRowSeparatorTint(Color(uiColor: theme.separator))
                        .accessibilityIdentifier("aiConversation-\(conversation.id)")
                }.onDelete { offsets in for id in offsets.map({ ai.conversations[$0].id }) { ai.delete(id) } }
            }.listStyle(.plain).themedPage().navigationTitle("对话")
                .overlay {
                    if ai.loaded && ai.conversations.isEmpty {
                        VStack(spacing: LayoutTokens.control) {
                            MoonView(size: 56)
                            Text("还没有对话").foregroundStyle(Color(uiColor: theme.secondary))
                        }.allowsHitTesting(false)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { NavigationLink { AISettingsView() } label: { Label("AI 助手", systemImage: "slider.horizontal.3") }.toolbarGlyph().accessibilityIdentifier("aiAssistantSettings") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("新对话", systemImage: "square.and.pencil") { Task { if let value = await ai.openDraft() { path.append(value.id) } } }.toolbarGlyph().accessibilityIdentifier("newAIConversation")
                        AppSettingsLink()
                    }
                }
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
        .onReceive(NotificationCenter.default.publisher(for: .aiActionFailed)) { notification in
            guard visible, path.isEmpty, let event = notification.object as? AIActionNotice, event.sessionID == nil else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
    }
}
extension AIConversation: Identifiable {}

/// Title and the latest visible message lead; the book and time stay quiet.
private struct AIConversationRow: View {
    let conversation: AIConversation
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.compact) {
                Text(conversation.title).font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(Color(uiColor: theme.ink))
                Spacer(minLength: LayoutTokens.compact)
                status.font(.footnote).lineLimit(1).layoutPriority(1)
            }
            if let preview {
                Text(preview).font(.subheadline).lineLimit(1)
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
            if let book = conversation.context.title, !book.isEmpty {
                Label(book, systemImage: "book.closed").font(.caption).lineLimit(1)
                    .labelStyle(AICompactLabelStyle())
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
    /// The title already is the first question; repeating it adds nothing.
    private var preview: String? {
        let value = conversation.preview
        return value.isEmpty || value.hasPrefix(conversation.title) ? nil : value
    }
    @ViewBuilder private var status: some View {
        // A task awaiting approval is still running; asking the person comes first.
        if conversation.head.status == .waitingConfirmation || conversation.activity.status == .waitingDataSharing {
            Text("待确认").foregroundStyle(Color(uiColor: theme.accent))
        } else if conversation.running {
            // The spinner must not change the title line's height.
            Text("进行中").padding(.leading, 18)
                .overlay(alignment: .leading) { ProgressView().controlSize(.mini) }
                .foregroundStyle(Color(uiColor: theme.secondary))
        } else {
            switch conversation.head.status {
            case .failed: Text("未完成").foregroundStyle(Color(uiColor: theme.destructive))
            case .interrupted: Text("已中断").foregroundStyle(Color(uiColor: theme.secondary))
            default: Text(AIRelativeTime.text(conversation.updated)).monospacedDigit()
                .foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
}

struct AICompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

enum AIRelativeTime {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month().day()) }
        return date.formatted(.dateTime.year().month().day())
    }
}

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
struct AIChatView: View {
    /// The tab page sits on the App canvas; the reading sheet keeps the panel
    /// surface shared by the other reading sheets. Both are the scope's roles.
    enum Placement { case page, sheet }
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let conversationID: String
    var placement: Placement = .page
    var taskObject: AITaskObject?
    /// A search match to open at, instead of the newest message.
    var anchor: AIConversationAnchor? = nil
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
    var body: some View {
        Group {
            if let conversation = ai.conversation(conversationID) { content(conversation) }
            else { ContentUnavailableView("对话不可用", systemImage: "exclamationmark.bubble") }
        }
        // Same roles as themedPage, with the placement's own background.
        .foregroundStyle(Color(uiColor: theme.ink)).tint(Color(uiColor: theme.accent))
        .background(Color(uiColor: background))
        .toolbarBackground(Color(uiColor: background), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .modifier(AIDataSharingPresentation(owner: conversationID))
        .sheet(item: $attachmentPreview) { AIReadingAttachmentPreview(attachment: $0, owner: conversationID) }
        .sheet(item: $pickingKind) { AIReadingObjectPicker(kind: $0, conversationID: conversationID) }
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
                        }, toggleProcessItem: toggle)
                        .background(row.turnID == highlightedTurn && highlightedTurn != nil ? Color(uiColor: theme.search) : .clear)
                        .environment(ai).environment(\.theme, theme).environment(\.dynamicTypeSize, typeSize)
                        .environment(\.colorScheme, theme.scheme)
                    }
                })
            }.id(conversationID)
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
        .onReceive(NotificationCenter.default.publisher(for: .aiActionFailed)) { notification in
            guard visible, let event = notification.object as? AIActionNotice, event.sessionID == conversationID else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
        .task { await ai.providers.refreshCatalogsIfNeeded() }
    }
}

/// Input shared by conversations and quick tasks: same draft, send modes and stop.
struct AIComposer: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let conversation: AIConversation
    var placement: AIChatView.Placement = .page
    var prompt: LocalizedStringKey = "向月读提问"
    var modelTarget: AIModelSelectionTarget
    /// Nil hides the reading-object menu.
    var pickingKind: Binding<AIReadingAttachment.Kind?>?
    @Binding var attachmentPreview: AIReadingAttachment?
    var inputFocused: FocusState<Bool>.Binding
    var onSend: () -> Void = {}
    var body: some View {
        let hasText = !conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            if !conversation.readingDraft.isEmpty {
                // Chip targets are 44pt tall; the drawn pill is inset, so rows need no extra gap.
                AIFlowLayout(spacing: 6, lineSpacing: 0) { attachmentChips }
            }
            TextField(prompt, text: Binding(get: { conversation.draft }, set: { ai.updateDraft(conversation.id, text: $0) }), prompt: Text(prompt).foregroundStyle(Color(uiColor: theme.secondary)), axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.plain).focused(inputFocused).accessibilityIdentifier("aiInput")
                .padding(.horizontal, 4).padding(.top, conversation.readingDraft.isEmpty ? 6 : 0)
            HStack(alignment: .center, spacing: 4) {
                if let pickingKind { Menu {
                    Button("书籍", systemImage: "book") { pickingKind.wrappedValue = .book }
                    Button("书签", systemImage: "bookmark") { pickingKind.wrappedValue = .bookmark }
                    Button("批注", systemImage: "highlighter") { pickingKind.wrappedValue = .annotation }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.medium))
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                }
                .accessibilityLabel("添加阅读对象").accessibilityIdentifier("addReadingAttachment") }
                Spacer(minLength: 0)
                AIModelPickerButton(target: modelTarget)
                if conversation.running && !hasText {
                    Button("停止", systemImage: "stop.fill") { ai.stop(conversation.id) }
                        .buttonStyle(AIComposerActionStyle()).accessibilityIdentifier("stopAI")
                } else {
                    Button("发送", systemImage: "arrow.up") { onSend(); ai.send(conversation.id) }
                        .buttonStyle(AIComposerActionStyle()).disabled(!hasText || conversation.submitting).accessibilityIdentifier("sendAI")
                }
                if conversation.running && hasText {
                    Menu {
                        Button("完成后发送") { onSend(); ai.send(conversation.id, mode: .followUp) }.disabled(conversation.submitting)
                        Button("停止", systemImage: "stop.fill") { ai.stop(conversation.id) }
                    } label: {
                        Image(systemName: "chevron.down").font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: theme.ink))
                            .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    }
                    .accessibilityLabel("发送方式")
                }
            }
        }
        .padding(.horizontal, LayoutTokens.compact).padding(.top, conversation.readingDraft.isEmpty ? LayoutTokens.compact : 2).padding(.bottom, 4)
        .background(Color(uiColor: placement == .page ? theme.surface : theme.raised), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
        .overlay {
            RoundedRectangle(cornerRadius: LayoutTokens.floatingRadius)
                .strokeBorder(Color(uiColor: inputFocused.wrappedValue ? theme.focus : theme.border), lineWidth: LayoutTokens.border)
        }
        .padding(.horizontal, LayoutTokens.content).padding(.bottom, LayoutTokens.compact)
        .disabled(conversation.submitting || conversation.deleting)
    }

    @ViewBuilder private var attachmentChips: some View {
        ForEach(conversation.readingDraft) { attachment in
            HStack(spacing: 0) {
                Button { attachmentPreview = attachment } label: {
                    Label(attachment.summary, systemImage: attachment.symbol)
                        .labelStyle(AICompactLabelStyle())
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .padding(.leading, LayoutTokens.compact)
                        .frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { ai.removeReadingAttachment(conversation.id, attachmentID: attachment.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("移除阅读附件")
            }
            .font(.footnote)
            // Full 44pt targets; only the pill inside them is drawn.
            .background { RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: theme.input)).padding(.vertical, 6) }
            .accessibilityElement(children: .contain)
        }
    }
}

/// The composer's primary action: accent fill with its paired foreground.
private struct AIComposerActionStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 32
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(uiColor: enabled ? theme.onAccent : theme.secondary))
            .frame(width: diameter, height: diameter)
            .background(Color(uiColor: enabled ? theme.accent : theme.selected), in: .circle)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
            .contentShape(Rectangle())
    }
}

/// Wraps short items onto shared lines; each item is capped to the row width.
struct AIFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + (lineSpacing ?? spacing) * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }
    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > width { size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
struct AIReadingAttachmentPreview: View {
    let attachment: AIReadingAttachment
    var owner: String? = nil
    @State private var image: UIImage?
    @State private var imageError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(attachment.summary, systemImage: attachment.symbol).font(.headline)
                    if attachment.kind == .image {
                        Text("用于图片修改")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("aiReferenceImagePreview") }
                        else if let imageError { Text(verbatim: imageError).foregroundStyle(Color(uiColor: theme.destructive)) }
                        else { ProgressView() }
                    }
                    if let chapter = attachment.chapter { Text(chapter).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let progress = attachment.progress { Text(progress, format: .percent.precision(.fractionLength(1))).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let text = attachment.excerpt, !text.isEmpty { Text(text).textSelection(.enabled) }
                    if let note = attachment.note, !note.isEmpty { Text(note).textSelection(.enabled) }
                    if let conflicts = attachment.conflictContents, !conflicts.isEmpty {
                        Text("批注有冲突").font(.headline)
                        ForEach(conflicts) { version in
                            VStack(alignment: .leading) {
                                if let value = version.content { Text(value.excerpt); Text(value.note) }
                                else { Text("已移除") }
                            }
                                .padding().background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 12))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.themedPage().navigationTitle("阅读附件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.medium, .large])
            .task(id: attachment.attachmentRef) {
                guard attachment.kind == .image else { return }
                do {
                    guard let owner, let ref = attachment.attachmentRef else { throw AIToolError("not_found") }
                    let bytes = try await AIImageStore.shared.read(owner: owner, ref: ref)
                    guard let decoded = AIImageThumbnail.make(bytes, pixels: 1600) else { throw AIToolError("invalid_response") }
                    image = decoded
                } catch { imageError = String(localized: "参考图片已不可用。") }
            }
    }
}

private struct AIReadingObjectPicker: View {
    @Environment(\.theme) private var theme
    let kind: AIReadingAttachment.Kind
    let conversationID: String
    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var books: [AIReadingAttachment] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loaded = false
    private var title: String { switch kind { case .bookmark: String(localized: "选择书签"); case .annotation: String(localized: "选择批注"); default: String(localized: "选择书籍") } }
    var body: some View {
        NavigationStack {
            let shown = books.filter { LibraryQueryRules.selectionMatches($0.title, query: query) }
            Group {
                if !loaded {
                    ProgressView("正在读取书籍…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView {
                        Label("暂时无法读取书籍", systemImage: "exclamationmark.circle")
                    } description: { Text(verbatim: error) } actions: { Button("重试") { Task { await load() } } }
                } else if books.isEmpty {
                    ContentUnavailableView("暂无书籍", systemImage: "books.vertical")
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List {
                        ForEach(shown) { book in
                            if kind == .book {
                                Button { Task { try? await ai.addReadingAttachment(conversationID, attachment: book); dismiss() } } label: { Label(book.title, systemImage: "book") }
                            } else {
                                NavigationLink { AIReadingMarkPicker(book: book, kind: kind) { attachment in
                                    Task { try? await ai.addReadingAttachment(conversationID, attachment: attachment); dismiss() }
                                } } label: { Label(book.title, systemImage: "book") }
                                .disabled(book.bookRef == nil)
                            }
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }
                }
            }.themedPage().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "搜索书籍")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .task { await load() }
        }
    }
    private func load() async {
        loaded = false; error = nil
        do {
            var result: [AIReadingAttachment] = []; var seen = Set<String>()
            for shelf in try await AppDataService.shared.shelves() {
                for row in try await AppDataService.shared.aiLibraryBooks(shelf.id) {
                    let bookRef = (row.metadata?.sha).flatMap { (try? parseSha256(value: $0)) != nil ? AIReadingTools.bookRef($0) : nil }
                    let fileRef = AIReadingTools.ref("f", row.id)
                    guard seen.insert(bookRef ?? fileRef).inserted else { continue }
                    result.append(.init(kind: .book, origin: "picker", bookRef: bookRef, fileRef: fileRef, title: row.title))
                }
            }
            books = result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}
private struct AIReadingMarkPicker: View {
    @Environment(\.theme) private var theme
    let book: AIReadingAttachment
    let kind: AIReadingAttachment.Kind
    let select: (AIReadingAttachment) -> Void
    @State private var items: [AIReadingAttachment] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var query = ""
    private var shown: [AIReadingAttachment] {
        items.filter { LibraryQueryRules.selectionMatches([$0.title, $0.excerpt ?? "", $0.note ?? ""].joined(separator: " "), query: query) }
    }
    var body: some View {
        Group {
            if !loaded {
                ProgressView("正在读取记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label("暂时无法读取记录", systemImage: "exclamationmark.circle")
                } description: { Text(verbatim: error) } actions: { Button("重试") { Task { await load() } } }
            } else if items.isEmpty {
                ContentUnavailableView("暂无记录", systemImage: kind == .bookmark ? "bookmark" : "highlighter")
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    ForEach(shown) { item in
                        Button { select(item) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.excerpt ?? item.title).lineLimit(3)
                                if item.conflictContents != nil { Text("批注有冲突").font(.caption) }
                                else if let note = item.note, !note.isEmpty { Text(note).font(.caption).lineLimit(2) }
                            }
                        }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
        }.themedPage().navigationTitle(book.title)
            .searchable(text: $query, prompt: "搜索记录")
            .task { await load() }
    }
    private func load() async {
        loaded = false; error = nil

        do {
            guard let ref = book.bookRef else { loaded = true; return }
            let groups = try await AppDataService.shared.aiMarks(sha: String(ref.dropFirst(2)))
            items = groups.compactMap { id, heads in
                let live = heads.filter { $0.content != nil }
                guard let first = live.first, let content = first.content, first.bookmark == (kind == .bookmark) else { return nil }
                var item = book; item.id = id; item.kind = kind
                item.objectRef = AIReadingTools.ref("mark", id); item.startUtf8 = content.start; item.endUtf8 = content.end
                item.excerpt = AnnotationReduction.conflicts(heads) ? String(localized: "批注有冲突") : content.excerpt
                item.note = AnnotationReduction.conflicts(heads) ? nil : content.note
                item.conflictContents = AnnotationReduction.conflicts(heads) ? heads.map { .init(id: AIReadingTools.ref("v", $0.id), content: $0.content) } : nil
                return item
            }.sorted { ($0.startUtf8 ?? 0, $0.id) < ($1.startUtf8 ?? 0, $1.id) }
        } catch { self.error = ReaderMessages.error(error) }
        loaded = true
    }
}

extension AIReadingAttachment.Kind: Identifiable { var id: String { rawValue } }

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
