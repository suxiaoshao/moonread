import Foundation
import SwiftData
import CoreData

struct UserDataTransfer: Sendable {
    struct Operation: Sendable { let id: String; let mark: String; let payload: String }
    struct Fact: Sendable { let id: String; let payload: String }
    var opened: String? = nil
    let positions: [String]
    let operations: [Operation]
    let facts: [Fact]
}
extension UserDataStore {
    func pendingKeys() throws -> Set<String> {
        var result = Set(try modelContext.fetch(FetchDescriptor<AnnotationOperation>()).map(\.contentKey))
        result.formUnion(try modelContext.fetch(FetchDescriptor<ReadingFact>()).map(\.contentKey))
        result.formUnion(try modelContext.fetch(FetchDescriptor<UserPosition>()).map(\.contentKey))
        for row in try modelContext.fetch(FetchDescriptor<StatisticsClear>()) where (try? decode(ClearValue.self, row.payload)) == nil {
            if let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(row.payload.utf8)), let book = scope.book { result.insert(book) }
        }
        for row in try modelContext.fetch(FetchDescriptor<UserValue>()) where row.key.hasPrefix("opened/") { result.insert(String(row.key.dropFirst(7))) }
        return result.filter { if let key = try? parseReadingKey(value: $0), case .pending = key { return true }; return false }
    }
    func requirePendingReadable(key: String) throws {
        try requireValueReadable("position/" + key)
        try requireValueReadable("opened/" + key)
        guard try blockedMarks(key: key).isEmpty else { throw UserSyncCompatibilityError() }
        try requireStatisticsReadable(book: key)
        let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key }))
        for row in facts { try UserSyncJSON.validateFact(row.payload, id: row.id) }
    }
    func exportPending(key: String) throws -> UserDataTransfer {
        try requirePendingReadable(key: key)
        let positions = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key })).map(\.payload)
        let operations = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
            .map { UserDataTransfer.Operation(id: $0.id, mark: $0.markID, payload: $0.payload) }
        let visible = Set(try visibleFacts(key: key).compactMap { ($0["slice"] as? [String: Any])?["id"] as? String })
        let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })).filter { visible.contains($0.id) }
            .map { UserDataTransfer.Fact(id: $0.id, payload: $0.payload) }
        return UserDataTransfer(opened: try storedValue("opened/" + key).map { try encode($0) }, positions: positions, operations: operations, facts: facts)
    }
    // Shared immutable-record intake for pending promotion and portable backup.
    func mergePositionRecord(key: String, payload: String) throws {
        let incoming = try PositionCandidate(UserSyncJSON.storedValue(payload, key: "position/" + key))
        let rows = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
        for row in rows {
            let old = try UserSyncJSON.storedValue(row.payload, key: "position/" + key)
            if old.token == incoming.stored.token {
                guard try PositionCandidate.sameUpdate(old, incoming.stored) else { throw UserSyncCompatibilityError() }
            }
        }
        let old = try values(key: "position/" + key)["position/" + key]
        let winner = try PositionCandidate.winner(old.map(PositionCandidate.init), incoming).stored
        if old?.token != winner.token || old?.updated != winner.updated {
            for row in rows { modelContext.delete(row) }
            modelContext.insert(UserPosition(contentKey: key, payload: payload))
        }
    }
    func mergeOperationRecord(key: String, id: String, mark: String, payload: String) throws {
        _ = try UserSyncJSON.annotation(payload, id: id)
        let rows = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.id == id }))
        for row in rows {
            _ = try UserSyncJSON.annotation(row.payload, id: row.id)
            guard row.contentKey == key, row.markID == mark, Self.samePayload(row.payload, payload) else { throw UserSyncCompatibilityError() }
        }
        if rows.isEmpty { modelContext.insert(AnnotationOperation(id: id, contentKey: key, markID: mark, payload: payload)) }
    }
    func mergeFactRecord(key: String, id: String, payload: String) throws {
        try UserSyncJSON.validateFact(payload, id: id)
        let rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id }))
        for row in rows {
            try UserSyncJSON.validateFact(row.payload, id: row.id)
            guard row.contentKey == key, Self.samePayload(row.payload, payload) else { throw UserSyncCompatibilityError() }
        }
        if rows.isEmpty { modelContext.insert(ReadingFact(id: id, contentKey: key, payload: payload)) }
    }
    func importPending(_ transfer: UserDataTransfer, from: String, to: String) throws {
        try transaction {
            try requirePendingReadable(key: to)
            // Validate the complete snapshot before any insert. A failure rolls back all kinds.
            for value in transfer.positions { _ = try UserSyncJSON.storedValue(value, key: "position/" + from) }
            for value in transfer.operations { _ = try UserSyncJSON.annotation(value.payload, id: value.id) }
            for value in transfer.facts { try UserSyncJSON.validateFact(value.payload, id: value.id) }
            if let opened = transfer.opened {
                _ = try UserSyncJSON.storedValue(opened, key: "opened/" + from)
                try mergeValueRecord(key: "opened/" + to, device: "pending-promotion", payload: opened)
            }
            for value in transfer.positions {
                let incoming = try PositionCandidate(decode(StoredValue.self, value)).rekeyed(to: to)
                try mergePositionRecord(key: to, payload: encode(incoming.stored))
            }
            for value in transfer.operations {
                let mark = value.mark.hasPrefix("bookmark/" + from + "/") ? "bookmark/" + to + "/" + value.mark.split(separator: "/").last! : value.mark
                try mergeOperationRecord(key: to, id: value.id, mark: mark, payload: UserSyncJSON.versioned(value.payload))
            }
            for value in transfer.facts { try mergeFactRecord(key: to, id: value.id, payload: UserSyncJSON.versioned(value.payload)) }

        }
    }
    func removePending(key: String) throws {
        try transaction {
            try requirePendingReadable(key: key)
            let positions = try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { $0.contentKey == key }))
            let operations = try modelContext.fetch(FetchDescriptor<AnnotationOperation>(predicate: #Predicate { $0.contentKey == key }))
            let facts = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key }))
            for row in positions { _ = try UserSyncJSON.storedValue(row.payload, key: "position/" + key) }
            for row in operations { _ = try UserSyncJSON.annotation(row.payload, id: row.id) }
            for row in facts { try UserSyncJSON.validateFact(row.payload, id: row.id) }
            let openedKey = "opened/" + key
            for row in try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { $0.key == openedKey })) { modelContext.delete(row) }
            for row in positions { modelContext.delete(row) }
            for row in operations { modelContext.delete(row) }
            for row in facts { modelContext.delete(row) }
        }
    }
}
