import Foundation

struct AIModelSelection: Equatable {
    var connectionID: String
    var modelID: String
    var thinking: String?
    static func defaultThinking(_ model: AIModelOption) -> String? {
        model.defaultThinking.flatMap { model.thinking.contains($0) ? $0 : nil }
    }
    mutating func select(_ model: AIModelOption, connection: AIConnection) {
        if connectionID != connection.id || modelID != model.id {
            connectionID = connection.id; modelID = model.id; thinking = Self.defaultThinking(model)
        } else { thinking = thinking.flatMap { model.thinking.contains($0) ? $0 : nil } ?? Self.defaultThinking(model) }
    }
}
enum AIModelSelectionTarget: Equatable { case conversation(String), session(String), defaults }

extension AIService {
    func modelSelection(for target: AIModelSelectionTarget) -> AIModelSelection? {
        let connectionID: String?, modelID: String?, thinking: String?
        switch target {
        case .defaults: connectionID = providers.defaultTextConnectionID; modelID = nil; thinking = nil
        case .conversation(let id), .session(let id):
            guard let value = conversation(id) else { return nil }
            connectionID = value.connectionID ?? providers.defaultTextConnectionID
            modelID = value.modelID.flatMap { $0.isEmpty ? nil : $0 }; thinking = value.thinking
        }
        guard let connection = providers.connections.first(where: { $0.id == connectionID }),
              let model = providers.model(modelID ?? connection.modelID, in: connection) else { return nil }
        let effort = thinking ?? (modelID == nil && model.id == connection.modelID ? connection.thinking : nil)
        return AIModelSelection(connectionID: connection.id, modelID: model.id,
                                thinking: effort.flatMap { model.thinking.contains($0) ? $0 : nil } ?? AIModelSelection.defaultThinking(model))
    }
    @discardableResult func applyModelSelection(_ selection: AIModelSelection, to target: AIModelSelectionTarget) async -> Bool {
        guard let index = providers.connections.firstIndex(where: { $0.id == selection.connectionID }),
              let model = providers.model(selection.modelID, in: providers.connections[index]),
              selection.thinking == nil || model.thinking.contains(selection.thinking!) else { return false }
        guard model.capabilities?.text != false else { return false }
        let thinking = selection.thinking ?? AIModelSelection.defaultThinking(model)
        switch target {
        case .defaults:
            providers.defaultTextConnectionID = selection.connectionID
            providers.connections[index].modelID = selection.modelID; providers.connections[index].thinking = thinking
            providers.saveConnections(); return true
        case .conversation(let id), .session(let id):
            guard let value = conversation(id) else { return false }
            do {
                try await selectRuntime(.init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: thinking), conversation: value)
                return true
            } catch { return false }
        }
    }
}

extension AIModelSelectionTarget {
    var isDefault: Bool { if case .defaults = self { true } else { false } }
}

/// Shared selectors present capability-compatible models (and a stale selected value),
/// while credential/model state explains why a visible choice cannot be used.
@MainActor enum AIModelAvailability {
    static func supports(_ model: AIModelOption, purpose: AIModelPurpose?, connection: AIConnection) -> Bool {
        if let purpose { return AINativeCapabilities.supports(purpose, connection: connection, model: model) }
        return model.capabilities?.text != false
    }
    static func reason(_ model: AIModelOption, purpose: AIModelPurpose?, connection: AIConnection, providers: AIConnectionService) -> String? {
        guard supports(model, purpose: purpose, connection: connection) else { return String(localized: "不支持该用途") }
        switch providers.connectionState(connection) {
        case .signedOut, .expired, .needsLogin, .loginFailed, .authorizing, .browser:
            return String(localized: "未登录")
        case .planPermissionRequired: return String(localized: "你没有允许月读使用 ChatGPT 套餐")
        default: break
        }
        if !providers.isLoggedIn(connection) { return String(localized: "未登录") }
        if !providers.isEnabled(modelID: model.id, in: connection) { return String(localized: "未启用") }
        return nil
    }
}
