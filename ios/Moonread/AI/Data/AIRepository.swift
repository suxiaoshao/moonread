import Foundation
import SwiftData

struct AISessionValue: Codable, Sendable, Identifiable {
    let id: String
    var title: String
    var updated: Date
    var context: AIContext
    var origin: AITaskOrigin?
    var kind: AITaskKind?
    var listed: Bool
    init(id: String = UUID().uuidString, title: String, context: AIContext = .general,
         origin: AITaskOrigin? = nil, kind: AITaskKind? = nil, listed: Bool = true) {
        self.id = id; self.title = title; self.context = context
        self.origin = origin; self.kind = kind; self.listed = listed
        updated = Date()
    }
}
struct AIStagedAsset: Sendable {
    let sessionID: String
    let attachment: AIImageAttachment
    let bytes: Data
}

@Model final class AIConversationRecord {
    var id: String
    var title: String
    var updated: Date
    var context: Data
    var origin: Data?
    var kind: Data?
    var listed: Bool
    @Relationship(deleteRule: .cascade, inverse: \AIAgentHeadRecord.session) var heads: [AIAgentHeadRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \AIAgentEntryRecord.session) var entries: [AIAgentEntryRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \AIAssetRecord.session) var assets: [AIAssetRecord] = []
    init(_ value: AISessionValue) throws {
        id = value.id; title = value.title; updated = value.updated
        context = try JSONEncoder().encode(value.context)
        origin = try value.origin.map { try JSONEncoder().encode($0) }; kind = try value.kind.map { try JSONEncoder().encode($0) }
        listed = value.listed
    }
}
@Model final class AIAssetRecord {
    var id: String
    var sessionID: String
    var mimeType: String
    var width: Int
    var height: Int
    @Attribute(.externalStorage) var bytes: Data
    var session: AIConversationRecord?
    init(_ value: AIStagedAsset, session: AIConversationRecord) {
        id = value.attachment.id; sessionID = value.sessionID
        mimeType = value.attachment.mimeType; width = value.attachment.width; height = value.attachment.height
        bytes = value.bytes; self.session = session
    }
}
@ModelActor actor AIRepository {
    nonisolated static func open(inMemory: Bool = false, url: URL? = nil) async throws -> AIRepository {
        try await Task.detached { try Self.make(inMemory: inMemory, url: url) }.value
    }
    private nonisolated static func make(inMemory: Bool, url: URL?) throws -> AIRepository {
        let schema = Schema([AIConversationRecord.self, AIAgentHeadRecord.self, AIAgentEntryRecord.self, AIAssetRecord.self])
        let configuration: ModelConfiguration
        if inMemory { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none) }
        else {
            let arguments = ProcessInfo.processInfo.arguments
            let session = arguments.firstIndex(of: "--ui-test-session").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            let location: URL
            if let url { location = url }
            else {
                let directory = URL.applicationSupportDirectory.appending(path: "Moonread", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                location = directory.appending(path: session.map { "ai-ui-\($0).store" } ?? "ai-conversations.store")
            }
            configuration = ModelConfiguration(schema: schema, url: location, cloudKitDatabase: .none)
        }
        return AIRepository(modelContainer: try ModelContainer(for: schema, configurations: [configuration]))
    }
    private func save<T>(_ operation: () throws -> T) throws -> T {
        modelContext.autosaveEnabled = false
        do {
            let value = try operation()
            try modelContext.save(); return value
        } catch { modelContext.rollback(); throw error }
    }
    private func record(_ id: String) throws -> AIConversationRecord {
        guard let value = try modelContext.fetch(FetchDescriptor<AIConversationRecord>(predicate: #Predicate { $0.id == id })).first else { throw AIToolError("not_found") }
        return value
    }
    private func value(_ row: AIConversationRecord) throws -> AISessionValue {
        var value = AISessionValue(id: row.id, title: row.title, context: try JSONDecoder().decode(AIContext.self, from: row.context), listed: row.listed)
        value.updated = row.updated
        value.origin = try row.origin.map { try JSONDecoder().decode(AITaskOrigin.self, from: $0) }
        value.kind = try row.kind.map { try JSONDecoder().decode(AITaskKind.self, from: $0) }
        return value
    }
    func sessions() throws -> [AISessionValue] {
        try modelContext.fetch(FetchDescriptor<AIConversationRecord>(sortBy: [SortDescriptor(\AIConversationRecord.updated, order: .reverse)])).map(value)
    }
    func session(_ id: String) throws -> AISessionValue { try value(record(id)) }
    func create(_ value: AISessionValue, head: AIAgentHead = .init(), assets: [AIStagedAsset] = []) throws {
        try save {
            guard (try? record(value.id)) == nil else { throw AIError.storage }
            let row = try AIConversationRecord(value); modelContext.insert(row)
            try insertAssets(assets, session: row)
            modelContext.insert(try AIAgentHeadRecord(value.id, head, session: row))
            try validateAssetReferences(Array(AIAssetReferences.head(head)), session: row)
        }
    }
    func list(_ id: String) throws {
        try save { let row = try record(id); row.listed = true; row.origin = nil }
    }
    func delete(_ id: String) throws { try save { modelContext.delete(try record(id)) } }
    private func insertAssets(_ values: [AIStagedAsset], session: AIConversationRecord) throws {
        for value in values {
            guard value.sessionID == session.id else { throw AIToolError("permission_denied") }
            let id = value.attachment.id, owner = session.id
            if try modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == owner })).isEmpty {
                modelContext.insert(AIAssetRecord(value, session: session))
            }
        }
    }
    private func validateAssetReferences(_ refs: [String], session: AIConversationRecord) throws {
        let owner = session.id
        for id in Set(refs) {
            guard try !modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == owner })).isEmpty else { throw AIToolError("not_found", field: "attachmentRef") }
        }
    }
    func asset(_ id: String, sessionID: String) throws -> AIImageAttachment {
        _ = try record(sessionID)
        guard let row = try modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == sessionID })).first else { throw AIToolError("not_found", field: "attachmentRef") }
        return .init(attachmentRef: row.id, mimeType: row.mimeType, width: row.width, height: row.height)
    }
    func assetBytes(_ id: String, sessionID: String) throws -> Data {
        _ = try record(sessionID)
        guard let row = try modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == sessionID })).first else { throw AIToolError("not_found", field: "attachmentRef") }
        return row.bytes
    }
    func head(_ id: String) throws -> AIAgentHead {
        _ = try record(id)
        let row = try modelContext.fetch(FetchDescriptor<AIAgentHeadRecord>(predicate: #Predicate { $0.conversationID == id })).first
        return try row.map { try JSONDecoder().decode(AIAgentHead.self, from: $0.payload) } ?? .init()
    }
    @discardableResult func commit(_ id: String, head: AIAgentHead, entries: [AIAgentEntry] = [], assets: [AIStagedAsset] = [], references: [String] = [], listed: Bool? = nil, sentAt: Date? = nil, finish: Bool = false) throws -> [AIAgentEntry] {
        try save {
            var changes = entries
            let session = try record(id)
            try insertAssets(assets, session: session); try validateAssetReferences(references, session: session)
            let payload = try JSONEncoder().encode(head)
            if let row = try modelContext.fetch(FetchDescriptor<AIAgentHeadRecord>(predicate: #Predicate { $0.conversationID == id })).first { row.payload = payload }
            else { modelContext.insert(try AIAgentHeadRecord(id, head, session: session)) }
            for entry in entries { modelContext.insert(try AIAgentEntryRecord(id, entry, session: session)) }
            if listed == true, !session.listed, session.kind == nil,
               try JSONDecoder().decode(AIContext.self, from: session.context) == .general,
               let first = head.queue.first {
                session.title = String(first.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            }
            if let listed { session.listed = listed }
            if let sentAt { session.updated = sentAt }
            if finish {
                var query = FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.conversationID == id }, sortBy: [SortDescriptor(\AIAgentEntryRecord.sequence, order: .reverse)])
                query.fetchLimit = 1
                if let row = try modelContext.fetch(query).first {
                    var entry = try JSONDecoder().decode(AIAgentEntry.self, from: row.payload)
                    if entry.turn == head.currentTurn {
                        entry.outcome = head.status; entry.error = head.error; row.payload = try JSONEncoder().encode(entry)
                        if let index = changes.firstIndex(where: { $0.id == entry.id }) { changes[index] = entry }
                        else { changes.append(entry) }
                    }
                }
            }
            return changes
        }
    }
    /// The newest matching message of each of the given conversations.
    func newestMatches(_ text: String, in ids: Set<String>) throws -> [String: AIAgentEntry] {
        let query = FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.searchText.localizedStandardContains(text) },
                                                        sortBy: [SortDescriptor(\AIAgentEntryRecord.sequence, order: .reverse)])
        var matches: [String: AIAgentEntry] = [:]
        for row in try modelContext.fetch(query) where ids.contains(row.conversationID) && matches[row.conversationID] == nil {
            matches[row.conversationID] = try JSONDecoder().decode(AIAgentEntry.self, from: row.payload)
        }
        return matches
    }
    func history(_ id: String, before: Int = Int.max, after: Int = -1, through: Int = Int.max, limit: Int? = 50) throws -> [AIAgentEntry] {
        _ = try record(id)
        var query = FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.conversationID == id && $0.sequence < before && $0.sequence > after && $0.sequence <= through }, sortBy: [SortDescriptor(\AIAgentEntryRecord.sequence, order: limit == nil || after >= 0 ? .forward : .reverse)])
        if let limit { query.fetchLimit = min(max(limit, 1), 50) }
        let rows = try modelContext.fetch(query).map { try JSONDecoder().decode(AIAgentEntry.self, from: $0.payload) }
        return limit != nil && after < 0 ? Array(rows.reversed()) : rows
    }
}
