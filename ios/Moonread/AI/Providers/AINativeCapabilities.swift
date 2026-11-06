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
    static func supportsText(connection: AIConnection, model: AIModelOption) -> Bool {
        guard model.isListed != false else { return false }
        if connection.authMethod == .chatGPT { return model.capabilities?.text != false }
        if model.isManual == true, model.capabilities?.text == nil { return true }
        guard model.capabilities?.text == true else { return false }
        if connection.catalogID == "openai", connection.authMethod == .apiKey,
           connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "https://api.openai.com/v1",
           (model.wireProtocol ?? connection.wireProtocol) == .responses, model.isManual != true {
            return openAIResponses(model.id)
        }
        return true
    }
    // Endpoint compatibility, not a second model catalog. The basic /models
    // response includes audio/embedding/legacy Chat-only models. Exact public
    // metadata still supplies modality; a recognized family only gates Responses.
    // https://developers.openai.com/api/docs/guides/your-data
    private static func openAIResponses(_ id: String) -> Bool {
        let excluded = ["audio", "realtime", "transcribe", "tts", "search-api", "search-preview", "chat-latest"]
        guard !excluded.contains(where: { id.contains($0) }) else { return false }
        let families = ["gpt-6", "gpt-6.1", "gpt-5", "gpt-4.1", "gpt-4o", "o1", "o3", "o4-mini", "computer-use-preview"]
        return families.contains { id == $0 || id.hasPrefix($0 + "-") || id.hasPrefix($0 + ".") }
    }
    static func route(_ purpose: AIModelPurpose, connection: AIConnection, model: AIModelOption) -> Route? {
        guard model.isListed != false else { return nil }
        let endpoint = connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let image = model.capabilities?.imageOutput == true
        let text = supportsText(connection: connection, model: model) && !image && (connection.authMethod == .chatGPT || model.capabilities?.text == true)
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
                if text, openAIResponses(model.id),
                   !["o1", "o1-mini", "o1-preview", "o3-mini", "gpt-4.1-nano"].contains(where: { model.id == $0 || model.id.hasPrefix($0 + "-") }),
                   (model.wireProtocol ?? connection.wireProtocol) == .responses { return .openAIHosted }
            }
            if connection.catalogID == "google", endpoint == "https://generativelanguage.googleapis.com/v1beta" {
                if purpose == .search, text { return .googleSearch }
                if purpose == .image, image { return .googleImage }
            }
        }
        return nil
    }
    static func supports(_ purpose: AIModelPurpose, connection: AIConnection, model: AIModelOption) -> Bool {
        route(purpose, connection: connection, model: model) != nil
    }
}
