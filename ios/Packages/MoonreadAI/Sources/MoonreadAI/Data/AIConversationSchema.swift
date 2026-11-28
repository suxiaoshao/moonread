import Foundation
import SwiftData

/// The unversioned store shipped in 1.9. Preserve entity names and attributes.
enum AIConversationSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [AIConversationRecord.self, AIAgentHeadRecord.self, AIAgentEntryRecord.self, AIAssetRecord.self] }

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
}

enum AIConversationSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [AIConversationRecord.self, AIAgentHeadRecord.self, AIAgentEntryRecord.self, AIAssetRecord.self] }
}

enum AIConversationMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AIConversationSchemaV1.self, AIConversationSchemaV2.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: AIConversationSchemaV1.self, toVersion: AIConversationSchemaV2.self)] }
}
