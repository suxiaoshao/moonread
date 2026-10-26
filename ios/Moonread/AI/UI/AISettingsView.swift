import SwiftUI

private struct AIConnectionRoute: Hashable {
    let id: String
    var startsLogin = false
}
private enum AISettingsRoute: Hashable {
    case conversation, tool(AIModelPurpose), connection(AIConnectionRoute)
}

struct AISettingsView: View {
    @State private var adding = false
    @State private var route: AISettingsRoute?
    @Environment(\.dismiss) private var dismiss
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                Button { route = .conversation } label: {
                    AISettingsValueLabel(title: "对话", value: conversationLabel)
                }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPanel")
                ForEach(AIModelPurpose.allCases, id: \.self) { purpose in
                    Button { route = .tool(purpose) } label: {
                        AISettingsValueLabel(title: LocalizedStringKey(purpose.title), value: purposeLabel(purpose))
                    }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPanel-" + purpose.rawValue)
                }
            } header: { Text("默认使用") } footer: {
                Text("按用途选择默认模型，具体对话仍可单独更换。")
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                ForEach(ai.providers.connections) { connection in
                    AISettingsConnectionRow(connection: connection,
                        manage: { route = .connection(.init(id: connection.id)) },
                        login: { route = .connection(.init(id: connection.id, startsLogin: true)) })
                }
                Button("添加连接", systemImage: "plus") { adding = true }
                    .foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("addAIConnection")
            } header: { Text("连接") } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if ai.providers.connections.isEmpty { Text("添加一个 AI 连接后，选择用于对话和工具的模型。") }
                    if let error = ai.providers.error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    }
                    Text("登录、模型发现和公共模型目录刷新只用于连接与能力信息，不发送小说或聊天内容。内容共享会在发送前另行询问。")
                }.foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }.themedPage().navigationTitle("AI 助手")
            .aiAddConnectionFlow(isPresented: $adding)
            .navigationDestination(item: $route) { destination in
                switch destination {
                case .conversation:
                    AIModelPicker(destination: .target(.defaults), detent: .constant(.large), embedded: true)
                case .tool(let purpose): AIToolServiceView(purpose: purpose)
                case .connection(let value): AIConnectionView(connectionID: value.id, startsLogin: value.startsLogin)
                }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { adding = false; route = nil; dismiss() } }
            .task { await ai.providers.refreshCatalogsIfNeeded() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { AIUsageHelpView() } label: { Image(systemName: "questionmark.circle") }.toolbarGlyph().accessibilityLabel("AI 使用帮助") } }
    }
    private var conversationLabel: String {
        guard let value = ai.modelSelection(for: .defaults), let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID) else { return String(localized: "未设置") }
        return model.name + (value.thinking.map { " · " + AIThinkingLabel.label($0) } ?? "")
    }
    private func purposeLabel(_ purpose: AIModelPurpose) -> String {
        guard let selection = ai.providers.purposeSelection(purpose),
              let connection = ai.providers.connections.first(where: { $0.id == selection.connectionID }) else { return String(localized: "未设置") }
        return connection.models.first { $0.id == selection.modelID }?.name ?? selection.modelID
    }
}

/// Plain task rows keep the whole control tappable without row-level navigation
/// being shared between the three independent purposes.
private struct AISettingsValueLabel: View {
    let title: LocalizedStringKey
    let value: String
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(Color(uiColor: theme.ink))
            Spacer(minLength: 8)
            Text(verbatim: value).font(.subheadline).multilineTextAlignment(.trailing)
                .foregroundStyle(Color(uiColor: theme.secondary))
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
    }
}

