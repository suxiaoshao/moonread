import Foundation
import Observation

enum AILoginState: Equatable {
    case authorizing, browser(AIAuthentication.BrowserAuthorization), expired, failed(String)
}
enum AIConnectionState: Equatable {
    case signedOut, authorizing, loadingModels, connected
    case expired, loginFailed(String), needsLogin, planPermissionRequired, modelsFailed(String), browser(AIAuthentication.BrowserAuthorization)
}

/// Owns connection configuration, authorization and model catalog state.
@MainActor @Observable final class AIConnectionService {
    let availability: AIAvailability
    let catalog: AIModelCatalog
    private let usage: AIConnectionUsageService?
    private(set) var catalogActivated = false
    @ObservationIgnored private var accountCatalogAttempts: [String: Date] = [:]
    let sharing: AIDataSharingConsent
    var connections: [AIConnection] = [] {
        didSet {
            for old in oldValue {
                guard let new = connections.first(where: { $0.id == old.id }),
                      old.baseURL == new.baseURL, old.providerID == new.providerID,
                      old.protocolIdentity == new.protocolIdentity, old.catalogCredentialGeneration == new.catalogCredentialGeneration else {
                    usage?.invalidate(old.id)
                    sharing.revoke(old.id); invalidateCatalog(old.id)
                    if let index = connections.firstIndex(where: { $0.id == old.id }) {
                        let manuals = connections[index].models.filter { $0.isManual == true }.map {
                            AIModelOption(id: $0.id, name: $0.name, contextWindow: $0.contextWindow, thinking: [], maxOutput: $0.maxOutput, isManual: true)
                        }
                        connections[index].directorySnapshot = .legacy(manuals)
                        runtime[old.id, default: ConnectionRuntime()].directory = .idle
                        usage?.refresh(old.id)
                    }
                    continue
                }
            }
        }
    }
    var defaultTextConnectionID: String?
    private(set) var purposeDefaults: [AIModelPurpose: AIPurposeSelection] = [:]
    enum NativeRequestKind { case content, usage }
    @ObservationIgnored private var nativeRequests: [UUID: (connectionID: String, kind: NativeRequestKind, cancel: @Sendable () -> Void)] = [:]
    private var changingCredentials: Set<String> = []
    var error: String?
    var credentialRevision = 0
    var loginConnectionID: String?
    private enum LoginReason { case expiredSession, directoryRejected }
    private enum AuthorizationSnapshot {
        case disconnected
        case available(reference: String, generation: UUID?)
        case needsLogin(LoginReason)
    }
    private enum LoginAttempt {
        case preparing
        case browser(AIAuthentication.BrowserAuthorization)
    }
    private enum LoginFailure { case expired, message(String) }
    private enum Authorization {
        case settled(AuthorizationSnapshot)
        case authorizing(LoginAttempt, previous: AuthorizationSnapshot)
        case failed(LoginFailure, previous: AuthorizationSnapshot)

        var snapshot: AuthorizationSnapshot {
            switch self {
            case .settled(let snapshot), .authorizing(_, let snapshot), .failed(_, let snapshot): snapshot
            }
        }
        var presentation: AILoginState? {
            switch self {
            case .settled: nil
            case .authorizing(.preparing, _): .authorizing
            case .authorizing(.browser(let request), _): .browser(request)
            case .failed(.expired, _): .expired
            case .failed(.message(let message), _): .failed(message)
            }
        }
        func updatingSnapshot(_ value: AuthorizationSnapshot) -> Self {
            switch self {
            case .settled: .settled(value)
            case .authorizing(let attempt, _): .authorizing(attempt, previous: value)
            case .failed(let error, _): .failed(error, previous: value)
            }
        }
    }
    private enum DirectoryState {
        case idle
        case refreshing(previous: AIDirectorySnapshot)
        case ready(AIDirectorySnapshot)
        case failed(String, previous: AIDirectorySnapshot?)

        var snapshot: AIDirectorySnapshot? {
            switch self {
            case .idle: nil
            case .refreshing(let value), .ready(let value): value
            case .failed(_, let previous): previous
            }
        }
        var isRefreshing: Bool { if case .refreshing = self { true } else { false } }
        var error: String? { if case .failed(let message, _) = self { message } else { nil } }
    }
    private struct ConnectionRuntime {
        var authorization = Authorization.settled(.disconnected)
        var directory = DirectoryState.idle
    }
    private var runtime: [String: ConnectionRuntime] = [:]
    var showingChatGPTWelcome = false
    var modelNotices: [String: String] = [:]
    var credentialErrors: [String: String] = [:]
    @ObservationIgnored private var modelRevisions: [String: UUID] = [:]
    @ObservationIgnored private var modelTasks: [String: Task<Void, Never>] = [:]

