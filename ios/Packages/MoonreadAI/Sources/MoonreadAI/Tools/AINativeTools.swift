import Foundation
import AISDKProvider
import AISDKProviderUtils
import SwiftAISDK

public struct AIWebSearchInput: AIReadingInput {
    public var query: String
    public var language: String?
    public static var constraints: [String: [String: JSONValue]] {
        ["query": ["minLength": .number(1)], "language": [:]]
    }
    public func validate() throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIToolError("invalid_argument", field: "query") }
    }

    public init(query: String, language: String? = nil) {
        self.query = query
        self.language = language
    }
}
public struct AIGenerateImageInput: AIReadingInput {
    public var prompt: String
    public var referenceAttachmentRefs: [String]?
    public static var constraints: [String: [String: JSONValue]] {
        ["prompt": ["minLength": .number(1)],
         "referenceAttachmentRefs": ["type": .string("array"), "items": .object(["type": .string("string")])]]
    }
    public func validate() throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIToolError("invalid_argument") }
    }
}
public struct AIWebSource: Codable, Equatable, Sendable, Identifiable {
    public let sourceRef: String
    public let title: String
    public let url: String
    public var id: String { sourceRef }
    private init(sourceRef: String, title: String, url: String) {
        self.sourceRef = sourceRef; self.title = title; self.url = url
    }
    /// Provider citation IDs are not application references. Preserve the exact returned URL bytes.
    public static func make(title: String, url: String) -> Self? {
        guard let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme), parsed.host != nil else { return nil }
        return .init(sourceRef: AIReference.make("web", url), title: title, url: url)
    }
    /// Merge source identities without allowing an early hostname fallback to hide a later title.
    public static func merge(_ sources: [Self]) -> [Self] {
        var result: [Self] = [], indices: [String: Int] = [:]
        for source in sources where source.isValid {
            if let index = indices[source.sourceRef] {
                if result[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[index] = source }
            } else { indices[source.sourceRef] = result.count; result.append(source) }
        }
        return result.map { source in
            source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.make(title: URL(string: source.url)?.host ?? "", url: source.url)! : source
        }
    }
    public var isValid: Bool { Self.make(title: title, url: url)?.sourceRef == sourceRef }
    /// Only typed successful tool results can supply web-source authority.
    public static func committed(in output: JSONValue, tool: String) -> [Self] {
        guard let bytes = try? JSONEncoder().encode(output) else { return [] }
        switch tool {
        case "web_search":
            guard let result = try? JSONDecoder().decode(AINativeResult.self, from: bytes), result.status == "ok" else { return [] }
            return Self.merge(result.sources)
        case "find_cover":
            guard let result = try? JSONDecoder().decode(AIToolResponse<AIFindCoverResult>.self, from: bytes), result.status == "ok" else { return [] }
            return Self.merge(result.data.sources)
        default: return []
        }
    }
}
public struct AINativeResult: Codable, Sendable {
    public var status = "ok"
    public var data: Payload
    public var sources: [AIWebSource] = []
    public struct Payload: Codable, Sendable {
        public var answer: String?
        public var attachments: [AIImageAttachment]?
        public var connectionID: String
        public var modelID: String
        public var truncated: Bool = false
        public var inputTokens: Int?
        public var outputTokens: Int?
    }
}

/// Independent provider invocation, with the same auth and cancellation owners as chat.
@MainActor public final class AINativeTools {
    public let providers: AIConnectionService
    public let owner: String
    public let images: AIImageStore
    public let makeTransport: @Sendable () -> AITransport
    public init(providers: AIConnectionService, owner: String, images: AIImageStore = .shared,
         makeTransport: @escaping @Sendable () -> AITransport = { AITransport() }) {
        self.providers = providers; self.owner = owner; self.images = images; self.makeTransport = makeTransport
    }
    public func definitions() -> [AIAgentTool] {
        [AIAgentTool(name: "web_search", description: "Search the web with the user's configured search model. Returns a sourced answer, not full webpage text.", input: AIWebSearchInput.self,
            enabled: { [providers] in providers.purposeSelection(.search) != nil },
            execute: { input in try await self.search(input) }),
         AIAgentTool(name: "generate_image", description: "Generate an image when requested, or edit images using attachment references from prior results. Never claims to change a book cover.", input: AIGenerateImageInput.self,
            enabled: { [providers] in providers.purposeSelection(.image) != nil },
            execute: { input in try await self.generate(input) })]
    }
    public func search(_ input: AIWebSearchInput) async throws -> AINativeResult {
        try input.validate()
        return try await AINativeExecutor(providers: providers, owner: owner, images: images, makeTransport: makeTransport).perform(.search, prompt: input.query + (input.language.map { "\nRespond in language: \($0)" } ?? ""), refs: [])
    }
    public func generate(_ input: AIGenerateImageInput) async throws -> AINativeResult {
        try input.validate()
        return try await AINativeExecutor(providers: providers, owner: owner, images: images, makeTransport: makeTransport).perform(.image, prompt: input.prompt, refs: input.referenceAttachmentRefs ?? [])
    }
}
