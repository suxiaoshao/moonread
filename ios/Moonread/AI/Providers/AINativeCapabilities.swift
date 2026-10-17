import Foundation

/// Purpose selection never changes the current conversation's model.
enum AIModelPurpose: String, Codable, CaseIterable, Sendable {
    case search, image
    var title: String { self == .search ? String(localized: "联网搜索") : String(localized: "图片生成") }
}
struct AIPurposeSelection: Codable, Equatable, Sendable {
    var connectionID: String
    var modelID: String
}

/// Explicit supported hosted-tool routes, not inferred from generic tool_call metadata.
enum AINativeCapabilities {
    enum Route { case openAIHosted, xaiSearch, xaiImage, googleSearch, googleImage, openAIImage }
    /// Connection eligibility is independent of whether its model directory has loaded.
    static func supportsConnection(_ connection: AIConnection) -> Bool {
        let endpoint = connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return switch (connection.catalogID, connection.authMethod, endpoint) {
        case (_, .chatGPT, "https://api.openai.com/v1"),
             ("xai", .apiKey, "https://api.x.ai/v1"),
             ("openai", .apiKey, "https://api.openai.com/v1"),
             ("google", .apiKey, "https://generativelanguage.googleapis.com/v1beta"): true
        default: false
        }
    }
    static func route(_ purpose: AIModelPurpose, connection: AIConnection, model: AIModelOption) -> Route? {
        let endpoint = connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let image = model.capabilities?.imageOutput == true
        let text = model.capabilities?.text != false && !image
        if connection.authMethod == .chatGPT, endpoint == "https://api.openai.com/v1", text, purpose == .search {
            return .openAIHosted
        }
        if connection.catalogID == "xai", endpoint == "https://api.x.ai/v1",
           connection.authMethod == .apiKey {
            if purpose == .search, text { return .xaiSearch }
            if purpose == .image, image { return .xaiImage }
        }
        if connection.authMethod == .apiKey {
            if connection.catalogID == "openai", endpoint == "https://api.openai.com/v1" {
                if purpose == .image, image { return .openAIImage }
                if text, (model.wireProtocol ?? connection.wireProtocol) == .responses { return .openAIHosted }
            }
            if connection.catalogID == "google", endpoint == "https://generativelanguage.googleapis.com/v1beta" {
                if purpose == .search, !image { return .googleSearch }
                if purpose == .image, image { return .googleImage }
            }
        }
        return nil
    }
    static func supports(_ purpose: AIModelPurpose, connection: AIConnection, model: AIModelOption) -> Bool {
        route(purpose, connection: connection, model: model) != nil
    }
}
