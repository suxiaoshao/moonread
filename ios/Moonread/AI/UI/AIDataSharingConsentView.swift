import SwiftUI

struct AIDataSharingConsentView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .body) private var scopeIconWidth: CGFloat = 22
    let request: AIDataSharingConsent.Request
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.content) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("接收方：\(request.service + " · " + request.destination.host)").font(.headline)
                        Text(verbatim: request.destination.endpoint).font(.caption)
                            .foregroundStyle(Color(uiColor: theme.secondary)).textSelection(.enabled)
                        Text("用途：\(request.purpose)")
                        if request.gateway { Text("自定义端点或网关可能将请求转发给其模型服务。") }
                    }
                    Text("本次及本连接后续同范围请求可能发送：").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AIDataSharingConsent.Scope.allCases.filter { request.scopes.contains($0) }, id: \.self) { scope in
                            Label {
                                Text(verbatim: scope.description)
                            } icon: {
                                Image(systemName: symbol(for: scope)).frame(width: scopeIconWidth)
                                    .foregroundStyle(Color(uiColor: theme.secondary))
                            }.accessibilityElement(children: .combine)
                        }
                    }
                    Text("服务可能按其政策保存和处理这些内容，并使用该账户的额度。你可以随时在 AI 设置中撤销许可；已发送的数据无法追回。拒绝不会影响阅读。")
                    VStack(alignment: .leading, spacing: 8) {
                        Link(destination: AppLinks.privacy()) { Label("隐私政策", systemImage: "arrow.up.right") }
                        if let policy = AppLinks.providerPrivacy(request.destination.provider) {
                            Link(destination: policy) { Label("服务商隐私政策", systemImage: "arrow.up.right") }
                        }
                    }.foregroundStyle(Color(uiColor: theme.accent)).tint(Color(uiColor: theme.accent))
                }.padding(LayoutTokens.page).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
            }.themedPage()
                .safeAreaInset(edge: .bottom, spacing: 0) { actions }
                .navigationTitle("数据共享许可").navigationBarTitleDisplayMode(.inline)
        }.accessibilityIdentifier("aiDataSharingConsent")
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { ai.sharing.answer(request.id, approved: true) } label: {
                Text("同意并发送").frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
            }.buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("approveAIDataSharing")
            Button(role: .cancel) { ai.sharing.answer(request.id, approved: false) } label: {
                Text("暂不发送").frame(maxWidth: .infinity, minHeight: LayoutTokens.hit)
            }.buttonStyle(ThemedSecondaryButtonStyle()).accessibilityIdentifier("declineAIDataSharing")
        }.controlSize(.large).frame(maxWidth: 640).padding(LayoutTokens.page).frame(maxWidth: .infinity)
            .background(Color(uiColor: theme.surface))
            .overlay(alignment: .top) { ThemedDivider() }
    }

    private func symbol(for scope: AIDataSharingConsent.Scope) -> String {
        switch scope {
        case .conversation: "text.bubble"
        case .reading: "book"
        case .statistics: "chart.bar"
        case .images: "photo"
        case .webSources: "globe"
        }
    }
}

/// Presented by the currently visible chat/task sheet, never by the root window.
struct AIDataSharingPresentation: ViewModifier {
    @Environment(AIService.self) private var ai
    let owner: String
    @State private var presentedID: UUID?
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { ai.sharing.requests.first { $0.owner == owner } }, set: { _ in }), onDismiss: {
            if let id = presentedID { ai.sharing.answer(id, approved: false) }
            presentedID = nil
        }) { request in
            AIDataSharingConsentView(request: request).onAppear { presentedID = request.id }
        }.onDisappear { ai.sharing.cancel(owner: owner) }
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-ai-sharing") {
                let connection = AIConnection(id: "sharing-fixture", name: "Fixture", billing: .usage, baseURL: "https://example.com/v1", providerID: "custom", providerName: "Example AI", wireProtocol: .chat, authMethod: .apiKey)
                ai.conversation(owner)?.draft = "Synthetic sharing draft"
                // Render the actual waiting flow without credentials or content transport.
                try? await ai.sharing.authorize(connection, owner: owner, purpose: String(localized: "阅读问答"), scopes: Set(AIDataSharingConsent.Scope.allCases)) { connection }
            }
            #endif
        }
    }
}
