import Foundation
import SwiftData
import CoreData

@ModelActor actor UserDataStore {
    static let modelTypes: [any PersistentModel.Type] = [UserPosition.self, UserValue.self, AnnotationOperation.self, ReadingFact.self, StatisticsClear.self, UserCover.self]
    static let schema = Schema(modelTypes)

    nonisolated let changes = UserInputRevision()
    struct ProjectionWork { let version: String; let id: UUID; let task: Task<String, Error> }
    var projectionWork: [String: ProjectionWork] = [:]
    var preparedFactsCache: [String: (version: String, value: PreparedFacts)] = [:]
    var preparedFactsWork: [String: (version: String, id: UUID, task: Task<PreparedFacts, Error>)] = [:]
    var projectionCache: [String: (String, String)] = [:]
    func importedChanges(keys: Set<String> = []) throws {
        if keys.isEmpty { invalidateProjection() }
        else { changes.invalidate(keys: Array(keys)) }
        for key in keys { try compactPositions(key: key) }
    }
    func invalidateProjection() { changes.invalidate(); projectionCache.removeAll(); preparedFactsCache.removeAll() }
    nonisolated func version(keys: [String]?, positionsOnly: Bool, includeFacts: Bool, statisticsKeys: [String]?, fields: UserProjectionDomain = .reading) -> String {
        let values: UserProjectionDomain = positionsOnly ? [.position, .opened] : fields
        return "\(changes.version(keys: keys, domains: values))-\(includeFacts ? changes.version(keys: statisticsKeys, domains: .statistics) : 0)-\(UserProjectionChanges.shared.revision)"
    }
    var recordingGeneration: UInt64?
    var recordingEnabled = true

    func setRecording(generation: UInt64, enabled: Bool) { recordingGeneration = generation; recordingEnabled = enabled; invalidateProjection() }

    func encode<T: Encodable>(_ value: T) throws -> String {
        try UserSyncJSON.encode(value, envelope: T.self == StoredValue.self || T.self == AnnotationCandidate.self || T.self == ClearValue.self)
    }
    func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
        let shape: UserSyncJSON.Shape
        let envelope: Bool
        switch type {
        case is StoredValue.Type: shape = UserSyncJSON.stored; envelope = true
        case is AnnotationCandidate.Type: shape = UserSyncJSON.candidate; envelope = true
        case is ClearValue.Type: shape = UserSyncJSON.clear; envelope = true
        case is PositionValue.Type: shape = UserSyncJSON.position; envelope = false
        case is ChapterValue.Type: shape = UserSyncJSON.chapter; envelope = false
        default: throw UserSyncCompatibilityError()
        }
        return try UserSyncJSON.decode(type, value, as: shape, envelope: envelope)
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        modelContext.autosaveEnabled = false
        do {
            let value = try body()
            // Invalidate before save makes changes visible: a concurrent cache
            // lookup must then enter this actor, after commit or rollback.
            let dependencies = (modelContext.insertedModelsArray + modelContext.changedModelsArray + modelContext.deletedModelsArray).map(Self.dependency)
            for (key, domain) in dependencies { changes.invalidate(keys: key.map { [$0] }, domains: domain) }
            try modelContext.save()
            return value
        }
        catch { modelContext.rollback(); throw error }
    }
    private static func dependency(_ model: any PersistentModel) -> (String?, UserProjectionDomain) {
        switch model {
        case let value as UserPosition: return (value.contentKey, .position)
        case let value as ReadingFact: return (value.contentKey, .statistics)
        case let value as StatisticsClear:
            return ((try? JSONDecoder().decode(ClearValue.self, from: Data(value.payload.utf8)))?.book, .statistics)
        case let value as UserValue:
            let parts = value.key.split(separator: "/", maxSplits: 2).map(String.init)
            let domain: UserProjectionDomain = switch parts.first {
            case "position": .position
            case "opened": .opened
            case "metadata": .metadata
            case "chapter": .chapter
            case "palette", "shelf-reference", "source-decoding": []
            default: .all
            }
            return (parts.count > 1 ? parts[1] : nil, domain)
        default: return (nil, []) // Cover bytes and annotations are not ReaderQuery inputs.
        }
    }
    func saveCover(id: String, bytes: Data) throws {
        try transaction { try saveCoverWithoutSave(id: id, bytes: bytes) }
    }
    func saveCoverWithoutSave(id: String, bytes: Data) throws {
        let rows = try modelContext.fetch(FetchDescriptor<UserCover>(predicate: #Predicate { $0.id == id }))
        guard rows.allSatisfy({ $0.bytes == nil || $0.bytes == bytes }) else { throw UserSyncCompatibilityError() }
        if rows.isEmpty { modelContext.insert(UserCover(id: id, bytes: bytes)) }
    }
    func cover(_ id: String) throws -> Data? {
        try modelContext.fetch(FetchDescriptor<UserCover>(predicate: #Predicate { $0.id == id })).compactMap(\.bytes).first
    }
}

/// CloudSync publishes completed imports through cloudDataReceived. Raw Core Data
/// remote-change notifications also fire for our local saves, so they cannot serve
/// as a global invalidation signal without undoing scoped local revisions.
/// This epoch is read under a lock; no projection or SwiftData work runs in notifications.
private final class UserProjectionChanges: @unchecked Sendable {
    static let shared = UserProjectionChanges()
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    private init() {
        for name in [Notification.Name.cloudDataReceived] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { @Sendable [weak self] _ in
                guard let self else { return }
                lock.lock(); value &+= 1; lock.unlock()
            })
        }
    }
}

struct UserProjectionDomain: OptionSet, Sendable {
    let rawValue: Int
    static let position = Self(rawValue: 1)
    static let metadata = Self(rawValue: 2)
    static let chapter = Self(rawValue: 4)
    static let statistics = Self(rawValue: 8)
    static let opened = Self(rawValue: 16)
    static let reading: Self = [.position, .metadata, .chapter, .opened]
    static let all: Self = [.position, .metadata, .chapter, .statistics, .opened]
}

final class UserInputRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var global: [Int: UInt64] = [:]
    private var books: [String: [Int: UInt64]] = [:]
    func invalidate(keys: [String]? = nil, domains: UserProjectionDomain = .all) {
        lock.lock(); defer { lock.unlock() }
        guard !domains.isEmpty else { return }
        value &+= 1
        for bit in [1, 2, 4, 8, 16] where domains.rawValue & bit != 0 {
            if let keys { for key in keys { books[key, default: [:]][bit] = value } }
            else { global[bit] = value }
        }
    }
    func version(keys: [String]?, domains: UserProjectionDomain) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        var result: UInt64 = 0
        for bit in [1, 2, 4, 8, 16] where domains.rawValue & bit != 0 {
            result = max(result, global[bit] ?? 0)
            if let keys { for key in keys { result = max(result, books[key]?[bit] ?? 0) } }
            else { for revisions in books.values { result = max(result, revisions[bit] ?? 0) } }
        }
        return result
    }
}
