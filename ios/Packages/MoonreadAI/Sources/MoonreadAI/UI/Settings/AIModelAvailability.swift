import Foundation

/// Shared selectors present capability-compatible models (and a stale selected value),
/// while credential/model state explains why a visible choice cannot be used.
@MainActor public enum AIModelAvailability {
    public static func supports(_ model: AIModelOption, purpose: AIModelPurpose?, connection: AIConnection) -> Bool {
        if let purpose { return AINativeCapabilities.supports(purpose, connection: connection, model: model) }
        return AINativeCapabilities.supportsText(connection: connection, model: model)
    }
    public static func reason(_ model: AIModelOption, purpose: AIModelPurpose?, connection: AIConnection, providers: AIConnectionService) -> String? {
        if model.isListed == false { return String(localized: "此连接的目录未列出该型号") }
        if connection.authMethod != .chatGPT, model.isManual != true, model.capabilities?.text == nil && model.capabilities?.imageOutput == nil {
            return String(localized: "能力资料尚未补齐")
        }
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
