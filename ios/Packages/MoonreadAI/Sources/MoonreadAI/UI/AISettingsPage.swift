import MoonreadDesign
import SwiftUI

public struct AISettingsPage<Defaults: View>: View {
    @Environment(\.theme) private var theme
    let connections: [AIConnection]
    let error: String?
    let loginInProgress: Bool
    let state: (AIConnection) -> AIConnectionState
    let enabledCount: (AIConnection) -> Int
    let add: () -> Void
    let manage: (String, Bool) -> Void
    let refreshModels: (String) async -> Void
    let defaults: () -> Defaults

    public init(
        connections: [AIConnection], error: String?, loginInProgress: Bool,
        state: @escaping (AIConnection) -> AIConnectionState, enabledCount: @escaping (AIConnection) -> Int,
        add: @escaping () -> Void, manage: @escaping (String, Bool) -> Void,
        refreshModels: @escaping (String) async -> Void, @ViewBuilder defaults: @escaping () -> Defaults
    ) {
        self.connections = connections
        self.error = error
        self.loginInProgress = loginInProgress
        self.state = state
        self.enabledCount = enabledCount
        self.add = add
        self.manage = manage
        self.refreshModels = refreshModels
        self.defaults = defaults
    }

    public var body: some View {
        List {
            Section {
                defaults()
            } header: { Text("默认使用") } footer: {
                Text("按用途选择默认模型，具体对话仍可单独更换。")
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
            Section {
                ForEach(connections) { connection in
                    AISettingsConnectionRow(connection: connection, state: state(connection),
                        loginInProgress: loginInProgress, enabledCount: enabledCount(connection),
                        manage: { manage(connection.id, false) }, login: { manage(connection.id, true) },
                        retry: { await refreshModels(connection.id) })
                }
                Button("添加连接", systemImage: "plus", action: add)
                    .foregroundStyle(Color(uiColor: theme.accent)).accessibilityIdentifier("addAIConnection")
            } header: { Text("连接") } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    if connections.isEmpty { Text("添加一个 AI 连接后，选择用于对话和工具的模型。") }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    }
                    Text("登录、模型发现和公共模型目录刷新只用于连接与能力信息，不发送小说或聊天内容。内容共享会在发送前另行询问。")
                }.foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
        }.themedPage().navigationTitle("AI 助手")
    }
}

/// Connection state and model enablement retain their existing service owner.
private struct AISettingsConnectionRow: View {
    let connection: AIConnection
    let state: AIConnectionState
    let loginInProgress: Bool
    let enabledCount: Int
    let manage: () -> Void
    let login: () -> Void
    let retry: () async -> Void
    @Environment(\.theme) private var theme
    private var needsLogin: Bool {
        switch state {
        case .signedOut, .expired, .loginFailed, .needsLogin, .planPermissionRequired: true
        default: false
        }
    }
    private var catalogFailed: Bool { if case .modelsFailed = state { true } else { false } }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: manage) {
                HStack(spacing: 12) {
                    AIProviderIcon(providerID: connection.catalogID, accent: theme.accent).frame(width: 32, height: 32)
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
                    .frame(minWidth: 44, minHeight: 44).disabled(loginInProgress)
                    .accessibilityIdentifier("loginAIConnection-" + connection.id)
            } else if catalogFailed {
                Button("重试") { Task { await retry() } }
                    .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.accent)).frame(minWidth: 44, minHeight: 44)
            }
        }.padding(.vertical, 4)
    }
    @ViewBuilder private var status: some View {
        switch state {
        case .connected:
            HStack(spacing: 4) {
                Text(connection.authMethod == .apiKey ? "已配置" : "已连接")
                Text("·")
                if connection.modelsChecked != nil || !connection.models.isEmpty {
                    Text("\(enabledCount) 个模型")
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
