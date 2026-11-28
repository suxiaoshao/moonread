import MoonreadDesign
import SwiftUI

public struct AIConversationListItem: Identifiable {
    public let id: String
    let title: String
    let preview: String
    let updated: Date
    let status: AIAgentStatus
    let awaitingConfirmation: Bool
    let running: Bool

    public init(id: String, title: String, preview: String, updated: Date,
                status: AIAgentStatus, awaitingConfirmation: Bool, running: Bool) {
        self.id = id
        self.title = title
        self.preview = preview
        self.updated = updated
        self.status = status
        self.awaitingConfirmation = awaitingConfirmation
        self.running = running
    }
}

public struct AIConversationList: View {
    @Environment(\.theme) private var theme
    let conversations: [AIConversationListItem]
    let error: String?
    let loaded: Bool
    let reload: () async -> Void
    let delete: (String) -> Void
    let openSettings: () -> Void
    let openDraft: () -> Void

    public init(conversations: [AIConversationListItem], error: String?, loaded: Bool,
                reload: @escaping () async -> Void, delete: @escaping (String) -> Void,
                openSettings: @escaping () -> Void, openDraft: @escaping () -> Void) {
        self.conversations = conversations
        self.error = error
        self.loaded = loaded
        self.reload = reload
        self.delete = delete
        self.openSettings = openSettings
        self.openDraft = openDraft
    }

    public var body: some View {
        List {
            if !conversations.isEmpty, let error = error {
                HStack(spacing: LayoutTokens.compact) {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                        .foregroundStyle(Color(uiColor: theme.destructive))
                    Spacer(minLength: 0)
                    if !loaded { Button("重试") { Task { await reload() } }.font(.footnote) }
                }.listRowBackground(Color(uiColor: theme.canvas))
            }
            ForEach(conversations) { conversation in
                NavigationLink(value: conversation.id) { AIConversationRow(conversation: conversation) }
                    .listRowBackground(Color(uiColor: theme.canvas))
                    .listRowSeparatorTint(Color(uiColor: theme.separator))
                    .accessibilityIdentifier("aiConversation-\(conversation.id)")
            }.onDelete { offsets in for id in offsets.map({ conversations[$0].id }) { delete(id) } }
        }.listStyle(.plain).themedPage().navigationTitle("对话")
            .overlay {
                if conversations.isEmpty {
                    if let error = error {
                        ContentUnavailableView {
                            Label("暂时无法读取对话", systemImage: "exclamationmark.bubble")
                        } description: { Text(error).foregroundStyle(Color(uiColor: theme.secondary)) } actions: {
                            Button("重试") { Task { await reload() } }.buttonStyle(ThemedProminentButtonStyle())
                        }.accessibilityIdentifier("aiConversationLoadError")
                    } else if loaded {
                        VStack(spacing: LayoutTokens.control) {
                            MoonView(size: 56)
                            Text("还没有对话").foregroundStyle(Color(uiColor: theme.secondary))
                        }.allowsHitTesting(false)
                    } else { LoadingActivity(fullPage: true, waitingLabel: "正在读取对话") }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { openSettings() } label: { Label("AI 助手", systemImage: "slider.horizontal.3") }.toolbarGlyph().accessibilityIdentifier("aiAssistantSettings") }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("新对话", systemImage: "square.and.pencil") { openDraft() }.toolbarGlyph().accessibilityIdentifier("newAIConversation")
                }
            }
    }
}

/// The title and status share one line. A distinct preview may use a second line.
private struct AIConversationRow: View {
    let conversation: AIConversationListItem
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
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
    private var preview: String? {
        let value = conversation.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix(conversation.title) ? nil : value
    }
    @ViewBuilder private var status: some View {
        // A task awaiting approval is still running; asking the person comes first.
        if conversation.awaitingConfirmation {
            Text("待确认").foregroundStyle(Color(uiColor: theme.accent))
        } else if conversation.running {
            // The spinner must not change the title line's height.
            Text("进行中").padding(.leading, 18)
                .overlay(alignment: .leading) { ProgressView().controlSize(.mini) }
                .foregroundStyle(Color(uiColor: theme.secondary))
        } else {
            switch conversation.status {
            case .failed: Text("未完成").foregroundStyle(Color(uiColor: theme.destructive))
            case .interrupted: Text("已中断").foregroundStyle(Color(uiColor: theme.secondary))
            default: Text(AIRelativeTime.text(conversation.updated)).monospacedDigit()
                .foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
    }
}

public struct AICompactLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon.imageScale(.small); configuration.title }
    }
}

public enum AIRelativeTime {
    public static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        if calendar.isDateInYesterday(date) { return String(localized: "昨天") }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month().day()) }
        return date.formatted(.dateTime.year().month().day())
    }
}
