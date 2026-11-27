import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

private struct AIConnectionRoute: Hashable {
    let id: String
    var startsLogin = false
}

public struct AISettingsView: View {
    public init() {}
    @State private var adding = false
    @State private var connectionRoute: AIConnectionRoute?
    @Environment(\.dismiss) private var dismiss
    @Environment(AIService.self) private var ai
    public var body: some View {
        AISettingsPage(
            connections: ai.providers.connections, error: ai.providers.error,
            loginInProgress: ai.providers.loginConnectionID != nil, state: ai.providers.connectionState,
            enabledCount: { connection in connection.models.filter { ai.providers.isEnabled(modelID: $0.id, in: connection) }.count },
            add: { adding = true }, manage: { connectionRoute = .init(id: $0, startsLogin: $1) },
            refreshModels: { await ai.providers.refreshModels($0) }
        ) {
            AIModelPickerButton(target: .defaults, title: "对话")
            ForEach(AIModelPurpose.allCases, id: \.self) { purpose in
                AIModelPickerButton(purpose: purpose, title: LocalizedStringKey(purpose.title))
            }
        }
            .aiAddConnectionFlow(isPresented: $adding)
            .navigationDestination(item: $connectionRoute) { value in
                AIConnectionView(connectionID: value.id, startsLogin: value.startsLogin)
            }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available { adding = false; connectionRoute = nil; dismiss() }
            }
            .task { await ai.providers.refreshCatalogsIfNeeded() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { AIUsageHelpView() } label: { Image(systemName: "questionmark.circle") }.toolbarGlyph().accessibilityLabel("AI 使用帮助") } }
    }
}

/// Every entry adds a connection the same way: the add sheet, then the new
/// connection's own page in the current navigation stack. Back returns to the entry.
private struct AIAddConnectionFlow: ViewModifier {
    @Environment(AIService.self) private var ai
    @Binding var isPresented: Bool
    @State private var createdConnectionID: String?
    @State private var destinationConnectionID: String?
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, onDismiss: {
                destinationConnectionID = createdConnectionID; createdConnectionID = nil
            }) { AIAddConnectionView(createdConnectionID: $createdConnectionID) }
            .navigationDestination(item: $destinationConnectionID) { AIConnectionView(connectionID: $0) }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available { isPresented = false; createdConnectionID = nil; destinationConnectionID = nil }
            }
    }
}
extension View {
    func aiAddConnectionFlow(isPresented: Binding<Bool>) -> some View { modifier(AIAddConnectionFlow(isPresented: isPresented)) }
}
private struct AIUsageHelpView: View {
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("问题与相关阅读上下文发送给所选服务，使用该连接的账户权限与额度。月读不提供额度，也不自动切换计费连接。")
                Text("订阅授权在服务商页面完成，API Key 保存在本机钥匙串中。")
            }.padding([.horizontal, .top], 20).padding(.bottom).frame(maxWidth: .infinity, alignment: .leading)
        }.themedPage().navigationTitle("AI 使用帮助").navigationBarTitleDisplayMode(.inline)
    }
}
private struct AIAddConnectionView: View {
    @Binding var createdConnectionID: String?
    @State private var usesAPIKey = false
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var customName = ""
    @State private var endpoint = ""
    @State private var wire = AIWireProtocol.chat
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("认证方式", selection: $usesAPIKey) {
                        Text("账户登录").tag(false)
                        Text("API Key").tag(true)
                    }.pickerStyle(.segmented).accessibilityIdentifier("aiAuthenticationMethod")
                }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                Section {
                    ForEach(AIProviderPreset.all.filter { ($0.auth == .apiKey) == usesAPIKey && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }, id: \.identity) { preset in
                        Button { createdConnectionID = ai.providers.addConnection(preset.connection()); dismiss() } label: {
                            HStack { AIProviderIcon(providerID: preset.id, accent: theme.accent); Text(verbatim: preset.name).foregroundStyle(Color(uiColor: theme.ink)); Spacer() }
                        }
                    }
                }.listRowBackground(Color(uiColor: theme.surface))
                if usesAPIKey { Section("自定义连接") {
                    TextField("名称", text: $customName)
                    TextField("https://…", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Picker("协议", selection: $wire) {
                        Text("OpenAI Responses").tag(AIWireProtocol.responses)
                        Text("OpenAI Chat Completions").tag(AIWireProtocol.chat)
                        Text("Anthropic Messages").tag(AIWireProtocol.anthropic)
                        Text("Google Gemini").tag(AIWireProtocol.gemini)
                    }
                    Button {
                        let value = AIConnection(name: customName, billing: .usage,
                            baseURL: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                            providerID: "custom", providerName: customName, wireProtocol: wire, authMethod: .apiKey)
                        createdConnectionID = ai.providers.addConnection(value); dismiss()
                    } label: { Text("添加连接").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("addCustomAIConnection")
                        .disabled(customName.isEmpty || URL(string: endpoint)?.scheme != "https" || URL(string: endpoint)?.host == nil)
                }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
            }.themedPage().searchable(text: $query).navigationTitle("添加连接")
                .toolbar { ToolbarItem(placement: .cancellationAction) { SystemToolbarButton("取消", role: .cancel) { dismiss() } } }
        }
    }
}
