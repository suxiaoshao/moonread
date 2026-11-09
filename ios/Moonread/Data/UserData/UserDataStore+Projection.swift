import Foundation
import SwiftData
import CoreData

extension UserDataStore {
    private func populatedReadingKeys() throws -> Set<String> {
        let metadata = "metadata/", chapter = "chapter/", position = "position/", opened = "opened/"
        let values = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate {
            $0.key.starts(with: metadata) || $0.key.starts(with: chapter) || $0.key.starts(with: position) || $0.key.starts(with: opened)
        }))
        // This is only a broad presence filter, never a second parser or LWW
        // decision. All selected candidates go through scopedValues unchanged.
        var result = Set(values.compactMap { row in row.key.split(separator: "/", maxSplits: 2).dropFirst().first.map(String.init) })
        result.formUnion(try modelContext.fetch(FetchDescriptor<UserPosition>()).map(\.contentKey))
        return result
    }
    private func scopedValues(_ contentKey: String, fields: UserProjectionDomain = .reading) throws -> ValueSnapshot {
        var result = ValueSnapshot()
        if fields.contains(.position) { try result.merge(valueSnapshot(key: "position/" + contentKey)) }
        var prefixes: [String] = []
        if fields.contains(.opened) { try result.merge(valueSnapshot(key: "opened/" + contentKey)) }
        if fields.contains(.metadata) { prefixes.append("metadata/" + contentKey + "/") }
        if fields.contains(.chapter) { prefixes.append("chapter/" + contentKey + "/") }
        for prefix in prefixes {
            let next = try valueSnapshot(prefix: prefix)
            try result.merge(next)
        }
        return result
    }
    func positionValues() throws -> [String: StoredValue] { try valueSnapshot(prefix: "position/").values }
    func projection(generation: UInt64, enabled: Bool, includeFacts: Bool, keys: [String]? = nil, positionsOnly: Bool = false, statisticsBook: String? = nil, statisticsKeys: [String]? = nil, fields: UserProjectionDomain = .reading, diagnostic: ReaderOpenTrace? = nil, diagnosticScope: String = "projection", sparseCatalogue: Bool = false, statisticsRange: ClosedRange<Int64>? = nil) async throws -> String {
        diagnostic?.mark(diagnosticScope + ".actor.begin")
        defer { diagnostic?.mark(diagnosticScope + ".actor.return") }
        let factKeys = statisticsKeys ?? statisticsBook.map { [$0] }
        let rangeKey = statisticsRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "full"
        let cacheKey = rangeKey + "-\(generation)-\(enabled)-\(includeFacts)-\(positionsOnly)-\(factKeys?.sorted().joined(separator: ",") ?? "all")-\(sparseCatalogue)-\(fields.rawValue)-" + (keys?.sorted().joined(separator: ",") ?? "all")
        let version = version(keys: keys, positionsOnly: positionsOnly, includeFacts: includeFacts, statisticsKeys: factKeys, fields: fields)
        if let cached = projectionCache[cacheKey], cached.0 == version { diagnostic?.mark(diagnosticScope + ".cacheHit"); return cached.1 }
        if let work = projectionWork[cacheKey], work.version == version { return try await work.task.value }
        let facts = includeFacts ? try await preparedFacts(keys: factKeys) : nil
        // Preparation may suspend. Rejoin a projection already started by a
        // concurrent date/page request rather than duplicating its JSON work.
        if let cached = projectionCache[cacheKey], cached.0 == version { return cached.1 }
        if let work = projectionWork[cacheKey], work.version == version { return try await work.task.value }
        let valueKeys = keys ?? statisticsRange.map { range in
            Array(Set(facts?.facts.filter { range.contains($0.day) }.map(\.contentKey) ?? []))
        }
        diagnostic?.mark(diagnosticScope + ".fetch.begin")
        let snapshot: ValueSnapshot
        if positionsOnly {
            var recent = try valueSnapshot(prefix: "position/")
            try recent.merge(valueSnapshot(prefix: "opened/")); snapshot = recent
        }
        else if let keys = valueKeys {
            var scoped = ValueSnapshot()
            // Large catalogues are mostly unread files without user data. One
            // metadata-only presence pass avoids three empty fetches per file;
            // populated keys still use the sole scoped projection/check below.
            let present = sparseCatalogue ? try populatedReadingKeys() : nil
            for key in keys where present?.contains(key) ?? true {
                let next = try scopedValues(key, fields: fields)
                try scoped.merge(next)
            }
            snapshot = scoped
        } else if fields == .reading { snapshot = try valueSnapshot() }
        else {
            var selected = ValueSnapshot()
            for (prefix, domain) in [("position/", UserProjectionDomain.position), ("opened/", .opened), ("metadata/", .metadata), ("chapter/", .chapter)] where fields.contains(domain) {
                try selected.merge(valueSnapshot(prefix: prefix))
            }
            snapshot = selected
        }
        diagnostic?.mark(diagnosticScope + ".fetch.return")
        // No ModelContext or @Model escapes this actor. Only immutable value
        // copies enter JSON/candidate computation, so saves can proceed meanwhile.
        let task = Task.detached(priority: Task.currentPriority) {
            diagnostic?.mark(diagnosticScope + ".json.begin")
            defer { diagnostic?.mark(diagnosticScope + ".json.return") }
            return try Self.encodeProjection(snapshot, facts: facts, generation: generation, enabled: enabled, statisticsRange: statisticsRange)
        }
        let id = UUID(); projectionWork[cacheKey] = ProjectionWork(version: version, id: id, task: task)
        defer { if projectionWork[cacheKey]?.id == id { projectionWork[cacheKey] = nil } }
        let json = try await task.value
        if self.version(keys: keys, positionsOnly: positionsOnly, includeFacts: includeFacts, statisticsKeys: factKeys, fields: fields) == version {
            if projectionCache.count > 32 { projectionCache.removeAll() }
            projectionCache[cacheKey] = (version, json)
        }
        return json
    }
    private nonisolated static func encodeProjection(_ snapshot: ValueSnapshot, facts: PreparedFacts?, generation: UInt64, enabled: Bool, statisticsRange: ClosedRange<Int64>?) throws -> String {
        let all = snapshot.values
        var metadata: [String: [String: Any]] = [:]
        for (key, stored) in all where key.hasPrefix("metadata/") {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            var item = metadata[parts[1]] ?? ["sha": parts[1], "author": "", "synopsis": "", "tags": [String](), "cover": NSNull(), "status": "Unread"]
            if parts[2].hasPrefix("tag-") {
                var tags = item["tags"] as? [String] ?? []
                if let tag = try JSONSerialization.jsonObject(with: Data(stored.value.utf8), options: .fragmentsAllowed) as? String { tags.append(tag) }
                item["tags"] = tags.sorted()
            } else { item[parts[2]] = try JSONSerialization.jsonObject(with: Data(stored.value.utf8), options: .fragmentsAllowed) }
            metadata[parts[1]] = item
        }
        let positions = try all.filter { $0.key.hasPrefix("position/") }.map { try PositionCandidate($0.value).projection() }
        let opened = try all.filter { $0.key.hasPrefix("opened/") }.map { key, stored -> [String: Any] in
            ["content_key": String(key.dropFirst(7)), "opened_ms": try JSONDecoder().decode(Int64.self, from: Data(stored.value.utf8)), "updated": stored.updated, "token": stored.token]
        }
        let corrections = try all.filter { $0.key.hasPrefix("chapter/") && $0.value.value != "null" }.map { try JSONSerialization.jsonObject(with: Data($0.value.value.utf8)) }
        let result: [String: Any] = ["positions": positions, "opened": opened, "metadata": Array(metadata.values), "corrections": corrections,
            "unsupportedPositions": snapshot.blocked.filter { $0.hasPrefix("position/") }.map { String($0.dropFirst(9)) },
            "facts": try facts?.values(range: statisticsRange) ?? [], "statisticsIncomplete": facts?.incomplete ?? false, "generation": generation, "enabled": enabled]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
        return json
    }
}
