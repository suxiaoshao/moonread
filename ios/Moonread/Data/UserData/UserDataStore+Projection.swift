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
        // decision. All selected keys use the same batched projection.
        var result = Set(values.compactMap { row in row.key.split(separator: "/", maxSplits: 2).dropFirst().first.map(String.init) })
        result.formUnion(try modelContext.fetch(FetchDescriptor<UserPosition>()).map(\.contentKey))
        return result
    }
    private func scopedValues(_ keys: [String], fields: UserProjectionDomain, filter: UserProjectionFilter) throws -> ValueSnapshot {
        var result = ValueSnapshot()
        let keys = Array(Set(keys)).sorted()
        let narrow = !fields.contains(.metadata) && !fields.intersection(.metadataFields).isEmpty
        let fullMetadata = fields.contains(.metadata) || (narrow && filter.preserveMetadataWinner)
        let requestedFixed = narrow && !fullMetadata
            ? UserProjectionDomain.fixedMetadata.filter { fields.contains($0.1) }.map(\.0) : []
        for start in stride(from: 0, to: keys.count, by: 128) {
            try Task.checkCancellation()
            let page = Array(keys[start..<min(start + 128, keys.count)])
            let direct = page.filter { !filter.coverOnly.contains($0) }
            let opened = filter.openedAliasesOnly ? direct.filter { $0.hasPrefix("pending:") } : direct
            let exact = (fields.contains(.position) ? direct.map { "position/" + $0 } : [])
                + (fields.contains(.opened) ? opened.map { "opened/" + $0 } : [])
                + page.flatMap { key in requestedFixed.map { "metadata/\(key)/" + $0 } }
            if !exact.isEmpty {
                for row in try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate { exact.contains($0.key) })) {
                    result.include(key: row.key, payload: row.payload)
                }
            }
            if fields.contains(.position), !direct.isEmpty {
                for row in try modelContext.fetch(FetchDescriptor<UserPosition>(predicate: #Predicate { direct.contains($0.contentKey) })) {
                    result.include(key: "position/" + row.contentKey, payload: row.payload)
                }
            }
        }

        // Tags and chapter offsets are open-ended suffixes. Use a bounded OR of
        // SQL-translatable prefix comparisons instead of fetching other books' rows.
        let prefixes = (fullMetadata ? keys.map { "metadata/" + $0 + "/" }
            : (fields.contains(.tags) ? keys.map { "metadata/" + $0 + "/tag-" } : []))
            + (fields.contains(.chapter) ? keys.filter { !filter.coverOnly.contains($0) }.map { "chapter/" + $0 + "/" } : [])
        for start in stride(from: 0, to: prefixes.count, by: 8) {
            try Task.checkCancellation()
            let page = Array(prefixes[start..<min(start + 8, prefixes.count)])
            let last = page.count - 1
            let p0 = page[min(0, last)], p1 = page[min(1, last)], p2 = page[min(2, last)], p3 = page[min(3, last)]
            let p4 = page[min(4, last)], p5 = page[min(5, last)], p6 = page[min(6, last)], p7 = page[min(7, last)]
            let predicate = #Predicate<UserValue> {
                (($0.key.starts(with: p0) || $0.key.starts(with: p1))
                  || ($0.key.starts(with: p2) || $0.key.starts(with: p3)))
                  || (($0.key.starts(with: p4) || $0.key.starts(with: p5))
                      || ($0.key.starts(with: p6) || $0.key.starts(with: p7)))
            }
            for row in try modelContext.fetch(FetchDescriptor<UserValue>(predicate: predicate)) {
                result.include(key: row.key, payload: row.payload)
            }
        }
        return result
    }
    func positionValues() throws -> [String: StoredValue] { try valueSnapshot(prefix: "position/").values }
    struct ProjectionInput: Sendable {
        let json: String
        let blockedMetadata: Set<String>
    }
    struct StoreProjection: Sendable {
        let input: ProjectionInput
        var json: String { input.json }
        let facts: FactQuerySelection?
        let statisticsIncomplete: Bool
    }

    // A nil projection has obsolete inputs and must be retried by the query owner.
    func projection(generation: UInt64, enabled: Bool, includeFacts: Bool, keys: [String]? = nil, positionsOnly: Bool = false, statisticsBook: String? = nil, statisticsKeys: [String]? = nil, fields: UserProjectionDomain = .reading, diagnostic: ReaderOpenTrace? = nil, diagnosticScope: String = "projection", sparseCatalogue: Bool = false, statisticsRange: ClosedRange<Int64>? = nil, filter: UserProjectionFilter = .init()) async throws -> StoreProjection? {
        try Task.checkCancellation()
        diagnostic?.mark(diagnosticScope + ".actor.begin")
        defer { diagnostic?.mark(diagnosticScope + ".actor.return") }
        let factKeys = statisticsKeys ?? statisticsBook.map { [$0] }
        let rangeKey = statisticsRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "full"
        let cacheKey = rangeKey + "-\(generation)-\(enabled)-\(includeFacts)-\(positionsOnly)-\(factKeys?.sorted().joined(separator: ",") ?? "all")-\(sparseCatalogue)-\(fields.rawValue)-\(filter.cacheKey)-" + (keys?.sorted().joined(separator: ",") ?? "all")
        func currentVersion() -> String { self.version(keys: keys, positionsOnly: positionsOnly, includeFacts: includeFacts, statisticsKeys: factKeys, fields: fields, filter: filter) }
        let version = currentVersion()
        let facts: PreparedFacts?
        if includeFacts {
            guard let prepared = try await preparedFacts(keys: factKeys), currentVersion() == version else { return nil }
            facts = prepared
        } else { facts = nil }

        var indices: [UInt64]?
        var valueKeys = keys
        if let range = statisticsRange {
            var selected: [UInt64] = [], scoped = Set<String>()
            for (index, fact) in (facts?.facts ?? []).enumerated() where range.contains(fact.day) {
                selected.append(UInt64(index))
                if keys == nil { scoped.insert(fact.contentKey) }
            }
            indices = selected
            if keys == nil { valueKeys = Array(scoped) }
        }
        let selection = facts?.handle.map { FactQuerySelection(prepared: $0, preparedId: $0.preparedId(), indices: indices) }
        func projection(_ input: ProjectionInput) -> StoreProjection {
            .init(input: input, facts: selection, statisticsIncomplete: facts?.incomplete ?? false)
        }
        if let cached = projectionCache[cacheKey], cached.0 == version {
            diagnostic?.mark(diagnosticScope + ".cacheHit")
            return projection(cached.1)
        }
        if let work = projectionWork[cacheKey], work.version == version {
            let result = await work.task.result
            try Task.checkCancellation()
            return currentVersion() == version ? try projection(result.get()) : nil
        }
        diagnostic?.mark(diagnosticScope + ".fetch.begin")
        let snapshot: ValueSnapshot
        if positionsOnly {
            var recent = try valueSnapshot(prefix: "position/")
            try recent.merge(valueSnapshot(prefix: "opened/")); snapshot = recent
        }
        else if let keys = valueKeys {
            // The existing all-library system catalogue can still skip unread
            // files. Folder projections never need an unscoped presence scan.
            let scope = sparseCatalogue ? try keys.filter(populatedReadingKeys().contains) : keys
            snapshot = try scopedValues(scope, fields: fields, filter: filter)
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
            let blockedMetadata = Set(snapshot.blocked.compactMap { key -> String? in
                guard key.hasPrefix("metadata/") else { return nil }
                return key.split(separator: "/", maxSplits: 2).dropFirst().first.map(String.init)
            })
            return try ProjectionInput(json: Self.encodeProjection(snapshot, generation: generation, enabled: enabled, fields: fields),
                                       blockedMetadata: blockedMetadata)
        }
        let id = UUID(); projectionWork[cacheKey] = ProjectionWork(version: version, id: id, task: task)
        defer { if projectionWork[cacheKey]?.id == id { projectionWork[cacheKey] = nil } }
        let result = await task.result
        guard currentVersion() == version else { try Task.checkCancellation(); return nil }
        if case .success(let input) = result {
            if projectionCache.count > 32 { projectionCache.removeAll() }
            // The JSON cache never retains prepared facts, including oversized results.
            projectionCache[cacheKey] = (version, input)
        }
        try Task.checkCancellation()
        return try projection(result.get())
    }
    private nonisolated static func encodeProjection(_ snapshot: ValueSnapshot, generation: UInt64, enabled: Bool, fields: UserProjectionDomain) throws -> String {
        let all = snapshot.values
        var metadata: [String: [String: Any]] = [:]
        for (key, stored) in all where key.hasPrefix("metadata/") {
            let parts = key.split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            var item = metadata[parts[1]] ?? ["sha": parts[1], "author": "", "synopsis": "", "tags": [String](), "cover": NSNull(), "status": "Unread"]
            // A readable omitted field can still make the pending object
            // replace formal. Preserve object presence, without carrying its payload.
            if !fields.contains(.metadata), !fields.contains(.metadataField(parts[2])) {
                metadata[parts[1]] = item
                continue
            }
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
            "generation": generation, "enabled": enabled]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
        return json
    }
}
