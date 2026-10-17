import SwiftUI
import AuthenticationServices

struct AIConnectionView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let connectionID: String
    var startsEditingModels = false
    @State private var editingModels = false
    @State private var confirmingRemoval = false
    @State private var removing = false
    @State private var removalFailed = false
    @State private var editingKey = false
    @State private var modelQuery = ""
    @State private var addingModel = false
    @State private var manualModel = ""
    @State private var manualContext = ""
    @State private var manualOutput = ""
    @State private var manualError = false
    @State private var apiKey = ""
    @State private var savingKey = false
    @State private var browser: AILoginBrowserPage?
    @State private var renaming = false
    @State private var name = ""
    @State private var authorizationCode = ""
    @State private var showingChatGPTWelcome = false
    private var connection: AIConnection? { ai.providers.connections.first { $0.id == connectionID } }
    private var authorizationURL: URL? {
        if case .browser(let request) = ai.providers.loginStates[connectionID] { return request.url }
        return nil
    }
    var body: some View {
        ScrollView {
            if let connection {
                VStack(alignment: .leading, spacing: 28) {
                    identity(connection)
                    accountCard(connection)
                    VStack(alignment: .leading, spacing: LayoutTokens.control) {
                        Text("数据共享许可").font(.headline)
                        Text("撤销后会停止此连接的内容任务。已发送给服务的数据无法追回。")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        Button("撤销许可", role: .destructive) { ai.sharing.revoke(connection.id) }
                            .accessibilityIdentifier("revokeAIDataSharing")
                    }
                    if showsModels(connection) { modelSettings(connection) }
                    if let notice = ai.providers.modelNotices[connection.id] {
                        Text(verbatim: notice).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                            .accessibilityIdentifier("aiModelCatalogNotice")
                    }
                    if connection.authMethod == .apiKey && ai.providers.isLoggedIn(connection) {
                        Button("添加模型", systemImage: "plus") { addingModel = true }
                    }


                }.padding(24).frame(maxWidth: 600, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.themedPage().navigationTitle("AI 连接").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("AI 连接").font(.headline).foregroundStyle(Color(uiColor: theme.ink)) }

            }
            .alert("移除这个连接？", isPresented: $confirmingRemoval) {
                Button("移除连接", role: .destructive) {
                    removing = true
                    Task { if await ai.removeConnection(connectionID) { dismiss() } else { removalFailed = true }; removing = false }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("移除配置和本机凭证，保留已有对话。") }
            .alert("修改连接名称", isPresented: $renaming) {
                TextField("名称", text: $name)
                Button("取消", role: .cancel) {}
                Button("保存") {
                    if let index = ai.providers.connections.firstIndex(where: { $0.id == connectionID }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ai.providers.connections[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines); ai.providers.saveConnections()
                    }
                }
            }
            .sheet(isPresented: $addingModel) {
                NavigationStack {
                    Form {
                      Group {
                        TextField("模型 ID", text: $manualModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("上下文容量（tokens，必填）", text: $manualContext).keyboardType(.numberPad)
                        TextField("最大输出（tokens，选填）", text: $manualOutput).keyboardType(.numberPad)
                        if manualError { Text("请填写有效容量，最大输出不能超过上下文容量。")
                            .foregroundStyle(Color(uiColor: theme.destructive)) }
                      }.listRowBackground(Color(uiColor: theme.surface))
                    }.themedPage().navigationTitle("添加模型")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("取消") { addingModel = false } }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("保存") {
                                    manualError = !ai.providers.addManualModel(connectionID: connectionID, id: manualModel, context: manualContext, output: manualOutput)
                                    if !manualError { addingModel = false }
                                }.disabled(manualModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manualContext.isEmpty)
                            }
                        }
                }
            }
            .onChange(of: addingModel) { _, presented in
                if !presented { manualModel = ""; manualContext = ""; manualOutput = ""; manualError = false }
            }
            .background {
                if let browser {
                    AIWebAuthenticationBrowser(url: browser.url) { error in
                        if self.browser?.url == browser.url { self.browser = nil }
                        ai.providers.browserPresentationFailed(connectionID, url: browser.url, error: error)
                    }.id(browser.id).frame(width: 0, height: 0)
                }
            }
            .onChange(of: authorizationURL) { _, url in
                if let url, connection?.authMethod == .chatGPT { browser = AILoginBrowserPage(url: url) }
                else if url == nil { browser = nil }
            }
            .onChange(of: ai.providers.showingChatGPTWelcome) { _, value in showingChatGPTWelcome = value }
            .onAppear { showingChatGPTWelcome = ai.providers.showingChatGPTWelcome }
            .alert("正在使用你的 ChatGPT 套餐", isPresented: $showingChatGPTWelcome) {
                Button("知道了") { ai.providers.acknowledgeChatGPTWelcome() }
            } message: { Text("此连接的 AI 请求使用你的 ChatGPT 套餐，用量与权限由 ChatGPT 管理。") }

    }
    private func identity(_ connection: AIConnection) -> some View {
        HStack(spacing: 16) {
            AIProviderIcon(providerID: connection.catalogID).frame(width: 50, height: 50)
                .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 17))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(connection.name).font(.title2.weight(.semibold))
                    Spacer(minLength: 8)
                    Button("修改连接名称", systemImage: "pencil") { name = connection.name; renaming = true }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                Text(verbatim: connection.serviceName + " · " + (connection.authMethod == .apiKey ? "API Key" : String(localized: "账户登录")))
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func accountCard(_ connection: AIConnection) -> some View {
        let connected = ai.providers.isLoggedIn(connection)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(connection.authMethod == .apiKey ? "凭证" : "账户").font(.headline)
                Spacer()
                if connected {
                    Label(connection.authMethod == .apiKey ? "已配置" : "已登录", systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.accent))
                }
            }
            if connection.authMethod == .apiKey {
                if ["kimi-code-plan-cn", "kimi-code-plan-global"].contains(connection.catalogID) {
                    Text("Kimi 会员可在 Kimi Code 控制台创建 API Key，然后粘贴到这里。会员权益与工具使用范围以 Kimi 的说明为准；月读不提供 Kimi 账户登录。")
                        .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        .accessibilityIdentifier("kimiMembershipKeyGuide")
                    Link("打开 Kimi Code 控制台", destination: URL(string: "https://www.kimi.com/code/console")!)
                        .foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("kimiKeyConsoleLink")
                }
                if !connected || editingKey {
                    SecureField("API Key", text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(savingKey)
                        .accessibilityIdentifier("aiAPIKeyDraft")
                        .padding(12).background(Color(uiColor: theme.input), in: .rect(cornerRadius: 12))
                    Button {
                        savingKey = true
                        Task {
                            let saved = await ai.providers.saveAPIKey(apiKey, for: connectionID)
                            savingKey = false
                            if saved { apiKey = ""; editingKey = false }
                        }
                    } label: { Text("保存 API Key").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(ThemedProminentButtonStyle()).disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savingKey).accessibilityIdentifier("saveAIAPIKey")
                    if savingKey { ProgressView() }
                    if let error = ai.providers.credentialErrors[connectionID] { Text(verbatim: error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("aiAPIKeyWriteError") }
                    if connected { Button("取消", role: .cancel) { editingKey = false; apiKey = "" } }
                } else {
                    Text("API Key 已安全保存").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                }
                if !connected, let error = ai.providers.modelErrors[connectionID] { Text(error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            } else { statusContent(connection) }
            if ai.providers.isUsingChatGPTPlan(connection) {
                Label("正在使用 ChatGPT 套餐", systemImage: "checkmark.shield")
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                Link("管理 ChatGPT 用量", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                    .foregroundStyle(Color(uiColor: theme.accent))
            }
            if removalFailed { Text("无法移除连接，请重试。").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
            ThemedDivider()
            HStack {
                if connected && !editingKey {
                    Button(connection.authMethod == .apiKey ? "更换 API Key" : "重新登录", systemImage: connection.authMethod == .apiKey ? "key" : "person.crop.circle.badge.checkmark") {
                        if connection.authMethod == .apiKey { editingKey = true } else { ai.providers.login(connectionID) }
                    }.font(.subheadline).disabled(savingKey || ai.providers.loginConnectionID != nil)
                        .accessibilityIdentifier("replaceAICredential")
                }
                Spacer(minLength: 8)
                Button("移除连接", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.destructive))
                    .disabled(removing || savingKey).accessibilityIdentifier("removeAIConnection")
            }.frame(minHeight: 44)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
    }
    @ViewBuilder private func statusContent(_ connection: AIConnection) -> some View {
        switch ai.providers.connectionState(connection) {
        case .signedOut:
            primary(connection.authMethod == .chatGPT ? "使用 ChatGPT 继续" : "登录账户") { ai.providers.login(connectionID) }.disabled(ai.providers.loginConnectionID != nil).accessibilityIdentifier("loginAIConnection")
        case .planPermissionRequired:
            Text("你没有允许月读使用 ChatGPT 套餐")
                .foregroundStyle(Color(uiColor: theme.ink))
            primary("重新授权") { ai.providers.login(connectionID) }
                .disabled(ai.providers.loginConnectionID != nil).accessibilityIdentifier("reauthorizeChatGPTPlan")
        case .needsLogin:
            loginPrompt(title: "重新连接你的账户", detail: "登录已失效，请重新授权。已有对话会保留。", retry: true)
        case .authorizing:
            VStack(alignment: .leading, spacing: 16) {
                ProgressView("正在准备授权…").tint(Color(uiColor: theme.accent))
                Button("取消登录", role: .cancel) { ai.providers.cancelLogin(connectionID) }
            }.accessibilityIdentifier("aiAuthorizing")
        case .browser:
            VStack(alignment: .leading, spacing: 12) {
                primary("打开登录页") { if let url = authorizationURL { browser = AILoginBrowserPage(url: url) } }
                if connection.authMethod == .openrouter {
                TextField("粘贴授权码", text: $authorizationCode)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).background(Color(uiColor: theme.input), in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("aiAuthorizationCode")
                primary("完成授权") {
                    let code = authorizationCode; authorizationCode = ""
                    ai.providers.submitAuthorizationCode(code, connectionID: connectionID)
                }.disabled(authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else { ProgressView("等待授权").tint(Color(uiColor: theme.accent)) }
                Button("取消登录", role: .cancel) { authorizationCode = ""; ai.providers.cancelLogin(connectionID) }
            }
        case .loadingModels, .connected:
            EmptyView()
        case .expired:
            failure(title: "授权已过期", detail: String(localized: "请重新登录并完成授权。"))
            primary("重新登录") { ai.providers.login(connectionID) }.disabled(ai.providers.loginConnectionID != nil)
        case .loginFailed(let error):
            failure(title: "连接暂时失败", detail: error)
            primary("重试登录") { ai.providers.login(connectionID) }.disabled(ai.providers.loginConnectionID != nil)
        case .modelsFailed:
            EmptyView()
        }
    }
    private func loginPrompt(title: LocalizedStringKey, detail: LocalizedStringKey, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold))
            secondary(detail)
            primary(retry ? "重新登录" : "登录") { ai.providers.login(connectionID) }
                .disabled(ai.providers.loginConnectionID != nil).accessibilityIdentifier("loginAIConnection")
            if ai.providers.loginConnectionID != nil { secondary("另一连接正在授权，请先完成或取消该次登录。") }
        }
    }
    private func failure(title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.circle").font(.headline).foregroundStyle(Color(uiColor: theme.destructive))
            Text(detail).foregroundStyle(Color(uiColor: theme.secondary))
        }.accessibilityIdentifier("aiConnectionError")
    }
    private func secondary(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(Color(uiColor: theme.secondary))
    }
    private func primary(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(ThemedProminentButtonStyle())
    }
    private func showsModels(_ connection: AIConnection) -> Bool {
        switch ai.providers.connectionState(connection) {
        case .connected, .loadingModels, .modelsFailed: return ai.providers.isLoggedIn(connection)
        default: return false
        }
    }
    private func modelSettings(_ connection: AIConnection) -> some View {
        let models = AIModelSearch.filter(connection.models, query: modelQuery, connection: connection, ai.providers)
        let enabled = connection.models.filter { ai.providers.isEnabled(modelID: $0.id, in: connection) }.count
        let searching = editingModels || connection.models.count > 12
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("模型").font(.headline)
                Text(verbatim: "\(enabled.formatted()) / \(connection.models.count.formatted())")
                    .foregroundStyle(Color(uiColor: theme.secondary))
                    .accessibilityLabel(Text("已启用 \(enabled) 个，共 \(connection.models.count) 个"))
                Spacer()
                if editingModels {
                    Menu {
                        let ids = models.map(\.id)
                        Button(modelQuery.isEmpty ? String(localized: "启用全部") : String(localized: "启用 \(ids.count) 个结果"), systemImage: "checkmark.circle") {
                            ai.providers.setModels(ids, enabled: true, connectionID: connectionID)
                        }
                        Button(modelQuery.isEmpty ? String(localized: "停用全部") : String(localized: "停用 \(ids.count) 个结果"), systemImage: "circle") {
                            ai.providers.setModels(ids, enabled: false, connectionID: connectionID)
                        }
                    } label: { Text("全部") }.disabled(models.isEmpty).frame(minHeight: 44).accessibilityIdentifier("bulkAIModels")
                    Button("完成") { editingModels = false }.fontWeight(.semibold).frame(minHeight: 44).accessibilityIdentifier("finishEditingAIModels")
                } else {
                    if ai.providers.refreshingModels.contains(connectionID) {
                        ProgressView().accessibilityLabel("正在载入模型…").frame(width: 44, height: 44)
                    } else {
                        Button("刷新可用模型", systemImage: "arrow.clockwise") { Task { await ai.providers.refreshModels(connectionID) } }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier("refreshAIModels")
                    }
                    if !connection.models.isEmpty {
                        Button("编辑") { editingModels = true }.frame(minHeight: 44).accessibilityIdentifier("editAIModels")
                    }
                }
            }
            if searching {
                TextField("搜索模型", text: $modelQuery).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(14).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 14))
                    .accessibilityIdentifier("searchAIConnectionModels")
            }
            LazyVStack(spacing: 0) {
                if connection.models.isEmpty {
                    Text("还没有可用模型").foregroundStyle(Color(uiColor: theme.secondary)).padding(20)
                } else if models.isEmpty {
                    Text("没有匹配的模型").foregroundStyle(Color(uiColor: theme.secondary)).padding(20)
                }
                ForEach(models) { model in
                    if model.id != models.first?.id { ThemedDivider().padding(.horizontal, 18) }
                    modelRow(model, connection: connection)
                }
                if case .modelsFailed(let error) = ai.providers.connectionState(connection) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(Color(uiColor: theme.destructive))
                        Button("重新加载模型") { Task { await ai.providers.refreshModels(connectionID) } }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("aiConnectionError")
                }
            }.frame(maxWidth: .infinity).background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 22))
            if editingModels {
                Text("停用后不再提供给新的选择，已有选择不受影响。").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
        .onAppear { if startsEditingModels && !connection.models.isEmpty { editingModels = true } }
    }
    @ViewBuilder private func modelRow(_ model: AIModelOption, connection: AIConnection) -> some View {
        let disabled = !ai.providers.isEnabled(modelID: model.id, in: connection)
        let isDefault = ai.providers.defaultTextConnectionID == connection.id && connection.modelID == model.id
        if editingModels {
            Toggle(isOn: Binding(get: { ai.providers.isEnabled(modelID: model.id, in: connection) },
                                 set: { ai.providers.setModels([model.id], enabled: $0, connectionID: connection.id) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name)
                    if isDefault { Text("默认对话").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
            }.tint(Color(uiColor: theme.accent)).padding(.horizontal, 18).padding(.vertical, 10).frame(minHeight: 44)
                .accessibilityIdentifier("aiModelEnabled-\(connection.id)-\(model.id)")
        } else {
            NavigationLink { AIModelDetailView(connectionID: connection.id, modelID: model.id) } label: {
                HStack(spacing: 12) {
                    Text(verbatim: model.name).frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color(uiColor: disabled ? theme.secondary : theme.ink))
                    if disabled { Text("未启用").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if isDefault {
                        Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)).accessibilityLabel("默认文本模型")
                    }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                }.padding(.horizontal, 18).padding(.vertical, 16).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("aiConnectionModel-\(connection.id)-\(model.id)")
        }
    }
}
private struct AILoginBrowserPage: Identifiable {
    let url: URL
    var id: URL { url }
}
/// The browser never consumes OAuth callbacks: only the validated loopback listener can finish sign-in.
@MainActor protocol AIWebAuthenticationSession: AnyObject {
    var prefersEphemeralWebBrowserSession: Bool { get set }
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
    func cancel()
}
extension ASWebAuthenticationSession: AIWebAuthenticationSession {}

