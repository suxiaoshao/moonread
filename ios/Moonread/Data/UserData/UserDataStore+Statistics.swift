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
    private nonisolated static func readableClears(_ payloads: [String], keys: [String]?, session: String? = nil) throws -> [ClearValue] {
        try payloads.compactMap { payload in
            do { return try UserSyncJSON.decode(ClearValue.self, payload, as: UserSyncJSON.clear, envelope: true) }
            catch {
                let scope = try? JSONDecoder().decode(UserSyncClearScope.self, from: Data(payload.utf8))
                if scope == nil || keys.map({ keys in keys.contains { scope!.intersects(book: $0, session: session) } }) ?? true {
                    UserSyncJSON.quarantined("StatisticsClear")
                    var issue = (error as? UserSyncCompatibilityError) ?? UserSyncCompatibilityError()
                    issue.statistics = true
                    throw issue
                }
                return nil
            }
        }
    }
    func requireStatisticsReadable(book: String? = nil, session: String? = nil) throws {
        _ = try Self.readableClears(modelContext.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload), keys: book.map { [$0] }, session: session)
    }
    func statisticsIncomplete(book: String? = nil) async throws -> Bool {
        try await preparedFacts(keys: book.map { [$0] }).incomplete
    }
    struct FactInput: Sendable { let id: String; let contentKey: String; let payload: String }
    struct PreparedFact: Sendable {
        let day: Int64
        let contentKey: String
        let full: Data
        let statistics: Data
    }
    struct PreparedFacts: Sendable {
        let facts: [PreparedFact]
        let incomplete: Bool
        func values(range: ClosedRange<Int64>? = nil) throws -> [[String: Any]] {
            try facts.filter { range?.contains($0.day) ?? true }.map {
                try JSONSerialization.jsonObject(with: range == nil ? $0.full : $0.statistics) as! [String: Any]
            }
        }
    }
    struct FactsInput: Sendable {
        let rows: [FactInput]
        let clearPayloads: [String]
        let keys: [String]?
        nonisolated func prepare(session: String? = nil) throws -> PreparedFacts {
            let clears = try UserDataStore.readableClears(clearPayloads, keys: keys, session: session)
            var groups: [String: [FactInput]] = [:], facts: [PreparedFact] = []
            var incomplete = false
            for row in rows { groups[row.id, default: []].append(row) }
            for copies in groups.values {
                // Keep the one compatibility/candidate rule: an unknown sibling
                // blocks its entire id even outside the requested date range.
                guard copies.allSatisfy({ (try? UserSyncJSON.validateFact($0.payload, id: $0.id)) != nil }), let row = copies.first else {
                    UserSyncJSON.quarantined("ReadingFact"); incomplete = true; continue
                }
                var value = try JSONSerialization.jsonObject(with: Data(row.payload.utf8)) as! [String: Any]
                var slice = value["slice"] as! [String: Any]
                if let session, slice["session_id"] as? String != session { continue }
                let start = (slice["started_ms"] as! NSNumber).int64Value
                value["content_key"] = row.contentKey
                if clears.contains(where: { ($0.book == nil || $0.book == row.contentKey) && ($0.session == nil || $0.session == slice["session_id"] as? String) && ($0.ids.contains(row.id) || start <= $0.through) }) { continue }
                let full = try JSONSerialization.data(withJSONObject: value)
                // Overview needs no coverage geometry; activity navigation only
                // reads the first exposure's original start. Do not carry all
                // exposures through JSON/TEMP again for every date selection.
                slice["exposures"] = Array((slice["exposures"] as? [[String: Any]] ?? []).prefix(1))
                value["slice"] = slice
                facts.append(.init(day: (slice["local_day"] as! NSNumber).int64Value, contentKey: row.contentKey, full: full,
                                   statistics: try JSONSerialization.data(withJSONObject: value)))
            }
            return PreparedFacts(facts: facts, incomplete: incomplete)
        }
        nonisolated func visible(session: String? = nil) throws -> [[String: Any]] { try prepare(session: session).values() }
    }
    func factsInput(keys: [String]? = nil) throws -> FactsInput {
        let clears = try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload)
        let rows: [ReadingFact]
        if let keys {
            rows = try keys.flatMap { key in try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) }
        } else { rows = try modelContext.fetch(FetchDescriptor<ReadingFact>()) }
        return FactsInput(rows: rows.map { FactInput(id: $0.id, contentKey: $0.contentKey, payload: $0.payload) }, clearPayloads: clears, keys: keys)
    }
    func preparedFacts(keys: [String]?) async throws -> PreparedFacts {
        let key = keys?.sorted().joined(separator: ",") ?? "all"
        let version = version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: keys, fields: [])
        if let cached = preparedFactsCache[key], cached.version == version { return cached.value }
        if let pending = preparedFactsWork[key], pending.version == version { return try await pending.task.value }
        let input = try factsInput(keys: keys)
        let task = Task.detached(priority: Task.currentPriority) { try input.prepare() }
        let id = UUID(); preparedFactsWork[key] = (version, id, task)
        defer { if preparedFactsWork[key]?.id == id { preparedFactsWork[key] = nil } }
        let result = try await task.value
        if self.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: keys, fields: []) == version {
            if preparedFactsCache.count >= 8 { preparedFactsCache.removeAll() }
            preparedFactsCache[key] = (version, result)
        }
        return result
    }
    func visibleFacts(key: String? = nil, session: String? = nil) throws -> [[String: Any]] {
        try factsInput(keys: key.map { [$0] }).visible(session: session)
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
