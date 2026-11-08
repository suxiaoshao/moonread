import Foundation
import SwiftData
import CoreData

@ModelActor actor UserDataStore {
    static let modelTypes: [any PersistentModel.Type] = [UserPosition.self, UserValue.self, AnnotationOperation.self, ReadingFact.self, StatisticsClear.self, UserCover.self]
    static let schema = Schema(modelTypes)

    nonisolated let changes = UserInputRevision()
    var projectionCache: [String: (String, String)] = [:]
    func importedChanges(keys: Set<String> = []) throws {
        invalidateProjection()
        for key in keys { try compactPositions(key: key) }
    }
    func invalidateProjection() { changes.invalidate(); projectionCache.removeAll() }
    nonisolated var projectionVersion: String { "\(changes.revision)-\(UserProjectionChanges.shared.revision)" }
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
        do { let value = try body(); try modelContext.save(); invalidateProjection(); return value }
        catch { modelContext.rollback(); throw error }
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

/// Framework imports can arrive without one of this actor's local transactions.
/// This epoch is read under a lock; no projection or SwiftData work runs in notifications.
private final class UserProjectionChanges: @unchecked Sendable {
    static let shared = UserProjectionChanges()
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    private init() {
        for name in [ModelContext.didSave, Notification.Name.NSPersistentStoreRemoteChange, .cloudDataReceived] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                lock.lock(); value &+= 1; lock.unlock()
            })
        }
    }
}

final class UserInputRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    var revision: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
}