struct AIWebAuthenticationBrowser: UIViewRepresentable {
    let url: URL
    let onFailure: (Error) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(url: url, onFailure: onFailure) }
    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.start(in: window) }
        return view
    }
    func updateUIView(_ view: AnchorView, context: Context) {}
    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        view.attached = nil
        coordinator.stop()
    }
    final class AnchorView: UIView {
        var attached: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor final class Coordinator {
        // No authorization request uses this scheme. It keeps ASWebAuth alive until loopback settles.
        static let callback = ASWebAuthenticationSession.Callback.customScheme("moonread-auth-session-unused")
        typealias Factory = (URL, @escaping ASWebAuthenticationSession.CompletionHandler) -> any AIWebAuthenticationSession
        private let url: URL
        private let makeSession: Factory
        private let onFailure: (Error) -> Void
        private var session: (any AIWebAuthenticationSession)?
        private var presentation: Presentation?
        private var stopped = false
        init(url: URL, makeSession: @escaping Factory = { url, completion in
            ASWebAuthenticationSession(url: url, callback: Coordinator.callback, completionHandler: completion)
        }, onFailure: @escaping (Error) -> Void) {
            self.url = url; self.makeSession = makeSession; self.onFailure = onFailure
        }
        func start(in window: UIWindow) {
            guard session == nil, !stopped else { return }
            let session = makeSession(url) { [weak self] _, error in
                Task { @MainActor [weak self] in self?.finished(error) }
            }
            presentation = Presentation(window: window)
            session.presentationContextProvider = presentation
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { finished(AIError.invalidResponse) }
        }
        func stop() {
            stopped = true
            let session = session; self.session = nil
            session?.cancel()
            presentation = nil
        }
        private func finished(_ error: Error?) {
            guard !stopped else { return }
            stop()
            let value = error as NSError?
            if value?.domain == ASWebAuthenticationSessionErrorDomain,
               value?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                onFailure(AIChatGPTError.loginCancelled)
            } else { onFailure(error ?? AIError.invalidResponse) }
        }
        private final class Presentation: NSObject, ASWebAuthenticationPresentationContextProviding {
            let window: UIWindow
            init(window: UIWindow) { self.window = window }
            func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
        }
    }
}
