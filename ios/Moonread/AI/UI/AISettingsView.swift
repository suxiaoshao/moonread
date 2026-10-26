import SwiftUI

private struct AIConnectionRoute: Hashable {
    let id: String
    var startsLogin = false
}
private enum AISettingsModelSheet: Identifiable {
    case conversation, tool(AIModelPurpose)
    var id: String { switch self { case .conversation: "conversation"; case .tool(let purpose): purpose.rawValue } }
    var purpose: AIModelPurpose? { if case .tool(let purpose) = self { purpose } else { nil } }
}

struct AISettingsView: View {
    @State private var adding = false
    @State private var connectionRoute: AIConnectionRoute?
    @State private var modelSheet: AISettingsModelSheet?
    @Environment(\.dismiss) private var dismiss
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            Section {
                Button { modelSheet = .conversation } label: {
                    AISettingsValueLabel(title: "对话", value: conversationLabel)
                }.buttonStyle(.plain).accessibilityIdentifier("openAIModelPanel")
                ForEach(AIModelPurpose.allCases, id: \.self) { purpose in
                    Button { modelSheet = .tool(purpose) } label: {
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
                        manage: { connectionRoute = .init(id: connection.id) },
                        login: { connectionRoute = .init(id: connection.id, startsLogin: true) })
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
            .navigationDestination(item: $connectionRoute) { value in
                AIConnectionView(connectionID: value.id, startsLogin: value.startsLogin)
            }
            .sheet(item: $modelSheet) { value in
                NavigationStack { AISettingsModelList(purpose: value.purpose) }
                    .environment(ai).themeScope(theme).preferredColorScheme(theme.scheme)
                    .presentationBackground(Color(uiColor: theme.canvas)).presentationDragIndicator(.visible)
            }
            .onChange(of: ai.availability.isAvailable) { _, available in
                if !available { adding = false; connectionRoute = nil; modelSheet = nil; dismiss() }
            }
            .task { await ai.providers.refreshCatalogsIfNeeded() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NavigationLink { AIUsageHelpView() } label: { Image(systemName: "questionmark.circle") }.toolbarGlyph().accessibilityLabel("AI 使用帮助") } }
    }
    private var conversationLabel: String {
        guard let value = ai.modelSelection(for: .defaults), let model = ai.providers.model(connectionID: value.connectionID, modelID: value.modelID) else { return String(localized: "未设置") }
        guard !model.thinking.isEmpty else { return model.name }
        let effort = value.thinking.map(AIThinkingLabel.label) ?? String(localized: "默认")
        return model.name + " · " + String(localized: "推理 \(effort)")
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

/// Tool entries from quick tasks and settings share immediate-save selection.
struct AIToolServiceView: View {
    let purpose: AIModelPurpose
    var body: some View { AISettingsModelList(purpose: purpose) }
}

private struct AISettingsModelList: View {
    /// nil is the conversation default; native tools have no separate effort setting.
    let purpose: AIModelPurpose?
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var saving = false
    @State private var saveFailed = false
    @State private var adding = false
    private var current: AIPurposeSelection? {
        if let purpose { return ai.providers.purposeDefaults[purpose] }
        return ai.modelSelection(for: .defaults).map { .init(connectionID: $0.connectionID, modelID: $0.modelID) }
    }
    private func models(_ connection: AIConnection) -> [AIModelOption] {
        connection.models.filter {
            AISettingsModelAvailability.supports($0, purpose: purpose, connection: connection)
                || (current?.connectionID == connection.id && current?.modelID == $0.id)
        }
    }
    private var offeredCount: Int { ai.providers.connections.reduce(0) { $0 + models($1).count } }
    private var hasMatches: Bool {
        ai.providers.connections.contains { connection in
            !AIModelSearch.filter(models(connection), query: query, connection: connection, ai.providers).isEmpty
        }
    }
    var body: some View {
        Group {
            if offeredCount == 0 {
                ContentUnavailableView {
                    Label("还没有可用模型", systemImage: "sparkles")
                } description: { Text("先连接一个 AI 账户并加载模型。") } actions: {
                    Button("添加连接", systemImage: "plus") { adding = true }
                }
            } else if !hasMatches {
                ContentUnavailableView {
                    Label("没有匹配的模型", systemImage: "magnifyingglass")
                } description: { Text("试试其他搜索词。") } actions: {
                    Button("清除搜索") { query = "" }
                }
            } else {
                List {
                    if purpose == nil, let selection = ai.modelSelection(for: .defaults),
                       let model = ai.providers.model(connectionID: selection.connectionID, modelID: selection.modelID),
                       !model.thinking.isEmpty {
                        Section("推理强度") {
                            Picker(selection: Binding<String?>(get: {
                                ai.modelSelection(for: .defaults)?.thinking
                            }, set: { effort in
                                var value = selection; value.thinking = effort
                                saving = true
                                Task {
                                    saveFailed = !(await ai.applyModelSelection(value, to: .defaults))
                                    saving = false
                                }
                            })) {
                                if AIModelSelection.defaultThinking(model) == nil { Text("默认").tag(String?.none) }
                                ForEach(model.thinking, id: \.self) { Text(AIThinkingLabel.label($0)).tag(Optional($0)) }
                            } label: { Text(verbatim: model.name) }
                                .pickerStyle(.menu).disabled(saving).accessibilityIdentifier("aiDefaultThinking")
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }
                    if let purpose {
                        Button {
                            if ai.providers.setPurpose(purpose, selection: nil) { dismiss() }
                            else { saveFailed = true }
                        } label: {
                            HStack { Text("不使用"); Spacer(); if current == nil { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) } }
                        }.buttonStyle(.plain).accessibilityIdentifier("aiPurposeNone")
                            .listRowBackground(Color(uiColor: theme.surface))
                    }
                    ForEach(ai.providers.connections) { connection in
                        let offered = models(connection)
                        let shown = AIModelSearch.filter(offered, query: query, connection: connection, ai.providers)
                        if !shown.isEmpty {
                            Section {
                                ForEach(shown) { model in modelRow(model, connection: connection, offered: offered) }
                            } header: { AIConnectionHeader(connection: connection) }
                                .listRowBackground(Color(uiColor: theme.surface))
                                .listRowSeparatorTint(Color(uiColor: theme.separator))
                        }
                    }
                }
            }
        }.modifier(AISettingsModelSearch(query: $query, enabled: offeredCount > 12))
            .themedPage().accessibilityIdentifier("aiSettingsModelList")
            .navigationTitle(purpose?.title ?? String(localized: "对话")).navigationBarTitleDisplayMode(.inline)
            .aiAddConnectionFlow(isPresented: $adding)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("dismissAISettingsModels")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if saveFailed {
                    Text("模型目录已变化，请重新选择。").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                        .padding().frame(maxWidth: .infinity).background(Color(uiColor: theme.canvas))
                }
            }
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { dismiss() } }
    }
    private func modelRow(_ model: AIModelOption, connection: AIConnection, offered: [AIModelOption]) -> some View {
        let reason = AISettingsModelAvailability.reason(model, purpose: purpose, connection: connection, providers: ai.providers)
        let selected = current == AIPurposeSelection(connectionID: connection.id, modelID: model.id)
        return Button {
            saving = true
            Task {
                let saved: Bool
                if let purpose {
                    saved = ai.providers.setPurpose(purpose, selection: .init(connectionID: connection.id, modelID: model.id))
                } else {
                    var value = ai.modelSelection(for: .defaults) ?? .init(connectionID: "", modelID: "", thinking: nil)
                    value.select(model, connection: connection)
                    saved = await ai.applyModelSelection(value, to: .defaults)
                }
                saving = false; saveFailed = !saved
                if saved && purpose != nil { dismiss() }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    AIModelRowLabel(model: model, duplicate: AIModelSearch.duplicateNames(offered).contains(model.name), disabled: false)
                    if let reason { Text(reason).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
            }.frame(minHeight: 44).contentShape(.rect)
                .foregroundStyle(Color(uiColor: reason == nil ? theme.ink : theme.secondary))
        }.buttonStyle(.plain).disabled(reason != nil || saving)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("aiSettingsModel-\(connection.id)-\(model.id)")
    }
}

private struct AISettingsModelSearch: ViewModifier {
    @Binding var query: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } else { content }
    }
}
