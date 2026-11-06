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
    private(set) var catalogActivated = false
    @ObservationIgnored private var accountCatalogAttempts: [String: Date] = [:]
    let sharing: AIDataSharingConsent
    var connections: [AIConnection] = [] {
        didSet {
            for old in oldValue {
                guard let new = connections.first(where: { $0.id == old.id }),
                      old.baseURL == new.baseURL, old.providerID == new.providerID,
                      old.protocolIdentity == new.protocolIdentity, old.catalogCredentialGeneration == new.catalogCredentialGeneration else {
                    sharing.revoke(old.id); invalidateCatalog(old.id)
                    if let index = connections.firstIndex(where: { $0.id == old.id }) {
                        connections[index].models = connections[index].models.filter { $0.isManual == true }.map {
                            AIModelOption(id: $0.id, name: $0.name, contextWindow: $0.contextWindow, thinking: [], maxOutput: $0.maxOutput, isManual: true)
                        }
                        connections[index].modelsChecked = nil; connections[index].modelsOrigin = nil; connections[index].modelsIdentity = nil
                    }
                    continue
                }
            }
        }
    }
    var defaultTextConnectionID: String?
    private(set) var purposeDefaults: [AIModelPurpose: AIPurposeSelection] = [:]
    @ObservationIgnored private var nativeRequests: [UUID: (String, @Sendable () -> Void)] = [:]
    var error: String?
    var credentialRevision = 0
    var loginConnectionID: String?
    var loginStates: [String: AILoginState] = [:]
    var showingChatGPTWelcome = false
    var modelErrors: [String: String] = [:]
    var modelNotices: [String: String] = [:]
    var credentialErrors: [String: String] = [:]
    var needsLogin = Set<String>()
    private var authenticatedConnections = Set<String>()
    @ObservationIgnored private var modelRevisions: [String: UUID] = [:]
    @ObservationIgnored private var modelTasks: [String: Task<Void, Never>] = [:]
    var refreshingModels = Set<String>()
    @ObservationIgnored let auth: AIAuthentication
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var loginRevision = UUID()
    init(defaults: UserDefaults, auth: AIAuthentication, catalog: AIModelCatalog? = nil, sharing: AIDataSharingConsent? = nil, availability: AIAvailability? = nil) {
        self.availability = availability ?? AIAvailability(defaults: defaults)
        self.sharing = sharing ?? AIDataSharingConsent(defaults: defaults)
        self.catalog = catalog ?? AIModelCatalog()
        self.defaults = defaults; self.auth = auth
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
                   connection.modelsOrigin != policy.origin || connection.modelsIdentity != connection.catalogIdentity {
                    connection.models.removeAll { $0.isManual != true }
                    connection.modelsChecked = nil; connection.modelsOrigin = nil; connection.modelsIdentity = nil
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
            authenticatedConnections = [first.id, second.id, image.id]
        }
        if arguments.contains("--ui-testing"), session != nil, arguments.contains("--ui-test-ai-key-write-failure") {
            var connection = AIConnection(name: "离线密钥连接", billing: .usage, baseURL: "https://example.com", providerID: "fixture", providerName: "Fixture", wireProtocol: .chat, authMethod: .apiKey)
            connection.id = "fixture-key"; connections = [connection]; authenticatedConnections = [connection.id]
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
        loginConnectionID = connection.id; loginStates[connection.id] = .authorizing
        loginTask = Task {
            defer { listener.stop() }
            do {
                let redirect = try await listener.start()
                try Task.checkCancellation()
                let url = redirect.deletingLastPathComponent().deletingLastPathComponent().appending(path: "fixture/authorize")
                let request = AIAuthentication.BrowserAuthorization(id: UUID().uuidString, url: url, expires: .distantFuture)
                loginStates[connection.id] = .browser(request)
                for try await _ in listener.callbacks {
                    try Task.checkCancellation()
                    loginStates[connection.id] = nil; loginConnectionID = nil
                    authenticatedConnections.insert(connection.id)
                    if !defaults.bool(forKey: "Moonread.ai.chatGPTWelcomeSeen") { showingChatGPTWelcome = true }
                    return
                }
            } catch { if !Task.isCancelled { loginStates[connection.id] = .failed(Self.connectionError(error)); loginConnectionID = nil } }
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
        guard let connection = connections.first(where: { $0.id == id }) else { return false }
        credentialErrors[id] = nil
        do {
            // Close content admission before suspending to the credential actor.
            sharing.revoke(id)
            invalidateCatalog(id)
            try await auth.saveAPIKey(key, connection: connection)
            resetCatalog(id)
            authenticatedConnections.insert(id); needsLogin.remove(id); credentialRevision += 1
            await refreshModels(id)
            return true
        } catch { credentialErrors[id] = Self.connectionError(error); return false }
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
        guard !needsLogin.contains(connection.id) else { return false }
        return authenticatedConnections.contains(connection.id) || (try? auth.credentials.load(connection.credentialReference)) != nil
    }
    func isUsingChatGPTPlan(_ connection: AIConnection) -> Bool {
        isLoggedIn(connection) && chatGPTPlanEnabled(connection)
    }
    func chatGPTPlanEnabled(_ connection: AIConnection) -> Bool {
        _ = credentialRevision
        return connection.authMethod == .chatGPT &&
            (try? auth.credentials.load(connection.credentialReference))?.chatGPT?.scopes.contains("chatgpt.tokens.use.direct") == true
    }
    func credential(_ connection: AIConnection) async throws -> AICredential {
        guard !needsLogin.contains(connection.id) else { throw AIError.loginRequired }
        let generation = availability.generation
        do {
            let value = try await availability.perform {
                try await self.auth.credential(connection, availability: self.availability, generation: generation)
            }
            guard !needsLogin.contains(connection.id) else { throw AIError.loginRequired }
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
        authenticatedConnections.remove(connection.id)
        if needsLogin.insert(connection.id).inserted { credentialRevision += 1 }
    }
    func chatGPTPlanDisabled(_ connection: AIConnection) -> Bool {
        _ = credentialRevision
        guard connection.authMethod == .chatGPT,
              let account = (try? auth.credentials.load(connection.credentialReference))?.chatGPT else { return false }
        return !account.scopes.contains("chatgpt.tokens.use.direct")
    }
    func connectionState(_ connection: AIConnection) -> AIConnectionState {
        if let state = loginStates[connection.id] {
            switch state {
            case .authorizing: return .authorizing
            case .browser(let request): return .browser(request)
            case .expired: return .expired
            case .failed(let error): return .loginFailed(error)
            }
        }
        if chatGPTPlanDisabled(connection) { return .planPermissionRequired }
        if needsLogin.contains(connection.id) { return .needsLogin }
        if refreshingModels.contains(connection.id) { return .loadingModels }
        if let error = modelErrors[connection.id] { return .modelsFailed(error) }
        return isLoggedIn(connection) ? .connected : .signedOut
    }
    func login(_ id: String) {
        guard availability.isAvailable else { return }
        guard let connection = connections.first(where: { $0.id == id }), loginConnectionID == nil else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-ai-login-browser"), id == "fixture-browser" {
            beginOfflineBrowserAuthorization(connection); return
        }
        #endif
        sharing.revoke(id)
        loginConnectionID = id; loginStates[id] = .authorizing
        let revision = loginRevision
        loginTask = Task {
            do {
                if connection.authMethod == .openrouter {
                    let request = try await auth.beginOpenRouter()
                    try Task.checkCancellation()
                    guard loginRevision == revision else { return }
                    loginStates[id] = .browser(request)
                    return
                }
                let request = try await auth.beginChatGPT(connection)
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                loginStates[id] = .browser(request)
                try await auth.finishChatGPT(request.id, reference: connection.credentialReference) {
                    await self.receivedChatGPTCallback(id, revision: revision)
                }
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                if let index = connections.firstIndex(where: { $0.id == id }) { connections[index].modelsChecked = nil; saveConnections() }
                sharing.revoke(id); resetCatalog(id)
                authenticatedConnections.insert(id); needsLogin.remove(id); modelErrors[id] = nil
                credentialRevision += 1; loginConnectionID = nil; loginStates[id] = nil
                guard !chatGPTPlanDisabled(connection) else { return }
                if !defaults.bool(forKey: "Moonread.ai.chatGPTWelcomeSeen") { showingChatGPTWelcome = true }
                await refreshModels(id)
            } catch {
                guard loginRevision == revision else { return }
                if !Task.isCancelled {
                    if case AIError.cancelled = error { loginStates[id] = nil }
                    else if case AIError.authorizationExpired = error { loginStates[id] = .expired }
                    else { loginStates[id] = .failed(Self.connectionError(error)) }
                }
                loginConnectionID = nil
            }
        }
    }
    private func receivedChatGPTCallback(_ id: String, revision: UUID) {
        guard loginRevision == revision, loginConnectionID == id else { return }
        // Removes the browser immediately; token exchange continues behind an in-app progress state.
        loginStates[id] = .authorizing
    }
    func submitAuthorizationCode(_ code: String, connectionID id: String) {
        guard availability.isAvailable else { return }
        guard let connection = connections.first(where: { $0.id == id }), connection.authMethod == .openrouter,
              case .browser(let request) = loginStates[id], loginConnectionID == id else { return }
        let revision = loginRevision
        loginStates[id] = .authorizing
        loginTask = Task {
            do {
                try await auth.finishOpenRouter(request.id, code: code, reference: connection.credentialReference)
                try Task.checkCancellation(); guard loginRevision == revision else { return }
                sharing.revoke(id); resetCatalog(id)
                authenticatedConnections.insert(id); needsLogin.remove(id); modelErrors[id] = nil
                credentialRevision += 1; loginConnectionID = nil; loginStates[id] = nil
                await refreshModels(id)
            } catch {
                guard loginRevision == revision else { return }
                loginConnectionID = nil
                if !Task.isCancelled { loginStates[id] = .failed(Self.connectionError(error)) }
            }
        }
    }
    func cancelLogin(_ id: String? = nil) {
        if let id, loginConnectionID != id { return }
        if let active = loginConnectionID {
            if case .browser(let request) = loginStates[active] {
                Task { await auth.cancelBrowserAuthorization(request.id) }
            }
            loginStates[active] = nil
        }
        loginRevision = UUID(); loginTask?.cancel(); loginTask = nil; loginConnectionID = nil
    }
    func browserPresentationFailed(_ id: String, url: URL, error: Error) {
        guard loginConnectionID == id, case .browser(let request) = loginStates[id], request.url == url else { return }
        // OpenRouter's headless PKCE requires returning from the browser to paste its code.
        // Closing that browser keeps the existing code-entry attempt; explicit Cancel ends it.
        if connections.first(where: { $0.id == id })?.authMethod == .openrouter,
           case AIChatGPTError.loginCancelled = error { return }
        cancelLogin(id)
        loginStates[id] = .failed(Self.connectionError(error))
    }
    @discardableResult func logout(_ id: String, forgetRegistration: Bool = false) async -> Bool {
        guard let connection = connections.first(where: { $0.id == id }) else { return false }
        sharing.revoke(id)
        cancelLogin(id)
        for request in nativeRequests.values where request.0 == id { request.1() }
        invalidateCatalog(id)
        do {
            try await auth.logout(connection, forgetRegistration: forgetRegistration); authenticatedConnections.remove(id); needsLogin.remove(id)
            resetCatalog(id); saveConnections()
            loginStates[id] = nil; modelErrors[id] = nil; accountCatalogAttempts[id] = nil; credentialRevision += 1
            return true
        } catch {
            modelErrors[id] = connection.authMethod == .chatGPT ? Self.connectionError(error) : String(localized: "无法移除 AI 凭证。")
            return false
        }
    }
    func removeConnection(_ id: String) async -> Bool {
        guard await logout(id, forgetRegistration: true) else { return false }
        connections.removeAll { $0.id == id }
        if defaultTextConnectionID == id { defaultTextConnectionID = nil }
        purposeDefaults = purposeDefaults.filter { $0.value.connectionID != id }
        accountCatalogAttempts[id] = nil; modelRevisions[id] = nil
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
        if connections[index].modelID.isEmpty, let model = model(id, in: connections[index]), AINativeCapabilities.supportsText(connection: connections[index], model: model) { connections[index].modelID = id }
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
        modelRevisions[id] = nil; refreshingModels.remove(id); accountCatalogAttempts[id] = nil
    }
    private func resetCatalog(_ id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        invalidateCatalog(id)
        connections[index].catalogCredentialGeneration = UUID()
        connections[index].models = connections[index].authMethod == .chatGPT ? [] : connections[index].models.filter { $0.isManual == true }.map {
            AIModelOption(id: $0.id, name: $0.name, contextWindow: $0.contextWindow, thinking: [], maxOutput: $0.maxOutput, isManual: true)
        }
        connections[index].modelsChecked = nil; connections[index].modelsOrigin = nil; connections[index].modelsIdentity = nil
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
        accountCatalogAttempts[id] = auth.now(); refreshingModels.insert(id)
        modelErrors[id] = nil; modelNotices[id] = nil
        defer { if modelRevisions[id] == revision { refreshingModels.remove(id) } }
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
                authenticatedConnections.insert(id); needsLogin.remove(id)
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
            connections[index].models = merged
            connections[index].modelsOrigin = policy.origin
            connections[index].modelsIdentity = connection.catalogIdentity
            connections[index].modelsChecked = checked
            if connections[index].modelID.isEmpty {
                let first = merged.map { catalog.option($0, providerID: connection.catalogID, authentication: connection.authMethod) }.first {
                    AINativeCapabilities.supportsText(connection: connection, model: $0) && !connections[index].disabledModelIDs.contains($0.id)
                }
                connections[index].modelID = first?.id ?? ""; connections[index].thinking = first?.defaultThinking
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
                needsLogin.insert(id); credentialRevision += 1
            }
            if case AIError.http(403) = error {
                modelErrors[id] = String(localized: "没有读取模型目录的权限。已有模型配置仍会保留。")
            } else if case AIError.http(401) = error {
                modelErrors[id] = String(localized: "无法读取模型目录，请检查此连接的凭证。")
            } else { modelErrors[id] = Self.connectionError(error) }
        }
    }
    func directorySummary(_ connection: AIConnection) -> String {
        if connection.authMethod == .chatGPT { return String(localized: "型号来自当前 ChatGPT 账户目录。") }
        if AIModelDirectoryPolicy.policy(connection).kind == .metadata {
            return String(localized: "型号与能力来自公开资料，尚未用此连接核实。")
        }
        guard connection.modelsIdentity == connection.catalogIdentity, let origin = connection.modelsOrigin else {
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
    func trackNativeRequest(connectionID: String, cancel: @escaping @Sendable () -> Void) throws -> UUID {
        let id = try availability.register(cancel: cancel); nativeRequests[id] = (connectionID, cancel); return id
    }
    func cancelAIWork() {
        cancelLogin()
        catalog.cancelRefresh()
        for task in modelTasks.values { task.cancel() }; modelTasks.removeAll()
        for id in refreshingModels { modelRevisions[id] = nil; accountCatalogAttempts[id] = nil }
        refreshingModels.removeAll()
        for request in nativeRequests.values { request.1() }
        for request in sharing.requests { sharing.cancel(owner: request.owner) }
        showingChatGPTWelcome = false
    }
    func cancelNativeRequests(connectionID: String) {
        for request in nativeRequests.values where request.0 == connectionID { request.1() }
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
