import SwiftUI

struct AISettingsView: View {
    @State private var adding = false
    @State private var purposeRoute: AIModelPurpose?
    @Environment(\.dismiss) private var dismiss
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("默认使用").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("对话").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        AIModelPickerButton(target: .defaults, compact: true)
                            .padding(.horizontal, 10).background(Color(uiColor: theme.selected), in: .capsule)
                    }
                    ForEach(AIModelPurpose.allCases, id: \.self) { purpose in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(purpose.title).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            Button { purposeRoute = purpose } label: {
                                Text(verbatim: purposeLabel(purpose)).font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Color(uiColor: theme.selected), in: .capsule)
                            }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPanel-" + purpose.rawValue)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                if ai.providers.connections.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("还没有连接").font(.headline)
                        Text("添加一个 AI 连接后，选择用于对话和工具的模型。")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                } else {
                    ForEach(ai.providers.connections) { connection in
                        AISettingsConnectionCard(connection: connection)
                    }
                }
                Button("添加连接", systemImage: "plus") { adding = true }
                    .buttonStyle(ThemedProminentButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).accessibilityIdentifier("addAIConnection")
                if let error = ai.providers.error {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote)
                        .foregroundStyle(Color(uiColor: theme.destructive))
                }
            } header: { Text("连接") } footer: {
                Text("登录、模型发现和公共模型目录刷新只用于连接与能力信息，不发送小说或聊天内容。内容共享会在发送前另行询问。")
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
        }.themedPage().navigationTitle("AI 助手")
            .aiAddConnectionFlow(isPresented: $adding)
            .navigationDestination(item: $purposeRoute) { AIToolServiceView(purpose: $0) }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { adding = false; purposeRoute = nil; dismiss() } }
            .task { await ai.providers.refreshCatalogsIfNeeded() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { AIUsageHelpView() } label: { Image(systemName: "questionmark.circle") }.toolbarGlyph().accessibilityLabel("AI 使用帮助") } }
    }
    private func purposeLabel(_ purpose: AIModelPurpose) -> String {
        guard let selection = ai.providers.purposeSelection(purpose),
              let connection = ai.providers.connections.first(where: { $0.id == selection.connectionID }) else { return String(localized: "未设置") }
        let model = connection.models.first { $0.id == selection.modelID }?.name ?? selection.modelID
        return model + " · " + connection.name
    }
}

/// Configuration summary, shared by the settings home and purpose draft. State
/// and model enablement continue to come from AIConnectionService.
private struct AISettingsConnectionCard: View {
    let connection: AIConnection
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AIProviderIcon(providerID: connection.catalogID)
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.name).font(.headline)
                    Text(verbatim: connection.serviceName).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }
            }
            status.font(.subheadline)
            if connection.modelsChecked != nil || !connection.models.isEmpty {
                Text("已启用 \(connection.models.filter { ai.providers.isEnabled(modelID: $0.id, in: connection) }.count) 个模型")
                    .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
            } else { Text("模型目录尚未加载").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
            if case .modelsFailed = ai.providers.connectionState(connection) {
                Button("重新加载模型") { Task { await ai.providers.refreshModels(connection.id) } }
                    .buttonStyle(ThemedSecondaryButtonStyle())
                NavigationLink("管理连接") { AIConnectionView(connectionID: connection.id) }.font(.subheadline)
            } else {
                NavigationLink(ai.providers.isLoggedIn(connection) ? "管理连接" : "连接账户") { AIConnectionView(connectionID: connection.id) }
                    .buttonStyle(ThemedSecondaryButtonStyle())
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
            .accessibilityIdentifier("aiConnectionCard-" + connection.id)
    }
    @ViewBuilder private var status: some View {
        switch ai.providers.connectionState(connection) {
        case .signedOut: Text("尚未连接").foregroundStyle(Color(uiColor: theme.secondary))
        case .connected: Text(connection.authMethod == .apiKey ? "已配置" : "已连接").foregroundStyle(Color(uiColor: theme.accent))
        case .authorizing, .browser: Label { Text("等待授权") } icon: { ProgressView() }
        case .loadingModels: Label { Text("正在加载模型") } icon: { ProgressView() }
        case .modelsFailed(let message), .loginFailed(let message):
            Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
        case .expired: Text("授权已过期").foregroundStyle(Color(uiColor: theme.secondary))
        case .needsLogin: Text("请重新登录并完成授权。").foregroundStyle(Color(uiColor: theme.secondary))
        case .planPermissionRequired: Text("你没有允许月读使用 ChatGPT 套餐").foregroundStyle(Color(uiColor: theme.secondary))
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if connections.isEmpty {
                    ContentUnavailableView {
                        Label("还没有支持此工具的连接", systemImage: "sparkles")
                    } actions: {
                        Button("添加连接", systemImage: "plus") { adding = true }
                            .buttonStyle(ThemedProminentButtonStyle()).accessibilityIdentifier("addAIToolConnection")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("服务").font(.headline)
                        Picker("服务", selection: Binding(get: { connectionID }, set: { connectionID = $0; modelID = nil; saveFailed = false })) {
                            Text("不使用").tag(String?.none)
                            ForEach(connections) { value in Text(value.name).tag(Optional(value.id)) }
                        }.pickerStyle(.menu).accessibilityIdentifier("aiPurposeConnection")
                        if let connection {
                            AISettingsConnectionCard(connection: connection)
                            ThemedDivider()
                            if models.isEmpty {
                                Text("暂无可用模型").foregroundStyle(Color(uiColor: theme.secondary))
                            } else {
                                NavigationLink {
                                    AIPurposeModelList(purpose: purpose, connectionID: connection.id,
                                        current: ai.providers.purposeSelection(purpose).flatMap { $0.connectionID == connection.id ? $0.modelID : nil }, selection: $modelID)
                                } label: {
                                    Label { Text(verbatim: models.first { $0.id == modelID }?.name ?? String(localized: "选择模型")) } icon: { Image(systemName: "sparkles") }
                                        .padding(.horizontal, 14).padding(.vertical, 10)
                                        .background(Color(uiColor: theme.selected), in: .capsule)
                                }.buttonStyle(.plain).accessibilityIdentifier("openAIPurposeModels")
                            }
                            if hostedImage { Text("绘图模型由服务决定。").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                        }
                        if saveFailed || (initialized && connectionID != nil && !valid) {
                            Label("模型目录已变化，请重新选择。", systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
                }
            }.padding(20).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle(purpose.title).navigationBarTitleDisplayMode(.inline)
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
