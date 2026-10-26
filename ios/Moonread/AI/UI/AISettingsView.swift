import SwiftUI

struct AISettingsView: View {
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        List {
            // What to use is the recurring task; the account list can grow without pushing it away.
            Section {
                Text("登录、模型发现和公共模型目录刷新只用于连接与能力信息，不发送小说或聊天内容。内容共享会在发送前另行询问。")
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("默认使用") {
                HStack {
                    Text("对话")
                    Spacer(minLength: LayoutTokens.compact)
                    AIModelPickerButton(target: .defaults)
                }
                ForEach(AIModelPurpose.allCases, id: \.self) { purpose in
                    NavigationLink { AIToolServiceView(purpose: purpose) } label: {
                        HStack {
                            Text(purpose.title)
                            Spacer()
                            Text(ai.providers.purposeSelection(purpose).flatMap { selection in
                                ai.providers.connections.first { $0.id == selection.connectionID }?.name
                            } ?? String(localized: "未设置"))
                                .foregroundStyle(Color(uiColor: theme.secondary))
                        }
                    }.accessibilityIdentifier("openAIModelPanel-" + purpose.rawValue)
                }
            }.listRowBackground(Color(uiColor: theme.surface))
            Section("连接") {
                ForEach(ai.providers.connections) { connection in
                    NavigationLink { AIConnectionView(connectionID: connection.id) } label: {
                        HStack(spacing: 12) {
                            AIProviderIcon(providerID: connection.catalogID)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(connection.name).font(.headline)
                                Text(ai.providers.isLoggedIn(connection) ? (connection.authMethod == .apiKey ? "已配置" : "已连接") : "尚未连接")
                                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }.padding(.vertical, 6)
                    }
                }
                Button("添加连接", systemImage: "plus") { adding = true }
                    .accessibilityIdentifier("addAIConnection")
            }.listRowBackground(Color(uiColor: theme.surface))
            if let error = ai.providers.error { Section { Text(error).foregroundStyle(Color(uiColor: theme.destructive)) }.listRowBackground(Color(uiColor: theme.surface)) }
        }.themedPage().navigationTitle("AI 助手")
            .aiAddConnectionFlow(isPresented: $adding)
            .onChange(of: ai.availability.isAvailable) { _, available in if !available { adding = false; dismiss() } }
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
                    Button("添加") {
                        let value = AIConnection(name: customName, billing: .usage,
                            baseURL: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                            providerID: "custom", providerName: customName, wireProtocol: wire, authMethod: .apiKey)
                        createdConnectionID = ai.providers.addConnection(value); dismiss()
                    }.disabled(customName.isEmpty || URL(string: endpoint)?.scheme != "https" || URL(string: endpoint)?.host == nil)
                }.listRowBackground(Color(uiColor: theme.surface)) }
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
        List {
            Section("服务") {
                Picker("服务", selection: Binding(get: { connectionID }, set: { connectionID = $0; modelID = nil; saveFailed = false })) {
                    Text("不使用").tag(String?.none)
                    ForEach(connections) { connection in
                        Label { Text(connection.name) } icon: { AIProviderIcon(providerID: connection.catalogID) }
                            .tag(Optional(connection.id))
                    }
                }.pickerStyle(.inline).labelsHidden()
            }.listRowBackground(Color(uiColor: theme.surface))
            if connections.isEmpty {
                Section { Text("还没有支持此工具的连接")
                    Button("添加连接", systemImage: "plus") { adding = true }.accessibilityIdentifier("addAIToolConnection")
                }.listRowBackground(Color(uiColor: theme.surface))
            }
            if let connection {
                Section(hostedImage ? String(localized: "执行模型") : (purpose == .search ? String(localized: "搜索模型") : String(localized: "图片模型"))) {
                    if models.isEmpty {
                        Text("暂无可用模型").foregroundStyle(Color(uiColor: theme.secondary))
                    } else {
                        NavigationLink {
                            AIPurposeModelList(purpose: purpose, connectionID: connection.id,
                                               current: ai.providers.purposeSelection(purpose).flatMap { $0.connectionID == connection.id ? $0.modelID : nil },
                                               selection: $modelID)
                        } label: {
                            LabeledContent("模型") {
                                Text(verbatim: models.first { $0.id == modelID }?.name ?? String(localized: "选择模型"))
                            }
                        }.accessibilityIdentifier("openAIPurposeModels")
                    }
                    if hostedImage { LabeledContent("绘图模型", value: "由服务决定") }
                    NavigationLink(ai.providers.isLoggedIn(connection) ? "管理连接" : "连接账户") {
                        AIConnectionView(connectionID: connection.id)
                    }
                }.listRowBackground(Color(uiColor: theme.surface))
            }
            if saveFailed { Text("模型目录已变化，请重新选择。").foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
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
        if let connection { list(connection) } else { ContentUnavailableView("连接不可用", systemImage: "sparkles") }
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
                        .listRowBackground(Color(uiColor: theme.surface))
                }
            }
        }.themedPage().navigationTitle("选择模型").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索"))
    }
}
