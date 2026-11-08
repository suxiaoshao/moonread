import Foundation
import SwiftData
import CoreData

extension UserDataStore {
    struct ValueSnapshot: Sendable {
        var values: [String: StoredValue] = [:]
        var blocked = Set<String>()
        mutating func include(key: String, payload: String) {
            guard UserSyncJSON.kind(key) != nil else { return }
            do {
                let value = try UserSyncJSON.storedValue(payload, key: key)
                guard !blocked.contains(key) else { return }
                try select(key: key, value: value)
            } catch {
                // Shelf descriptions are independent hints. An unsupported
                // record stays stored but cannot poison a readable sibling or
                // replace it through LWW. Reading facts remain fail-closed.
                if !key.hasPrefix("shelf-reference/") {
                    blocked.insert(key); values.removeValue(forKey: key)
                }
                UserSyncJSON.quarantined("UserValue/UserPosition")
            }
        }
        mutating func select(key: String, value: StoredValue) throws {
            if key.hasPrefix("position/") {
                values[key] = try PositionCandidate.winner(values[key].map(PositionCandidate.init), PositionCandidate(value)).stored
            } else {
                if let old = values[key], (old.updated, old.token) >= (value.updated, value.token) { return }
                values[key] = value
            }
        }
        mutating func merge(_ next: Self) throws {
            for (key, value) in next.values { try select(key: key, value: value) }
            blocked.formUnion(next.blocked)
        }
    }
    func valueSnapshot(key: String? = nil, prefix: String? = nil) throws -> ValueSnapshot {
        let rows: [UserValue]
        if let key { rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key })) }
        else if let prefix { rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key.starts(with: prefix) })) }
        else { rows = try modelContext.fetch(FetchDescriptor<UserValue>()) }
        var result = ValueSnapshot()
        for row in rows { result.include(key: row.key, payload: row.payload) }
        let positionRows: [UserPosition]
        let includesPositions = prefix.map { $0.hasPrefix("position/") || "position/".hasPrefix($0) } ?? true
        if let key, key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
        } else if key == nil, includesPositions {
            positionRows = try modelContext.fetch(FetchDescriptor<UserPosition>())
        } else { positionRows = [] }
        for row in positionRows where prefix.map({ ("position/" + row.contentKey).hasPrefix($0) }) ?? true {
            result.include(key: "position/" + row.contentKey, payload: row.payload)
        }
        return result
    }
    func sourceDecodingSnapshot() throws -> SourceDecodingSnapshot {
        let snapshot = try valueSnapshot(prefix: "source-decoding/")
        return SourceDecodingSnapshot(values: snapshot.values, blocked: snapshot.blocked)
    }
    func values(key: String? = nil) throws -> [String: StoredValue] { try valueSnapshot(key: key).values }
    func requireValueReadable(_ key: String) throws {
        guard try !valueSnapshot(key: key).blocked.contains(key) else { throw UserSyncCompatibilityError() }
    }
    private func obsoletePositionRows(key: String) throws -> [UserPosition] {
        let snapshot = try valueSnapshot(key: "position/" + key)
        guard !snapshot.blocked.contains("position/" + key) else { return [] }
        let winner = snapshot.values["position/" + key]?.token
        let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
        return try rows.filter { try UserSyncJSON.storedValue($0.payload, key: "position/" + key).token != winner }
    }
    func compactPositions(key: String) throws {
        let obsolete = try obsoletePositionRows(key: key)
        if !obsolete.isEmpty { try transaction { for row in obsolete { modelContext.delete(row) } } }
    }
    func compactPositionsWithoutSave(key: String) throws {
        for row in try obsoletePositionRows(key: key) { modelContext.delete(row) }
    }
    func value(_ key: String) throws -> String? {
        try storedValue(key)?.value
    }
    func storedValue(_ key: String) throws -> StoredValue? {
        let snapshot = try valueSnapshot(key: key)
        guard !snapshot.blocked.contains(key) else { throw UserSyncCompatibilityError() }
        return snapshot.values[key]
    }
    @discardableResult func put(_ key: String, value: String, device: String) throws -> StoredValue {
        try transaction { try putWithoutSave(key, value: value, device: device) }
    }
    @discardableResult private func putWithoutSave(_ key: String, value: String, device: String) throws -> StoredValue {
        try UserSyncJSON.validateValue(value, key: key)
        try requireValueReadable(key)
        let rows = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == key && $0.device == device }))
        for row in rows { _ = try UserSyncJSON.storedValue(row.payload, key: key) }
        let latest = try values(key: key)[key]?.updated ?? 0
        guard latest < Int64.max else { throw UserSyncCompatibilityError() }
        let stored = StoredValue(updated: max(Int64(Date().timeIntervalSince1970 * 1000), latest + 1), token: UUID().uuidString, value: value)
        let payload = try encode(stored)
        if key.hasPrefix("position/") {
            let contentKey = String(key.dropFirst(9))
            let old = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == contentKey }))
            for row in old { _ = try UserSyncJSON.storedValue(row.payload, key: key) }
            modelContext.insert(UserPosition(contentKey: contentKey, payload: payload))
            for row in old { modelContext.delete(row) }
        } else if let row = rows.first { row.payload = payload; for duplicate in rows.dropFirst() { modelContext.delete(duplicate) } }
        else { modelContext.insert(UserValue(key: key, device: device, payload: payload)) }
        return stored
    }
    struct CoverWrite: Sendable { let id: String; let bytes: Data }
    func putValues(_ values: [String: String], device: String, cover: CoverWrite? = nil) throws {
        try transaction {
            if let cover { try saveCoverWithoutSave(id: cover.id, bytes: cover.bytes) }
            for (key, value) in values { try putWithoutSave(key, value: value, device: device) }
        }
    }
    func allValues(prefix: String) throws -> [String: String] {
        let snapshot = try valueSnapshot(prefix: prefix)
        guard snapshot.blocked.isEmpty else { throw UserSyncCompatibilityError() }
        return snapshot.values.mapValues(\.value)
    }

    /// Unsupported descriptions remain stored, but do not block unrelated hints.
    func shelfReferences() throws -> [ShelfReference] {
        try valueSnapshot(prefix: "shelf-reference/").values.map { key, stored in
            ShelfReference(id: String(key.dropFirst("shelf-reference/".count)), value: try JSONDecoder().decode(ShelfReferenceValue.self, from: Data(stored.value.utf8)))
        }
    }

    struct RecentPosition: Sendable, Equatable {
        let contentKey: String
        let token: String
        let updated: Int64
        let hint: PositionSourceHint?
    }
    /// Unsupported records are retained and excluded individually; they cannot
    /// suppress recovery for unrelated keys or become editable through recovery.
    func recentRestorationPositions(limit: Int, excluding: Set<String> = []) throws -> [RecentPosition] {
        try valueSnapshot(prefix: "position/").values.compactMap { key, stored in
            let value = try decode(PositionValue.self, stored.value)
            guard let key = try? parseReadingKey(value: value.content_key), case .formal = key, !excluding.contains(value.content_key) else { return nil }
            return RecentPosition(contentKey: value.content_key, token: stored.token, updated: stored.updated, hint: value.source_hint)
        }.sorted { ($0.updated, $0.contentKey) > ($1.updated, $1.contentKey) }.prefix(max(0, limit)).map { $0 }
    }
}
