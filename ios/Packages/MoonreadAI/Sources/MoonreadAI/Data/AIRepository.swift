import Foundation
import SwiftData
import AISDKProvider

public struct AISessionValue: Codable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var updated: Date
    public var context: AIContext
    public var origin: AITaskOrigin?
    public var kind: AITaskKind?
    public var listed: Bool
    public init(id: String = UUID().uuidString, title: String, context: AIContext = .general,
         origin: AITaskOrigin? = nil, kind: AITaskKind? = nil, listed: Bool = true) {
        self.id = id; self.title = title; self.context = context
        self.origin = origin; self.kind = kind; self.listed = listed
        updated = Date()
    }
}
public struct AIStagedAsset: Sendable {
    public let sessionID: String
    public let attachment: AIImageAttachment
    public let bytes: Data

    public init(sessionID: String, attachment: AIImageAttachment, bytes: Data) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.bytes = bytes
    }
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
@ModelActor public actor AIRepository {
    public nonisolated static func open(inMemory: Bool = false, url: URL? = nil) async throws -> AIRepository {
        try await Task.detached { try Self.make(inMemory: inMemory, url: url) }.value
    }
    private nonisolated static func make(inMemory: Bool, url: URL?) throws -> AIRepository {
        let schema = Schema([AIConversationRecord.self, AIAgentHeadRecord.self, AIAgentEntryRecord.self, AIAssetRecord.self])
        let configuration: ModelConfiguration
        if inMemory { configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none) }
        else {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let session = arguments.firstIndex(of: "--ui-test-session").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            #else
            let session: String? = nil
            #endif
            let location: URL
            if let url { location = url }
            else {
                let directory = URL.applicationSupportDirectory.appending(path: "Moonread", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                location = directory.appending(path: session.map { "ai-ui-\($0).store" } ?? "ai-conversations.store")
            }
            configuration = ModelConfiguration(schema: schema, url: location, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            try AIToolNameMigration.run(container, store: location)
            return AIRepository(modelContainer: container)
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
    public func sessions() throws -> [AISessionValue] {
        try modelContext.fetch(FetchDescriptor<AIConversationRecord>(sortBy: [SortDescriptor(\AIConversationRecord.updated, order: .reverse)])).enumerated().compactMap { index, row in
            do { return try value(row) }
            catch { AIPersistedJSON.skipped("AIRepository.sessions", index: index); return nil }
        }
    }
    public func session(_ id: String) throws -> AISessionValue { try value(record(id)) }
    public func create(_ value: AISessionValue, head: AIAgentHead = .init(), assets: [AIStagedAsset] = []) throws {
        try save {
            guard (try? record(value.id)) == nil else { throw AIError.storage }
            let row = try AIConversationRecord(value); modelContext.insert(row)
            try insertAssets(assets, session: row)
            modelContext.insert(try AIAgentHeadRecord(value.id, head, session: row))
            try validateAssetReferences(Array(AIAssetReferences.head(head)), session: row)
        }
    }
    public func list(_ id: String) throws {
        try save { let row = try record(id); row.listed = true; row.origin = nil }
    }
    public func delete(_ id: String) throws { try save { modelContext.delete(try record(id)) } }
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
    public func asset(_ id: String, sessionID: String) throws -> AIImageAttachment {
        _ = try record(sessionID)
        guard let row = try modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == sessionID })).first else { throw AIToolError("not_found", field: "attachmentRef") }
        return .init(attachmentRef: row.id, mimeType: row.mimeType, width: row.width, height: row.height)
    }
    public func assetBytes(_ id: String, sessionID: String) throws -> Data {
        _ = try record(sessionID)
        guard let row = try modelContext.fetch(FetchDescriptor<AIAssetRecord>(predicate: #Predicate { $0.id == id && $0.sessionID == sessionID })).first else { throw AIToolError("not_found", field: "attachmentRef") }
        return row.bytes
    }
    public func head(_ id: String) throws -> AIAgentHead {
        _ = try record(id)
        let row = try modelContext.fetch(FetchDescriptor<AIAgentHeadRecord>(predicate: #Predicate { $0.conversationID == id })).first
        return try row.map { try JSONDecoder().decode(AIAgentHead.self, from: $0.payload) } ?? .init()
    }
    @discardableResult public func commit(_ id: String, head: AIAgentHead, entries: [AIAgentEntry] = [], assets: [AIStagedAsset] = [], references: [String] = [], listed: Bool? = nil, sentAt: Date? = nil, finish: Bool = false) throws -> [AIAgentEntry] {
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
    public func newestMatches(_ text: String, in ids: Set<String>) throws -> [String: AIAgentEntry] {
        let query = FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.searchText.localizedStandardContains(text) },
                                                        sortBy: [SortDescriptor(\AIAgentEntryRecord.sequence, order: .reverse)])
        var matches: [String: AIAgentEntry] = [:]
        for row in try modelContext.fetch(query) where ids.contains(row.conversationID) && matches[row.conversationID] == nil {
            matches[row.conversationID] = try JSONDecoder().decode(AIAgentEntry.self, from: row.payload)
        }
        return matches
    }
    public func history(_ id: String, before: Int = Int.max, after: Int = -1, through: Int = Int.max, limit: Int? = 50) throws -> [AIAgentEntry] {
        _ = try record(id)
        var query = FetchDescriptor<AIAgentEntryRecord>(predicate: #Predicate { $0.conversationID == id && $0.sequence < before && $0.sequence > after && $0.sequence <= through }, sortBy: [SortDescriptor(\AIAgentEntryRecord.sequence, order: limit == nil || after >= 0 ? .forward : .reverse)])
        if let limit { query.fetchLimit = min(max(limit, 1), 50) }
        let rows = try modelContext.fetch(query).map { try JSONDecoder().decode(AIAgentEntry.self, from: $0.payload) }
        return limit != nil && after < 0 ? Array(rows.reversed()) : rows
    }
}

/// 1.10 renamed and merged the AI tools (#378). Saved conversations are rewritten once to the
/// new names, and saved book-filter arguments to the nested form, so the model does not copy the
/// old shape back from history. Other inputs and all outputs are kept as saved.
enum AIToolNameMigration {
    static let renamed: [String: String] = [
        "ls": "list_shelf", "search_books": "find_books", "query_books_by_filter": "find_books",
        "list_filter_options": "list_filter_values", "show_book_list": "show_books", "get_book": "get_book_info",
        "get_chapters": "list_chapters", "read": "read_text", "rg": "search_text",
        "get_marks": "list_marks", "get_mark": "list_marks", "get_environment": "get_current_time", "find_cover": "search_cover",
    ]
    static let version = 3

    static func run(_ container: ModelContainer, store: URL, defaults: UserDefaults = .standard) throws {
        let key = "Moonread.ai.toolNames." + store.lastPathComponent
        guard defaults.integer(forKey: key) < version else { return }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for row in try context.fetch(FetchDescriptor<AIAgentEntryRecord>()) {
            if let payload = rewritten(row.payload) { row.payload = payload }
        }
        for row in try context.fetch(FetchDescriptor<AIAgentHeadRecord>()) {
            if let payload = rewritten(row.payload, key: "name", under: "pendingCalls") { row.payload = payload }
        }
        try context.save()
        defaults.set(version, forKey: key)
    }

    /// The payload with old tool names (and old filter arguments) replaced, or nil when nothing changed.
    static func rewritten(_ payload: Data, key: String = "toolName", under parent: String? = nil) -> Data? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: payload) else { return nil }
        var changed = false
        func walk(_ value: JSONValue, inside: Bool) -> JSONValue {
            switch value {
            case .object(var fields):
                if key == "toolName", fields["type"] == .string("tool-call"), case .string(let tool)? = fields["toolName"],
                   let input = fields["input"], let nested = nestedFilterInput(tool: renamed[tool] ?? tool, input) {
                    fields["input"] = nested; changed = true
                }
                var result: [String: JSONValue] = [:]
                for (name, field) in fields {
                    if name == key, inside || parent == nil, case .string(let old) = field, let new = renamed[old] {
                        result[name] = .string(new); changed = true
                    } else {
                        result[name] = walk(field, inside: inside || name == parent)
                    }
                }
                return .object(result)
            case .array(let items): return .array(items.map { walk($0, inside: inside) })
            default: return value
            }
        }
        let result = walk(value, inside: false)
        return changed ? try? JSONEncoder().encode(result) : nil
    }

    /// Old find_books/propose_book_filter arguments in the nested form; nil when already nested
    /// or deeper than the two levels the model may write (those stay as saved).
    static func nestedFilterInput(tool: String, _ input: JSONValue) -> JSONValue? {
        guard case .object(var fields) = input else { return nil }
        switch tool {
        case "propose_book_filter":
            guard let nodes = fields["nodes"]?.array, let filter = nested(nodes) else { return nil }
            fields["nodes"] = nil
            if filter != .null { fields["filter"] = filter }
            return .object(fields)
        case "find_books":
            if let old = fields["filter"]?.object, let nodes = old["nodes"]?.array {
                guard let filter = nested(nodes) else { return nil }
                fields["filter"] = filter == .null ? nil : filter
                if let sorts = old["sorts"], sorts != .array([]) { fields["sorts"] = sorts }
                return .object(fields)
            }
            // Old search_books fields become conditions of the same filter.
            var rules: [JSONValue] = []
            if let author = fields.removeValue(forKey: "author"), case .string(let name) = author, !name.isEmpty { rules.append(.object(["authors": .array([.string(name)])])) }
            if let tags = fields.removeValue(forKey: "tags"), case .array(let names) = tags, !names.isEmpty { rules.append(.object(["tags": .array(names), "tagMatch": .string("all")])) }
            if let status = fields.removeValue(forKey: "readingStatus"), case .string(let name) = status { rules.append(.object(["status": .array([.string(name)])])) }
            let sort = fields.removeValue(forKey: "sort")
            guard !rules.isEmpty || sort != nil else { return nil }
            if !rules.isEmpty { fields["filter"] = .object(["match": .string("all"), "rules": .array(rules)]) }
            if case .string(let field)? = sort { fields["sorts"] = .array([.object(["field": .string(field), "descending": .bool(field == "recent")])]) }
            return .object(fields)
        default: return nil
        }
    }

    /// Flat nodes (parents first, root at index 0) as {match, exclude?, rules}; .null for no nodes, nil when deeper than two levels.
    static func nested(_ nodes: [JSONValue]) -> JSONValue? {
        if nodes.isEmpty { return .null }
        func condition(_ node: [String: JSONValue]) -> JSONValue? {
            var rule: [String: JSONValue] = [:]
            let values = node["values"] ?? .array([])
            switch node["kind"]?.string {
            case "status": rule["status"] = values
            case "tag": rule["tags"] = values; rule["tagMatch"] = node["relation"] ?? .string("any")
            case "untagged": rule["untagged"] = .bool(true)
            case "author": rule["authors"] = values
            case "shelf": rule["shelves"] = values
            default: return nil
            }
            if node["excluded"] == .bool(true) { rule["exclude"] = .bool(true) }
            return .object(rule)
        }
        let objects = nodes.compactMap(\.object)
        guard objects.count == nodes.count, objects[0]["kind"] == .string("group") else { return nil }
        var rules: [JSONValue] = []
        for (index, node) in objects.enumerated().dropFirst() {
            guard node["parent"]?.int == 0 else { continue }
            if node["kind"] == .string("group") {
                var children: [JSONValue] = []
                for child in objects where child["parent"]?.int == index {
                    guard child["kind"] != .string("group"), let value = condition(child) else { return nil }
                    children.append(value)
                }
                var group: [String: JSONValue] = ["match": node["relation"] ?? .string("all"), "rules": .array(children)]
                if node["excluded"] == .bool(true) { group["exclude"] = .bool(true) }
                rules.append(.object(group))
            } else {
                guard let value = condition(node) else { return nil }
                rules.append(value)
            }
        }
        var root: [String: JSONValue] = ["match": objects[0]["relation"] ?? .string("all"), "rules": .array(rules)]
        if objects[0]["excluded"] == .bool(true) { root["exclude"] = .bool(true) }
        return .object(root)
    }
}
