import Foundation
import SwiftData
import AISDKProvider
import AISDKProviderUtils

@Model final class AIAgentHeadRecord {
    var conversationID: String
    var payload: Data
    var session: AIConversationRecord?
    init(_ id: String, _ head: AIAgentHead, session: AIConversationRecord) throws {
        conversationID = id; payload = try JSONEncoder().encode(head); self.session = session
    }
}
@Model final class AIAgentEntryRecord {
    var conversationID: String
    var sequence: Int
    var payload: Data
    /// The message text a person reads in the conversation; empty for process entries.
    var searchText: String
    var session: AIConversationRecord?
    init(_ id: String, _ entry: AIAgentEntry, session: AIConversationRecord) throws {
        conversationID = id; sequence = entry.sequence; payload = try JSONEncoder().encode(entry); searchText = entry.searchableText; self.session = session
    }
}

/// A concrete session store handle; every write goes to the same repository actor.
struct AIAgentStore: Sendable {
    let repository: AIRepository
    init(repository: AIRepository) { self.repository = repository }
    func head(_ id: String) async throws -> AIAgentHead { try await repository.head(id) }
    func all(_ id: String) async throws -> [AIAgentEntry] { try await repository.history(id, limit: nil) }
    func page(_ id: String, before: Int = Int.max, after: Int = -1, limit: Int = 50) async throws -> [AIAgentEntry] {
        try await repository.history(id, before: before, after: after, limit: limit)
    }
    func forward(_ id: String, after: Int, through: Int, limit: Int = 50) async throws -> [AIAgentEntry] {
        try await repository.history(id, after: after, through: through, limit: limit)
    }
    @discardableResult func commit(_ id: String, head: AIAgentHead, entries: [AIAgentEntry] = [], listed: Bool? = nil, sentAt: Date? = nil, finish: Bool = false) async throws -> [AIAgentEntry] {
        let refs = AIAssetReferences.head(head).union(entries.flatMap { AIAssetReferences.entry($0) })
        let staged = await AIImageStore.shared.staged(owner: id, refs: refs)
        let changes = try await repository.commit(id, head: head, entries: entries, assets: staged, references: Array(refs), listed: listed, sentAt: sentAt, finish: finish)
        await AIImageStore.shared.didCommit(owner: id, refs: refs)
        return changes
    }
    func finish(_ id: String, head: AIAgentHead) async throws { try await commit(id, head: head, finish: true) }
}

enum AIAssetReferences {
    static func output(_ value: JSONValue) -> Set<String> {
        guard value.object["status"] == .string("ok") else { return [] }
        return collect(value)
    }
    private static func collect(_ value: JSONValue) -> Set<String> {
        var result: Set<String> = []
        if let id = value.object["attachmentRef"]?.string { result.insert(id) }
        for child in value.object.values { result.formUnion(collect(child)) }
        for child in value.array ?? [] { result.formUnion(collect(child)) }
        return result
    }
    static func head(_ head: AIAgentHead) -> Set<String> {
        var refs = Set(head.queue.flatMap { $0.readingAttachments.compactMap(\.attachmentRef) })
        for call in head.pendingCalls { if let output = call.output { refs.formUnion(Self.output(output)) } }
        return refs
    }
    static func entry(_ entry: AIAgentEntry) -> Set<String> {
        var refs = Set(entry.readingAttachments.compactMap(\.attachmentRef))
        if entry.message.object["role"] == .string("tool") {
            for part in entry.message.object["content"]?.array ?? [] {
                if let value = part.object["output"]?.object["value"] { refs.formUnion(output(value)) }
            }
        }
        return refs
    }
}
