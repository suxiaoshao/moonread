import Foundation
import SwiftData
import CoreData
import Synchronization

extension UserDataStore {
    func saveFacts(_ facts: [(String, String, String)], generation: UInt64, current: UInt64, enabled: Bool) throws {
        guard generation == (recordingGeneration ?? current), enabled, recordingEnabled else { return }
        try transaction {
            for (id, key, payload) in facts {
                let rows = try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.id == id }))
                let incoming = try UserSyncJSON.validateFact(payload, id: id)
                for row in rows { try UserSyncJSON.validateFact(row.payload, id: row.id) }
                if rows.isEmpty { modelContext.insert(ReadingFact(id: id, contentKey: key, payload: try incoming.versioned())) }
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
        while true {
            try Task.checkCancellation()
            if let facts = try await preparedFacts(keys: book.map({ [$0] })) { return facts.incomplete }
        }
    }
    struct FactInput: Sendable { let id: String; let contentKey: String; let payload: String }
    struct PreparedFact: Sendable {
        let id: String
        let day: Int64
        let contentKey: String
    }
    struct PreparedFacts: Sendable {
        let facts: [PreparedFact]
        let handle: PreparedReadingFacts?
        let incomplete: Bool
        // Use raw UTF-8 size plus a per-row allowance as an estimate, not an allocation count.
        let estimatedBytes: Int
        var firstTitle: String? { handle?.firstTitle() }
    }
    struct FactsInput: Sendable {
        var rows: [FactInput]
        let clearPayloads: [String]
        let keys: [String]?

        private struct Candidate {
            let batch: DecodedFactBatch
            let pick: FactBatchPick
            let cue: FactSelectionCue
            let id: String
            let estimatedBytes: Int
        }
        private enum Group { case candidate(Candidate), blocked }

        nonisolated mutating func prepare(session: String? = nil, requireReadable: Bool = false, cancellable: Bool = false) throws -> PreparedFacts {
            let clears = try UserDataStore.readableClears(clearPayloads, keys: keys, session: session)
            var groups: [String: Group] = [:]
            var base: UInt64 = 0
            // Pop in original fetch order so completed batches release their raw strings.
            rows.reverse()
            while !rows.isEmpty {
                if cancellable { try Task.checkCancellation() }
                var inputs: [FactInput] = [], bytes = 0
                while inputs.count < 128, let row = rows.last {
                    let size = row.payload.utf8.count
                    if !inputs.isEmpty && size > 256 * 1024 - bytes { break }
                    inputs.append(rows.removeLast())
                    bytes += size
                }
                let batch = try decodeFactBatch(base: base, payloads: inputs.map(\.payload))
                if cancellable { try Task.checkCancellation() }
                for (row, cue) in zip(inputs, batch.cues()) {
                    do {
                        let fact = try UserSyncJSON.bindFact(cue, id: row.id)
                        if groups[row.id] == nil {
                            let pick = FactBatchPick(batchId: cue.batchId, ordinal: cue.ordinal, contentKey: row.contentKey)
                            groups[row.id] = .candidate(.init(batch: batch, pick: pick, cue: fact, id: row.id,
                                estimatedBytes: row.payload.utf8.count + 256))
                        }
                    } catch {
                        if requireReadable { throw error }
                        groups[row.id] = .blocked
                    }
                }
                base += UInt64(inputs.count)
            }

            var facts: [PreparedFact] = [], selections: [FactBatchSelection] = []
            var incomplete = false, estimatedBytes = 0
            var batchID: UInt64?
            for group in groups.values {
                guard case .candidate(let candidate) = group else {
                    incomplete = true
                    UserSyncJSON.quarantined("ReadingFact")
                    continue
                }
                let cue = candidate.cue, key = candidate.pick.contentKey
                if let session, cue.sessionId != session { continue }
                if clears.contains(where: { ($0.book == nil || $0.book == key) && ($0.session == nil || $0.session == cue.sessionId)
                    && ($0.ids.contains(candidate.id) || cue.startedMs <= $0.through) }) { continue }
                // Keep store-local winner order while grouping adjacent picks from one batch.
                if batchID == candidate.pick.batchId {
                    selections[selections.count - 1].picks.append(candidate.pick)
                } else {
                    selections.append(.init(batch: candidate.batch, picks: [candidate.pick]))
                    batchID = candidate.pick.batchId
                }
                facts.append(.init(id: cue.id, day: cue.localDay, contentKey: key))
                estimatedBytes += candidate.estimatedBytes
            }
            if cancellable { try Task.checkCancellation() }
            let handle = selections.isEmpty ? nil : try sealPreparedFacts(chunks: selections)
            return PreparedFacts(facts: facts, handle: handle, incomplete: incomplete, estimatedBytes: estimatedBytes)
        }
    }

    // Transfer the value snapshot once. The task closure keeps the box, not
    // another copy of the original strings while the worker drains its batches.
    private final class FactInputBox: Sendable {
        private let input: Mutex<FactsInput?>
        init(_ input: FactsInput) { self.input = Mutex(input) }
        func take() -> FactsInput {
            input.withLock { value in
                let snapshot = value!
                value = nil
                return snapshot
            }
        }
    }

    func factRows(keys: [String]?) throws -> [ReadingFact] {
        if let keys {
            return try keys.flatMap { key in try modelContext.fetch(FetchDescriptor<ReadingFact>(predicate: #Predicate { $0.contentKey == key })) }
        }
        return try modelContext.fetch(FetchDescriptor<ReadingFact>())
    }
    func factsInput(rows: [ReadingFact], keys: [String]?) throws -> FactsInput {
        let clears = try modelContext.fetch(FetchDescriptor<StatisticsClear>()).map(\.payload)
        return FactsInput(rows: rows.map { FactInput(id: $0.id, contentKey: $0.contentKey, payload: $0.payload) },
            clearPayloads: clears, keys: keys)
    }

    private nonisolated func factVersion(keys: [String]?) -> String {
        version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: keys, fields: [])
    }

    // A newer version may have resolved an error from a completed task.
    func preparedFactsResult(_ result: Result<PreparedFacts, Error>, keys: [String]?, version: String) throws -> PreparedFacts? {
        try Task.checkCancellation()
        return factVersion(keys: keys) == version ? try result.get() : nil
    }

    // nil is an obsolete input, not an error.
    func preparedFacts(keys: [String]?) async throws -> PreparedFacts? {
        try Task.checkCancellation()
        let key = keys?.sorted().joined(separator: ",") ?? "all"
        let version = factVersion(keys: keys)
        if let cached = preparedFactsCache[key], cached.version == version { return cached.value }
        if let pending = preparedFactsWork[key] {
            if pending.version == version {
                let result = await pending.task.result
                return try preparedFactsResult(result, keys: keys, version: version)
            }
            pending.task.cancel()
        }
        let input = FactInputBox(try factsInput(rows: factRows(keys: keys), keys: keys))
        let task = Task.detached(priority: Task.currentPriority) {
            var snapshot = input.take()
            return try snapshot.prepare(cancellable: true)
        }
        let id = UUID(); preparedFactsWork[key] = (version, id, task)
        defer { if preparedFactsWork[key]?.id == id { preparedFactsWork[key] = nil } }
        let result = await task.result
        // A cancelled caller does not cancel or prevent caching the shared result.
        guard factVersion(keys: keys) == version else { try Task.checkCancellation(); return nil }
        if case .success(let facts) = result {
            let budget = 32 * 1024 * 1024
            if facts.estimatedBytes <= budget {
                let retained = preparedFactsCache.values.reduce(0) { $0 + $1.value.estimatedBytes }
                if preparedFactsCache.count >= 8 || retained > budget - facts.estimatedBytes { preparedFactsCache.removeAll() }
                preparedFactsCache[key] = (version, facts)
            }
        }
        return try preparedFactsResult(result, keys: keys, version: version)
    }
    func visibleFacts(key: String? = nil, session: String? = nil) throws -> PreparedFacts {
        let keys = key.map { [$0] }
        var input = try factsInput(rows: factRows(keys: keys), keys: keys)
        return try input.prepare(session: session)
    }
    func clear(book: String?, session: String?, newGeneration: UInt64? = nil) throws {
        try transaction {
            let facts = try visibleFacts(key: book, session: session)
            let ids = Set(facts.facts.map(\.id))
            modelContext.insert(StatisticsClear(payload: try encode(ClearValue(book: book, session: session,
                through: Int64(Date().timeIntervalSince1970 * 1000), ids: ids))))
        }
        if let newGeneration { recordingGeneration = newGeneration }
    }
}