/// Connection state and model enablement retain their existing service owner.
private struct AISettingsConnectionRow: View {
    let connection: AIConnection
    let manage: () -> Void
    let login: () -> Void
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    private var needsLogin: Bool {
        switch ai.providers.connectionState(connection) {
        case .signedOut, .expired, .loginFailed, .needsLogin, .planPermissionRequired: true
        default: false
        }
    }
    private var catalogFailed: Bool { if case .modelsFailed = ai.providers.connectionState(connection) { true } else { false } }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: manage) {
                HStack(spacing: 12) {
                    AIProviderIcon(providerID: connection.catalogID).frame(width: 32, height: 32)
                        .background(Color(uiColor: theme.input), in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(connection.name).foregroundStyle(Color(uiColor: theme.ink))
                        status.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                    Spacer(minLength: 0)
                    if !needsLogin && !catalogFailed {
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("manageAIConnection-" + connection.id)
            if needsLogin {
                Button("登录", action: login).buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent))
                    .frame(minWidth: 44, minHeight: 44).disabled(ai.providers.loginConnectionID != nil)
                    .accessibilityIdentifier("loginAIConnection-" + connection.id)
            } else if catalogFailed {
                Button("重试") { Task { await ai.providers.refreshModels(connection.id) } }
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent)).frame(minWidth: 44, minHeight: 44)
            }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private var status: some View {
        switch ai.providers.connectionState(connection) {
        case .connected:
            HStack(spacing: 4) {
                Text(connection.authMethod == .apiKey ? "已配置" : "已连接")
                Text("·")
                if connection.modelsChecked != nil || !connection.models.isEmpty {
                    Text("\(connection.models.filter { ai.providers.isEnabled(modelID: $0.id, in: connection) }.count) 个模型")
                } else { Text("模型目录尚未加载") }
            }
        case .signedOut: Label("未登录", systemImage: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.warning))
        case .expired: Label("授权已过期", systemImage: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.warning))
        case .needsLogin: Label("请重新登录并完成授权。", systemImage: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.warning))
        case .planPermissionRequired: Label("你没有允许月读使用 ChatGPT 套餐", systemImage: "exclamationmark.triangle").foregroundStyle(Color(uiColor: theme.warning))
        case .loginFailed(let message), .modelsFailed(let message): Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.warning))
        case .authorizing, .browser: Label { Text("等待授权") } icon: { ProgressView() }
        case .loadingModels: Label { Text("正在加载模型") } icon: { ProgressView() }
        }
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
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
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
                            HStack { AIProviderIcon(providerID: preset.id); Text(verbatim: preset.name).foregroundStyle(Color(uiColor: theme.ink)); Spacer() }
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
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

/// Tool services select an account first; the model belongs to that service's wire route.
struct AIToolServiceView: View {
    let purpose: AIModelPurpose
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var connectionID: String?
    @State private var modelID: String?
    @State private var initialized = false
    @State private var saveFailed = false
    @State private var adding = false
    @State private var connectionRoute: AIConnectionRoute?
    private var connections: [AIConnection] { ai.providers.connections.filter { AINativeCapabilities.supportsConnection($0) && !(purpose == .image && $0.authMethod == .chatGPT) } }
    private var connection: AIConnection? { connections.first { $0.id == connectionID } }
    private var models: [AIModelOption] {
        guard let connection else { return [] }
        return connection.models.filter { AINativeCapabilities.supports(purpose, connection: connection, model: $0) }
    }
    private var valid: Bool { connectionID == nil || models.contains { $0.id == modelID } }
    private var hostedImage: Bool {
        guard purpose == .image, let connection, let model = models.first(where: { $0.id == modelID }) else { return false }
        return AINativeCapabilities.route(purpose, connection: connection, model: model) == .openAIHosted
    }
    var body: some View {
        Group {
            if connections.isEmpty {
                ContentUnavailableView {
                    Label("还没有支持此工具的连接", systemImage: "sparkles")
                } actions: {
                    Button("添加连接", systemImage: "plus") { adding = true }.accessibilityIdentifier("addAIToolConnection")
                }
            } else {
                List {
                    Section {
                        Picker("服务", selection: Binding(get: { connectionID }, set: { connectionID = $0; modelID = nil; saveFailed = false })) {
                            Text("不使用").tag(String?.none)
                            ForEach(connections) { value in Text(value.name).tag(Optional(value.id)) }
                        }.pickerStyle(.menu).accessibilityIdentifier("aiPurposeConnection")
                        if let connection {
                            AISettingsConnectionRow(connection: connection,
                                manage: { connectionRoute = .init(id: connection.id) },
                                login: { connectionRoute = .init(id: connection.id, startsLogin: true) })
                        }
                    } header: { Text("服务") } footer: {
                        if saveFailed || (initialized && connectionID != nil && !valid) {
                            Label("模型目录已变化，请重新选择。", systemImage: "exclamationmark.circle")
                                .foregroundStyle(Color(uiColor: theme.destructive))
                        }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    if let connection {
                        Section {
                            if models.isEmpty { Text("暂无可用模型").foregroundStyle(Color(uiColor: theme.secondary)) }
                            else {
                                NavigationLink {
                                    AIPurposeModelList(purpose: purpose, connectionID: connection.id,
                                        current: ai.providers.purposeSelection(purpose).flatMap { $0.connectionID == connection.id ? $0.modelID : nil }, selection: $modelID)
                                } label: {
                                    LabeledContent("模型") {
                                        Text(verbatim: models.first { $0.id == modelID }?.name ?? String(localized: "选择模型"))
                                            .foregroundStyle(Color(uiColor: theme.secondary))
                                    }
                                }.accessibilityIdentifier("openAIPurposeModels")
                            }
                        } header: { Text(purpose == .search ? "搜索模型" : "图片模型") } footer: {
                            if hostedImage { Text("绘图模型由服务决定。").foregroundStyle(Color(uiColor: theme.secondary)) }
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }
                }
            }
        }.themedPage().navigationTitle(purpose.title).navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $connectionRoute) { AIConnectionView(connectionID: $0.id, startsLogin: $0.startsLogin) }
            .aiAddConnectionFlow(isPresented: $adding)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let selection = connectionID.flatMap { id in modelID.map { AIPurposeSelection(connectionID: id, modelID: $0) } }
                        saveFailed = !ai.providers.setPurpose(purpose, selection: selection)
                        if !saveFailed { dismiss() }
                    }.disabled(!valid)
                }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { adding = false; dismiss() } }
            .task {
                guard !initialized else { return }
                connectionID = ai.providers.purposeSelection(purpose)?.connectionID
                initialized = true
                modelID = ai.providers.purposeSelection(purpose)?.modelID
            }
    }
}