    func loginState(_ id: String) -> AILoginState? { runtime[id]?.authorization.presentation }
    func setLoginPresentation(_ value: AILoginState?, for id: String) {
        if case .authorizing? = value { usage?.suspend(id) }
        let current = runtime[id]?.authorization.snapshot ?? .disconnected
        runtime[id, default: ConnectionRuntime()].authorization = switch value {
        case nil: .settled(current)
        case .authorizing: .authorizing(.preparing, previous: current)
        case .browser(let request): .authorizing(.browser(request), previous: current)
        case .expired: .failed(.expired, previous: current)
        case .failed(let message): .failed(.message(message), previous: current)
        }
    }
    func requiresLogin(_ id: String) -> Bool {
        if case .needsLogin = runtime[id]?.authorization.snapshot { true } else { false }
    }
    func isRefreshing(_ id: String) -> Bool { runtime[id]?.directory.isRefreshing == true }
    var refreshingModels: Set<String> { Set(runtime.keys.filter { isRefreshing($0) }) }
    func modelError(_ id: String) -> String? { runtime[id]?.directory.error }

    private func setAuthorization(_ value: AuthorizationSnapshot, for id: String) {
        if case .needsLogin = value { usage?.invalidate(id) }
        let current = runtime[id]?.authorization ?? .settled(.disconnected)
        runtime[id, default: ConnectionRuntime()].authorization = current.updatingSnapshot(value)
    }
    private func markAuthorized(_ id: String) {
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        setAuthorization(.available(reference: connection.credentialReference, generation: connection.catalogCredentialGeneration), for: id)
    }
    private func publishDirectoryError(_ message: String, for id: String) {
        let previous = connections.first(where: { $0.id == id })?.directorySnapshot ?? runtime[id]?.directory.snapshot
        runtime[id, default: ConnectionRuntime()].directory = .failed(message, previous: previous)
    }
    private func finishDirectoryRefresh(_ id: String) {
        guard case .refreshing(let previous) = runtime[id]?.directory else { return }
        runtime[id, default: ConnectionRuntime()].directory = .ready(previous)
    }
    @ObservationIgnored let auth: AIAuthentication
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginRevision = UUID()
    init(defaults: UserDefaults, auth: AIAuthentication, catalog: AIModelCatalog? = nil, sharing: AIDataSharingConsent? = nil, availability: AIAvailability? = nil, usage: AIConnectionUsageService? = nil) {
        self.availability = availability ?? AIAvailability(defaults: defaults)
        self.sharing = sharing ?? AIDataSharingConsent(defaults: defaults)
        self.catalog = catalog ?? AIModelCatalog()
        self.defaults = defaults; self.auth = auth
        self.usage = usage
        usage?.bind(self)
        auth.network.bind(self.availability)
        self.catalog.network.bind(self.availability)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let session = arguments.firstIndex(of: "--ui-test-session").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        #endif
        connections = AIPersistedJSON.readArray(AIConnection.self, data: defaults.data(forKey: "Moonread.ai.connections"), key: "Moonread.ai.connections")
            .map { stored in
                var connection = stored
                let policy = AIModelDirectoryPolicy.policy(connection)
                // 1.4 ordinary API snapshots may be public metadata, not a
                // successful directory read. Keep only explicit manual records.
                if policy.kind != .metadata, policy.kind != .chatGPT,
                   connection.verifiedDirectory?.origin != policy.origin {
                    connection.directorySnapshot = .legacy(connection.models.filter { $0.isManual == true })
                }
                return connection
            }
        defaultTextConnectionID = defaults.string(forKey: "Moonread.ai.defaultTextConnection")
        purposeDefaults = AIPersistedJSON.readDictionary(AIPurposeSelection.self, data: defaults.data(forKey: "Moonread.ai.purposeDefaults"), key: "Moonread.ai.purposeDefaults")
        #if DEBUG
        if arguments.contains("--ui-testing"), session != nil, arguments.contains("--ui-test-ai-model-picker") {
            var first = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); first.id = "fixture-first"; first.name = "测试连接甲"
            first.models = [AIModelOption(id: "shared", name: "Same Model", thinking: ["low", "high"], defaultThinking: "low")]
            first.modelID = "shared"; first.thinking = "low"
            if arguments.contains("--ui-test-ai-model-picker-dense") {
                first.models = (1...9).map { AIModelOption(id: "directory-\($0)", name: "测试模型 \($0)", contextWindow: 128000 + $0 * 8000, thinking: ["none", "minimal", "low", "medium", "high", "xhigh"], defaultThinking: "medium") }
                first.modelID = "directory-1"; first.thinking = "medium"
                if arguments.contains("--ui-test-ai-model-reference") {
                    first.models[0].id = "gpt-6-astra"; first.models[0].name = "GPT-6-Astra"; first.modelID = "gpt-6-astra"
                }
            }
            if arguments.contains("--ui-test-chatgpt-capacity") { first.models[0].contextWindow = nil }
            var second = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection(); second.id = "fixture-second"; second.name = "测试连接乙"
            second.models = [AIModelOption(id: "shared", name: "Same Model", thinking: [], defaultThinking: nil)]
            second.modelID = "shared"
            var image = AIProviderPreset.all.first { $0.id == "google" }!.connection()
            image.id = "fixture-image"; image.name = "测试绘图连接"
            image.models = [AIModelOption(id: "image", name: "Image Model", thinking: [], capabilities: .init(text: false, imageOutput: true))]
            connections = [first, second, image]; defaultTextConnectionID = first.id
            [first.id, second.id, image.id].forEach { markAuthorized($0) }
        }
        if arguments.contains("--ui-testing"), session != nil, arguments.contains("--ui-test-ai-key-write-failure") {
            var connection = AIConnection(name: "离线密钥连接", billing: .usage, baseURL: "https://example.com", providerID: "fixture", providerName: "Fixture", wireProtocol: .chat, authMethod: .apiKey)
            connection.id = "fixture-key"; connections = [connection]; markAuthorized(connection.id)
        }
        if arguments.contains("--ui-testing"), session != nil, arguments.contains("--ui-test-ai-login-browser") {
            var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
            connection.id = "fixture-browser"; connection.name = "离线授权连接"
            connections = [connection]
        }
        #endif
        self.availability.didDisable = { [weak self] in self?.cancelAIWork() }
    }
    #if DEBUG
    private func beginOfflineBrowserAuthorization(_ connection: AIConnection) {
        let listener = AIChatGPTLoopback()
        listener.enableOfflineConsentPage()
        loginConnectionID = connection.id; setLoginPresentation(.authorizing, for: connection.id)
        loginTask = Task {
            defer { listener.stop() }
            do {
                let redirect = try await listener.start()
                try Task.checkCancellation()
                let url = redirect.deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixture/authorize")
                let request = AIAuthentication.BrowserAuthorization(id: UUID().uuidString, url: url, expires: .distantFuture)
                setLoginPresentation(.browser(request), for: connection.id)
                for try await _ in listener.callbacks {
                    try Task.checkCancellation()
                    setLoginPresentation(nil, for: connection.id); loginConnectionID = nil
                    markAuthorized(connection.id)
                    if !defaults.bool(forKey: "Moonread.ai.chatGPTWelcomeSeen") { showingChatGPTWelcome = true }
                    return
                }
            } catch { if !Task.isCancelled { setLoginPresentation(.failed(Self.connectionError(error)), for: connection.id); loginConnectionID = nil } }
        }
    }
    #endif
    func addConnection(_ supplied: AIConnection) -> String {
        var connection = supplied
        var suffix = 2
        while connections.contains(where: { $0.name == connection.name }) {
            connection.name = "\(supplied.name) \(suffix)"; suffix += 1
        }
        connections.append(connection)
        if defaultTextConnectionID == nil { defaultTextConnectionID = connection.id }
        saveConnections(); return connection.id
    }
    @discardableResult func saveAPIKey(_ key: String, for id: String) async -> Bool {
        guard let connection = connections.first(where: { $0.id == id }), changingCredentials.insert(id).inserted else { return false }
        credentialErrors[id] = nil
        usage?.suspend(id)
        do {
            // Close content admission before suspending to the credential actor.
            sharing.revoke(id)
            invalidateCatalog(id)
            try await auth.saveAPIKey(key, connection: connection)
            resetCatalog(id)
            markAuthorized(id); credentialRevision += 1
            changingCredentials.remove(id)
            usage?.refresh(id)
            await refreshModels(id)
            return true
        } catch {
            changingCredentials.remove(id)
            credentialErrors[id] = Self.connectionError(error)
            return false
        }
    }
    func saveConnections() {
        do {
            let connectionsData = try AIPersistedJSON.encodeArray(connections, original: defaults.data(forKey: "Moonread.ai.connections"), id: \.id)
            let purposesData = try AIPersistedJSON.encodeDictionary(purposeDefaults, original: defaults.data(forKey: "Moonread.ai.purposeDefaults"))
            defaults.set(connectionsData, forKey: "Moonread.ai.connections")
            defaults.set(defaultTextConnectionID, forKey: "Moonread.ai.defaultTextConnection")
            defaults.set(purposesData, forKey: "Moonread.ai.purposeDefaults")
        } catch { self.error = String(localized: "无法保存 AI 设置。") }
    }
    func isLoggedIn(_ connection: AIConnection) -> Bool {
        _ = credentialRevision
        guard !requiresLogin(connection.id) else { return false }
        if case .available = runtime[connection.id]?.authorization.snapshot { return true }
        return (try? auth.credentials.load(for: connection)) != nil
    }
    func canQueryUsage(_ connection: AIConnection) -> Bool {
        guard !changingCredentials.contains(connection.id) else { return false }
        switch loginState(connection.id) {
        case .authorizing, .browser: return false
        default: return isLoggedIn(connection)
        }
    }
    func isUsingChatGPTPlan(_ connection: AIConnection) -> Bool {
        isLoggedIn(connection) && chatGPTPlanEnabled(connection)
    }
    func chatGPTPlanEnabled(_ connection: AIConnection) -> Bool {
        _ = credentialRevision
        return connection.authMethod == .chatGPT &&
            (try? auth.credentials.load(for: connection))?.oauth?.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true
    }
    func credential(_ connection: AIConnection) async throws -> RuntimeCredential {
        guard !requiresLogin(connection.id) else { throw AIError.loginRequired }
        let generation = availability.generation
        do {
            let value = try await availability.perform {
                try await self.auth.credential(connection, availability: self.availability, generation: generation)
            }
            guard !requiresLogin(connection.id) else { throw AIError.loginRequired }
            return value
        }
        catch AIChatGPTError.refreshExpired(let code, let sessionID) {
            try await confirmLoginInvalid(connection, sessionID: sessionID)
            throw AIChatGPTError.refreshExpired(code, sessionID: sessionID)
        }
    }
    func confirmLoginInvalid(_ connection: AIConnection, sessionID: String?) async throws {
        try availability.requireAvailable()
        guard connections.contains(where: { $0.id == connection.id }),
              try await auth.invalidateSession(connection, sessionID: sessionID),
              try auth.credentials.load(connection.credentialReference) == nil else { return }
        if !requiresLogin(connection.id) { credentialRevision += 1 }
        setAuthorization(.needsLogin(.expiredSession), for: connection.id)
    }
    func chatGPTPlanDisabled(_ connection: AIConnection) -> Bool {
        _ = credentialRevision
        guard connection.authMethod == .chatGPT,
              let account = (try? auth.credentials.load(for: connection))?.oauth?.chatGPT else { return false }
        return !account.scopes.contains("chatgpt.tokens.use.direct")
    }
    func connectionState(_ connection: AIConnection) -> AIConnectionState {
        if let state = loginState(connection.id) {
            switch state {
            case .authorizing: return .authorizing
            case .browser(let request): return .browser(request)
            case .expired: return .expired
            case .failed(let error): return .loginFailed(error)
            }
        }
        if chatGPTPlanDisabled(connection) { return .planPermissionRequired }
        if requiresLogin(connection.id) { return .needsLogin }
        if isRefreshing(connection.id) { return .loadingModels }
        if let error = modelError(connection.id) { return .modelsFailed(error) }
        return isLoggedIn(connection) ? .connected : .signedOut
    }
    func login(_ id: String) {
        guard availability.isAvailable else { return }
        guard let connection = connections.first(where: { $0.id == id }), loginConnectionID == nil, !changingCredentials.contains(id) else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-ai-login-browser"), id == "fixture-browser" {
            beginOfflineBrowserAuthorization(connection); return
        }
        #endif
        sharing.revoke(id)
        loginConnectionID = id; setLoginPresentation(.authorizing, for: id)
        let revision = loginRevision
        loginTask = Task {
            do {
                if connection.authMethod == .openrouter {
                    let request = try await auth.beginOpenRouter()
                    try Task.checkCancellation()
                    guard loginRevision == revision else { return }
                    setLoginPresentation(.browser(request), for: id)
                    return
                }
                let request = try await auth.beginChatGPT(connection)
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                setLoginPresentation(.browser(request), for: id)
                try await auth.finishChatGPT(request.id, reference: connection.credentialReference) {
                    await self.receivedChatGPTCallback(id, revision: revision)
                }
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                sharing.revoke(id); resetCatalog(id)
                markAuthorized(id)
                credentialRevision += 1; loginConnectionID = nil; setLoginPresentation(nil, for: id)
                guard !chatGPTPlanDisabled(connection) else { return }
                if !defaults.bool(forKey: "Moonread.ai.chatGPTWelcomeSeen") { showingChatGPTWelcome = true }
                await refreshModels(id)
            } catch {
                guard loginRevision == revision else { return }
                if !Task.isCancelled {
                    if case AIError.cancelled = error { setLoginPresentation(nil, for: id) }
                    else if case AIError.authorizationExpired = error { setLoginPresentation(.expired, for: id) }
                    else { setLoginPresentation(.failed(Self.connectionError(error)), for: id) }
                }
                loginConnectionID = nil
            }
        }
    }
    private func receivedChatGPTCallback(_ id: String, revision: UUID) {
        guard loginRevision == revision, loginConnectionID == id else { return }
        // Removes the browser immediately; token exchange continues behind an in-app progress state.
        setLoginPresentation(.authorizing, for: id)
    }
    func submitAuthorizationCode(_ code: String, connectionID id: String) {
        guard availability.isAvailable else { return }
        guard let connection = connections.first(where: { $0.id == id }), connection.authMethod == .openrouter,
              case .browser(let request) = loginState(id), loginConnectionID == id else { return }
        let revision = loginRevision
        setLoginPresentation(.authorizing, for: id)
        loginTask = Task {
            do {
                try await auth.finishOpenRouter(request.id, code: code, reference: connection.credentialReference)
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                sharing.revoke(id); resetCatalog(id)
                markAuthorized(id)
                credentialRevision += 1; loginConnectionID = nil; setLoginPresentation(nil, for: id)
                usage?.refresh(id)
                await refreshModels(id)
            } catch {
                guard loginRevision == revision else { return }
                loginConnectionID = nil
                if !Task.isCancelled { setLoginPresentation(.failed(Self.connectionError(error)), for: id) }
            }
        }
    }
    func cancelLogin(_ id: String? = nil) {
        if let id, loginConnectionID != id { return }
        if let active = loginConnectionID {
            if case .browser(let request) = loginState(active) {
                Task { await auth.cancelBrowserAuthorization(request.id) }
            }
            setLoginPresentation(nil, for: active)
        }
        loginRevision = UUID(); loginTask?.cancel(); loginTask = nil; loginConnectionID = nil
    }
    func browserPresentationFailed(_ id: String, url: URL, error: Error) {
        guard loginConnectionID == id, case .browser(let request) = loginState(id), request.url == url else { return }
        // OpenRouter's headless PKCE requires returning from the browser to paste its code.
        // Closing that browser keeps the existing code-entry attempt; explicit Cancel ends it.
        if connections.first(where: { $0.id == id })?.authMethod == .openrouter,
           case AIChatGPTError.loginCancelled = error { return }
        cancelLogin(id)
        setLoginPresentation(.failed(Self.connectionError(error)), for: id)
    }
    @discardableResult func logout(_ id: String, forgetRegistration: Bool = false) async -> Bool {
        guard let connection = connections.first(where: { $0.id == id }), changingCredentials.insert(id).inserted else { return false }
        defer { changingCredentials.remove(id) }
        usage?.suspend(id)
        sharing.revoke(id)
        cancelLogin(id)
        cancelNativeRequests(connectionID: id)
        invalidateCatalog(id)
        do {
            try await auth.logout(connection, forgetRegistration: forgetRegistration); setAuthorization(.disconnected, for: id)
            resetCatalog(id)
            setLoginPresentation(nil, for: id); accountCatalogAttempts[id] = nil; credentialRevision += 1
            return true
        } catch {
            publishDirectoryError(connection.authMethod == .chatGPT ? Self.connectionError(error) : String(localized: "无法移除 AI 凭证。"), for: id)
            return false
        }
    }
    func removeConnection(_ id: String) async -> Bool {
        guard await logout(id, forgetRegistration: true) else { return false }
        connections.removeAll { $0.id == id }
        if defaultTextConnectionID == id { defaultTextConnectionID = nil }
        purposeDefaults = purposeDefaults.filter { $0.value.connectionID != id }
        accountCatalogAttempts[id] = nil; modelRevisions[id] = nil; runtime[id] = nil
        saveConnections()
        return true
    }
    @discardableResult func addManualModel(connectionID: String, id: String, context: String, output: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, let capacity = Int(context.trimmingCharacters(in: .whitespacesAndNewlines)), capacity > 0,
              let index = connections.firstIndex(where: { $0.id == connectionID }), connections[index].authMethod != .chatGPT else { return false }
        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = connections[index].models.firstIndex(where: { $0.id == id })
        let maxOutput = output.isEmpty ? existing.flatMap { connections[index].models[$0].maxOutput } : Int(output)
        guard (output.isEmpty || maxOutput != nil), maxOutput.map({ $0 > 0 && $0 <= capacity }) ?? true else { return false }
        if let existing {
            if connections[index].models[existing].isManual != true,
               [.account, .service].contains(connections[index].models[existing].directoryOrigin) {
                connections[index].models[existing].connectionContextLimit = connections[index].models[existing].contextWindow
                connections[index].models[existing].connectionOutputLimit = connections[index].models[existing].maxOutput
            }
            connections[index].models[existing].contextWindow = capacity
            connections[index].models[existing].maxOutput = maxOutput
            connections[index].models[existing].isManual = true
        } else {
            connections[index].models.append(.init(id: id, name: id, contextWindow: capacity,
                thinking: [], maxOutput: maxOutput, isManual: true))
        }
        if AIModelDirectoryPolicy.policy(connections[index]).filtered, connections[index].modelsOrigin == .account,
           let model = connections[index].models.firstIndex(where: { $0.id == id }), connections[index].models[model].directoryOrigin != .account {
            connections[index].models[model].isListed = false
        }
        connections[index].disabledModelIDs.remove(id)
        if connections[index].modelChoice.id == nil, let model = model(id, in: connections[index]), AINativeCapabilities.supportsText(connection: connections[index], model: model) { connections[index].modelID = id }
        saveConnections(); return true
    }
    @discardableResult func setChatGPTContextBudget(connectionID: String, modelID: String, value: String) -> Bool {
        guard let capacity = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)), capacity > 0,
              let index = connections.firstIndex(where: { $0.id == connectionID && $0.authMethod == .chatGPT }),
              let model = connections[index].models.firstIndex(where: { $0.id == modelID }),
              connections[index].models[model].contextWindow == nil || connections[index].models[model].isManual == true else { return false }
        connections[index].models[model].contextWindow = capacity
        connections[index].models[model].isManual = true
        saveConnections(); return true
    }
    func setModels(_ ids: [String], enabled: Bool, connectionID: String) {
        guard let index = connections.firstIndex(where: { $0.id == connectionID }) else { return }
        if enabled { connections[index].disabledModelIDs.subtract(ids) }
        else { connections[index].disabledModelIDs.formUnion(ids) }
        saveConnections()
    }
    func isEnabled(modelID: String, in connection: AIConnection) -> Bool {
        !connection.disabledModelIDs.contains(modelID)
    }
    func matches(_ model: AIModelOption, in connection: AIConnection, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [model.name, model.id, connection.name].contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }
    func model(_ id: String, in connection: AIConnection) -> AIModelOption? {
        connection.models.first(where: { $0.id == id }).map { catalog.option($0, providerID: connection.catalogID, authentication: connection.authMethod) }
    }
    func model(connectionID: String, modelID: String) -> AIModelOption? {
        connections.first(where: { $0.id == connectionID }).flatMap { model(modelID, in: $0) }
    }
    func refreshCatalogsIfNeeded() async {
        try? await availability.perform {
            self.catalogActivated = true
            #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            #endif
            await self.catalog.refresh()
            try self.availability.requireAvailable()
            await self.refreshConnectionCatalogsIfNeeded()
        }
    }
    // Entry points read the persisted connection snapshots; only stale snapshots use IO.
    func refreshConnectionCatalogsIfNeeded(now: Date? = nil) async {
        let instant = now ?? auth.now()
        try? await availability.perform {
            for connection in self.connections where self.isLoggedIn(connection) && !self.chatGPTPlanDisabled(connection) &&
                instant.timeIntervalSince(self.accountCatalogAttempts[connection.id] ?? (connection.authMethod == .chatGPT || connection.modelsIdentity == connection.catalogIdentity ? connection.modelsChecked : nil) ?? .distantPast) >= 86400 {
                try self.availability.requireAvailable()
                await self.refreshModels(connection.id, refreshPublic: false)
            }
        }
    }
    private func invalidateCatalog(_ id: String) {
        modelTasks.removeValue(forKey: id)?.cancel()
        modelRevisions[id] = nil; finishDirectoryRefresh(id); accountCatalogAttempts[id] = nil
    }
    private func resetCatalog(_ id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        invalidateCatalog(id)
        connections[index].catalogCredentialGeneration = UUID()
        let manuals = connections[index].authMethod == .chatGPT ? [] : connections[index].models.filter { $0.isManual == true }.map {
            AIModelOption(id: $0.id, name: $0.name, contextWindow: $0.contextWindow, thinking: [], maxOutput: $0.maxOutput, isManual: true)
        }
        connections[index].directorySnapshot = .legacy(manuals)
        runtime[id, default: ConnectionRuntime()].directory = .idle
        // Persist the reset before refresh can suspend or fail, so the old
        // credential’s directory cannot return after restarting the app.
        saveConnections()
    }
    func refreshModels(_ id: String, refreshPublic: Bool = true) async {
        guard availability.isAvailable, !Task.isCancelled else { return }
        if let task = modelTasks[id] { await task.value; return }
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        let revision = UUID(); modelRevisions[id] = revision
        let job = Task { await self.readDirectory(connection, revision: revision, refreshPublic: refreshPublic) }
        modelTasks[id] = job
        await job.value
        if modelRevisions[id] == revision { modelTasks[id] = nil }
    }
    private func readDirectory(_ connection: AIConnection, revision: UUID, refreshPublic: Bool) async {
        let id = connection.id, policy = AIModelDirectoryPolicy.policy(connection)
        accountCatalogAttempts[id] = auth.now()
        runtime[id, default: ConnectionRuntime()].directory = .refreshing(previous: connection.directorySnapshot)
        modelNotices[id] = nil
        defer { if modelRevisions[id] == revision { finishDirectoryRefresh(id) } }
        func currentIndex() -> Int? {
            guard !Task.isCancelled, availability.isAvailable, modelRevisions[id] == revision else { return nil }
            return connections.firstIndex { $0.id == id && $0.catalogIdentity == connection.catalogIdentity }
        }
        var sessionID: String?
        do {
            if refreshPublic && connection.authMethod != .chatGPT { await catalog.refresh(force: true) }
            guard currentIndex() != nil else { return }
            let models: [AIModelOption]
            var checked = auth.now()
            switch policy.kind {
            case .metadata:
                guard !catalog.publicRefreshFailed else { throw AIError.invalidResponse }
                models = catalog.models(for: connection)
            case .service:
                let snapshot = try await catalog.serviceModels(connection, auth: auth, force: refreshPublic, now: auth.now())
                models = snapshot.models; checked = snapshot.checked
            case .account, .custom, .chatGPT:
                let token = try await credential(connection); sessionID = token.sessionID
                models = try await auth.directory(connection, credential: token)
            }
            guard let index = currentIndex() else { return }
            if policy.kind == .account || policy.kind == .custom || policy.kind == .chatGPT {
                markAuthorized(id)
            }
            let manuals = connections[index].models.filter { $0.isManual == true }
            var merged = models.map { discovered in
                guard let manual = manuals.first(where: { $0.id == discovered.id }) else { return discovered }
                if connection.authMethod == .chatGPT, discovered.contextWindow != nil {
                    modelNotices[id] = String(localized: "账户目录已提供容量，现已改用目录值。")
                    return discovered
                }
                var result = discovered
                if connection.authMethod != .chatGPT, policy.kind != .metadata {
                    result.connectionContextLimit = discovered.contextWindow; result.connectionOutputLimit = discovered.maxOutput
                }
                result.contextWindow = manual.contextWindow; result.maxOutput = manual.maxOutput; result.isManual = true
                return result
            }
            if connection.authMethod != .chatGPT {
                merged += manuals.filter { manual in !models.contains { $0.id == manual.id } }.map {
                    AIModelOption(id: $0.id, name: $0.name, contextWindow: $0.contextWindow, thinking: [], maxOutput: $0.maxOutput,
                                  isManual: true, isListed: policy.filtered ? false : nil)
                }
            }
            let snapshot = AIDirectorySnapshot.fetched(.init(models: merged, checked: checked, origin: policy.origin, identity: connection.catalogIdentity))
            connections[index].directorySnapshot = snapshot
            runtime[id, default: ConnectionRuntime()].directory = .ready(snapshot)
            if case .unselected = connections[index].modelChoice {
                let first = merged.map { catalog.option($0, providerID: connection.catalogID, authentication: connection.authMethod) }.first {
                    AINativeCapabilities.supportsText(connection: connection, model: $0) && !connections[index].disabledModelIDs.contains($0.id)
                }
                if let first { connections[index].modelChoice = .selected(id: first.id, thinking: first.defaultThinking) }
            }
            saveConnections()
        } catch {
            guard let index = currentIndex() else { return }
            // Only metadata-only presets use P as a model list. A/S failures
            // retain a successful directory or manual records, never public IDs.
            if policy.kind == .metadata, connections[index].modelsOrigin == nil, connections[index].models.isEmpty {
                connections[index].models = catalog.models(for: connection); saveConnections()
            }
            if connection.authMethod == .chatGPT {
                switch error {
                case AIError.loginRequired:
                    try? await confirmLoginInvalid(connection, sessionID: nil)
                case AIError.http(401):
                    try? await confirmLoginInvalid(connection, sessionID: sessionID)
                default: break
                }
            } else if policy.kind != .service, case AIError.http(401) = error {
                setAuthorization(.needsLogin(.directoryRejected), for: id); credentialRevision += 1
            }
            guard currentIndex() != nil else { return }
            let message: String
            if case AIError.http(403) = error {
                message = String(localized: "没有读取模型目录的权限。已有模型配置仍会保留。")
            } else if case AIError.http(401) = error {
                message = String(localized: "无法读取模型目录，请检查此连接的凭证。")
            } else { message = Self.connectionError(error) }
            publishDirectoryError(message, for: id)
        }
    }
    func directorySummary(_ connection: AIConnection) -> String {
        if connection.authMethod == .chatGPT { return String(localized: "型号来自当前 ChatGPT 账户目录。") }
        if AIModelDirectoryPolicy.policy(connection).kind == .metadata {
            return String(localized: "型号与能力来自公开资料，尚未用此连接核实。")
        }
        guard let origin = connection.verifiedDirectory?.origin else {
            return String(localized: "尚未取得模型目录，请刷新重试。")
        }
        switch origin {
        case .metadata: return String(localized: "型号与能力来自公开资料，尚未用此连接核实。")
        case .service: return String(localized: "型号来自官方公共目录，不代表此连接的密钥有效。")
        case .account:
            return AIModelDirectoryPolicy.policy(connection).filtered ? String(localized: "型号来自此连接的目录，已应用账户筛选。") : String(localized: "型号来自此连接读取的官方目录，不代表每个型号均有调用权限。")
        }
    }
    func purposeSelection(_ purpose: AIModelPurpose) -> AIPurposeSelection? {
        guard availability.isAvailable else { return nil }
        guard let value = purposeDefaults[purpose], let connection = connections.first(where: { $0.id == value.connectionID }),
              let model = model(value.modelID, in: connection), AINativeCapabilities.supports(purpose, connection: connection, model: model) else { return nil }
        return value
    }
    @discardableResult func setPurpose(_ purpose: AIModelPurpose, selection: AIPurposeSelection?) -> Bool {
        if let selection {
            guard let connection = connections.first(where: { $0.id == selection.connectionID }),
                  let model = model(selection.modelID, in: connection), AINativeCapabilities.supports(purpose, connection: connection, model: model) else { return false }
        }
        purposeDefaults[purpose] = selection; saveConnections(); return true
    }
    func trackNativeRequest(connectionID: String, kind: NativeRequestKind = .content, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        let id = try availability.register(cancel: cancel); nativeRequests[id] = (connectionID, kind, cancel); return id
    }
    func cancelAIWork() {
        usage?.cancelAllAndClear()
        cancelLogin()
        catalog.cancelRefresh()
        for task in modelTasks.values { task.cancel() }; modelTasks.removeAll()
        for id in refreshingModels { invalidateCatalog(id) }
        for request in nativeRequests.values { request.cancel() }
        for request in sharing.requests { sharing.cancel(owner: request.owner) }
        showingChatGPTWelcome = false
    }
    func cancelNativeRequests(connectionID: String) {
        // Sharing revocation cancels content tasks only; billing sends no book or chat content.
        for request in nativeRequests.values where request.connectionID == connectionID && request.kind == .content { request.cancel() }
    }
    func finishNativeRequest(_ id: UUID) { nativeRequests[id] = nil; availability.finish(id) }
    static func connectionError(_ error: Error) -> String {
        if error is AIAvailability.Unavailable { return error.localizedDescription }
        if let error = AIChatGPTResponses.failure(error) { return error.localizedDescription }
        if let error = error as? AIError { return error.localizedDescription }
        if let error = error as? URLError {
            if error.code == .notConnectedToInternet { return String(localized: "网络不可用，请稍后重试。") }
            if error.code == .timedOut { return String(localized: "AI 请求超时，请重试。") }
        }
        return String(localized: "连接请求未完成，请稍后重试。")
    }
    func acknowledgeChatGPTWelcome() {
        defaults.set(true, forKey: "Moonread.ai.chatGPTWelcomeSeen"); showingChatGPTWelcome = false
    }
}
