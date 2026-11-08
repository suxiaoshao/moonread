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
            List {
                if !ai.conversations.isEmpty, let error = ai.error {
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
                    if ai.conversations.isEmpty {
                        if let error = ai.error {
                            ContentUnavailableView {
                                Label("暂时无法读取对话", systemImage: "exclamationmark.bubble")
                            } description: { Text(error).foregroundStyle(Color(uiColor: theme.secondary)) } actions: {
                                Button("重试") { Task { await ai.load() } }.buttonStyle(ThemedProminentButtonStyle())
                            }.accessibilityIdentifier("aiConversationLoadError")
                        } else if ai.loaded {
                            VStack(spacing: LayoutTokens.control) {
                                MoonView(size: 56)
                                Text("还没有对话").foregroundStyle(Color(uiColor: theme.secondary))
                            }.allowsHitTesting(false)
                        } else { LoadingActivity(fullPage: true, waitingLabel: "正在读取对话") }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { library.openSettings(target: .ai) } label: { Label("AI 助手", systemImage: "slider.horizontal.3") }.toolbarGlyph().accessibilityIdentifier("aiAssistantSettings") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("新对话", systemImage: "square.and.pencil") { Task { if let value = await ai.openDraft() { path.append(value.id) } } }.toolbarGlyph().accessibilityIdentifier("newAIConversation")
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
