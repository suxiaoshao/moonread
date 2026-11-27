import MoonreadDesign
import SwiftUI

public enum AIChatPlacement { case page, sheet }

public struct AIChatSurface<Content: View>: View {
    @Environment(\.theme) private var theme
    let placement: AIChatPlacement
    let available: Bool
    let content: () -> Content

    public init(placement: AIChatPlacement, available: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.placement = placement
        self.available = available
        self.content = content
    }

    public var body: some View { chatWithNavigation }

    private var background: UIColor { placement == .page ? theme.canvas : theme.surface }
    private var chat: some View {
        Group {
            if available { content() }
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

}

/// The message viewport stays fixed while the queue and composer float above it.
public struct AIChatLayout<Messages: View, Composer: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queueHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    let isEmpty: Bool
    let atBottom: Bool
    let queue: [AIAgentInput]
    let showLatest: () async -> Void
    let cancelQueued: (String) -> Void
    let messages: (CGFloat) -> Messages
    let composer: () -> Composer

    public init(
        isEmpty: Bool, atBottom: Bool, queue: [AIAgentInput], showLatest: @escaping () async -> Void,
        cancelQueued: @escaping (String) -> Void, @ViewBuilder messages: @escaping (CGFloat) -> Messages,
        @ViewBuilder composer: @escaping () -> Composer
    ) {
        self.isEmpty = isEmpty
        self.atBottom = atBottom
        self.queue = queue
        self.showLatest = showLatest
        self.cancelQueued = cancelQueued
        self.messages = messages
        self.composer = composer
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            messages(composerHeight + (queue.isEmpty || queueHeight == 0 ? 0 : queueHeight + LayoutTokens.compact))
            if isEmpty {
                VStack(spacing: LayoutTokens.control) {
                    MoonView(size: 40)
                    Text("想聊点什么？").foregroundStyle(Color(uiColor: theme.secondary))
                }.padding(.bottom, composerHeight + LayoutTokens.section * 2).allowsHitTesting(false)
            }
            VStack(spacing: LayoutTokens.compact) {
                VStack(spacing: LayoutTokens.compact) {
                    if !atBottom {
                        Button("回到底部", systemImage: "arrow.down") {
                            Task { await showLatest() }
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .foregroundStyle(Color(uiColor: theme.ink))
                        .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
                        .background(Color(uiColor: theme.raised), in: .circle)
                        .overlay { Circle().strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
                        .accessibilityIdentifier("aiScrollToBottom")
                    }
                    if !queue.isEmpty {
                        AIQueuedStatus(queue: queue) { cancelQueued($0) }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { queueHeight = $0 }
                            .opacity(queueHeight > 0 ? 1 : 0)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: queueHeight > 0)
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: queue.isEmpty)
                composer()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .onChange(of: queue.isEmpty) { _, empty in
            if empty { queueHeight = 0 }
        }
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