/// A single connection's purpose-eligible models, using the shared search and enablement rules.
private struct AIPurposeModelList: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let purpose: AIModelPurpose
    let connectionID: String
    let current: String?
    @Binding var selection: String?
    @State private var query = ""
    // Read live so returning from model management shows re-enabled models at once.
    private var connection: AIConnection? { ai.providers.connections.first { $0.id == connectionID } }
    private var eligible: [AIModelOption] {
        guard let connection else { return [] }
        return connection.models.filter { AINativeCapabilities.supports(purpose, connection: connection, model: $0) }
    }
    private var offered: [AIModelOption] {
        guard let connection else { return [] }
        return AIModelSearch.offered(eligible, in: connection, keeping: current, ai.providers)
    }
    var body: some View {
        Group {
            if let connection { list(connection) }
            else {
                ContentUnavailableView {
                    Label("连接不可用", systemImage: "sparkles")
                } actions: { Button("返回") { dismiss() }.buttonStyle(ThemedSecondaryButtonStyle()) }
            }
        }.themedPage().navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
    }
    private func list(_ connection: AIConnection) -> some View {
        let shown = AIModelSearch.filter(offered, query: query, connection: connection, ai.providers)
        return Group {
            if eligible.isEmpty {
                ContentUnavailableView {
                    Label("还没有可用模型", systemImage: "sparkles")
                } description: { Text("先连接一个 AI 账户并加载模型。") } actions: {
                    NavigationLink("管理模型") { AIConnectionView(connectionID: connection.id, startsEditingModels: true) }
                }
            } else if offered.isEmpty {
                ContentUnavailableView {
                    Label("没有启用的模型", systemImage: "sparkles")
                } actions: {
                    NavigationLink("管理模型") { AIConnectionView(connectionID: connection.id, startsEditingModels: true) }
                }
            } else if shown.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的模型", systemImage: "magnifyingglass")
                } description: { Text("试试其他搜索词。") } actions: { Button("清除搜索") { query = "" } }
            } else {
                List {
                    let duplicates = AIModelSearch.duplicateNames(offered)
                    Section {
                        ForEach(shown) { model in
                            Button { selection = model.id; dismiss() } label: {
                                HStack {
                                    AIModelRowLabel(model: model, duplicate: duplicates.contains(model.name),
                                                    disabled: !ai.providers.isEnabled(modelID: model.id, in: connection))
                                    if selection == model.id {
                                        Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent))
                                    }
                                }.contentShape(Rectangle())
                            }.foregroundStyle(Color(uiColor: theme.ink))
                                .accessibilityAddTraits(selection == model.id ? .isSelected : [])
                                .accessibilityIdentifier("aiPurposeModel-\(model.id)")
                        }
                    } header: { AIConnectionHeader(connection: connection) }
                        .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
        }.themedPage().navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索"))
    }
}
