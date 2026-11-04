import Foundation
import SwiftData
import CoreData

extension UserDataStore {
    func saveFacts(_ facts: [(String, String, String)], generation: UInt64, current: UInt64, enabled: Bool) throws {
        guard generation == (recordingGeneration ?? current), enabled, recordingEnabled else { return }
        try transaction {
            for (id, key, payload) in facts {
                let rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id }))
                try UserSyncJSON.validateFact(payload, id: id)
                for row in rows { try UserSyncJSON.validateFact(row.payload, id: row.id) }
                if rows.isEmpty { modelContext.insert(ReadingFact(id: id, contentKey: key, payload: try UserSyncJSON.versioned(payload))) }
            }
        }
    }
    func requireStatisticsReadable(book: String? = nil, session: String? = nil) throws {
        for row in try modelContext.fetch(FetchDescriptor<StatisticsClear>()) {
            do { _ = try decode(ClearValue.self, row.payload) }
            catch {
                let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(row.payload.utf8))
                if scope == nil || scope!.intersects(book: book, session: session) {
                    UserSyncJSON.quarantined("StatisticsClear")
                    var issue = (error as? UserSyncCompatibilityError) ?? UserSyncCompatibilityError()
                    issue.statistics = true
                    throw issue
                }
            }
        }
    }
    func statisticsIncomplete(book: String? = nil) throws -> Bool {
        try requireStatisticsReadable(book: book)
        let rows: [ReadingFact]
        if let book { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == book })) }
        else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        return rows.contains { (try? UserSyncJSON.validateFact($0.payload, id: $0.id)) == nil }
    }
    func visibleFacts(key: String? = nil, session: String? = nil) throws -> [[String: Any]] {
        try requireStatisticsReadable(book: key, session: session)
        let clears = try modelContext.fetch(FetchDescriptor<StatisticsClear>()).compactMap { try? decode(ClearValue.self, $0.payload) }
        var groups: [String: [ReadingFact]] = [:], facts: [[String: Any]] = []
        let rows: [ReadingFact]
        if let key { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) }
        else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        for row in rows { groups[row.id, default: []].append(row) }
        for copies in groups.values {
            // An unknown sibling must not be hidden by the order CloudKit delivered duplicates.
            guard copies.allSatisfy({ (try? UserSyncJSON.validateFact($0.payload, id: $0.id)) != nil }), let row = copies.first else {
                UserSyncJSON.quarantined("ReadingFact"); continue
            }
            var value = try JSONSerialization.jsonObject(with: Data(row.payload.utf8)) as! [String: Any]
            let slice = value["slice"] as! [String: Any]
            if let session, slice["session_id"] as? String != session { continue }
            let start = (slice["started_ms"] as! NSNumber).int64Value
            value["content_key"] = row.contentKey
            if clears.contains(where: { ($0.book == nil || $0.book == row.contentKey) && ($0.session == nil || $0.session == slice["session_id"] as? String) && ($0.ids.contains(row.id) || start <= $0.through) }) { continue }
            facts.append(value)
        }
        return facts
    }
    func clear(book: String?, session: String?, newGeneration: UInt64? = nil) throws {
        try transaction {
            try requireStatisticsReadable(book: book, session: session)
            let facts = try visibleFacts(key: book, session: session)
            let ids = Set(facts.compactMap { value -> String? in
                (value["slice"] as? [String: Any])?["id"] as? String
            })
            modelContext.insert(StatisticsClear(payload: try encode(ClearValue(book: book, session: session,
                through: Int64(Date().timeIntervalSince1970 * 1000), ids: ids))))
        }
        if let newGeneration { recordingGeneration = newGeneration }
    }
}
