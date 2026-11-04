import Foundation
import SwiftData
import CoreData

extension UserDataStore {
    private func populatedReadingKeys() throws -> Set<String> {
        let metadata = "metadata/", chapter = "chapter/", position = "position/"
        let values = try modelContext.fetch(FetchDescriptor<UserValue>(predicate: #Predicate {
            $0.key.starts(with: metadata) || $0.key.starts(with: chapter) || $0.key.starts(with: position)
        }))
        // This is only a broad presence filter, never a second parser or LWW
        // decision. All selected candidates go through scopedValues unchanged.
        var result = Set(values.compactMap { row in row.key.split(separator: "/", maxSplits: 2).dropFirst().first.map(String.init) })
        result.formUnion(try modelContext.fetch(FetchDescriptor<UserPosition>()).map(\.contentKey))
        return result
    }
    private func scopedValues(_ contentKey: String) throws -> ValueSnapshot {
        var result = try valueSnapshot(key: "position/" + contentKey)
        for prefix in ["metadata/" + contentKey + "/", "chapter/" + contentKey + "/"] {
            let next = try valueSnapshot(prefix: prefix)
            try result.merge(next)
        }
        return result
    }
    func positionValues() throws -> [String: StoredValue] { try valueSnapshot(prefix: "position/").values }
    func projection(generation: UInt64, enabled: Bool, includeFacts: Bool, keys: [String]? = nil, positionsOnly: Bool = false, statisticsBook: String? = nil, diagnostic: ReaderOpenTrace? = nil, diagnosticScope: String = "projection", sparseCatalogue: Bool = false) throws -> String {
        diagnostic?.mark(diagnosticScope + ".actor.begin")
        defer { diagnostic?.mark(diagnosticScope + ".actor.return") }
        let cacheKey = "\(generation)-\(enabled)-\(includeFacts)-\(positionsOnly)-\(statisticsBook ?? "all")-\(sparseCatalogue)-" + (keys?.sorted().joined(separator: ",") ?? "all")
        if includeFacts { try requireStatisticsReadable(book: statisticsBook) }
        let version = projectionVersion
        if let cached = projectionCache[cacheKey], cached.0 == version { diagnostic?.mark(diagnosticScope + ".cacheHit"); return cached.1 }
        diagnostic?.mark(diagnosticScope + ".fetch.begin")
        let snapshot: ValueSnapshot
        if positionsOnly { snapshot = try valueSnapshot(prefix: "position/") }
        else if let keys {
            var scoped = ValueSnapshot()
            // Large catalogues are mostly unread files without user data. One
            // metadata-only presence pass avoids three empty fetches per file;
            // populated keys still use the sole scoped projection/check below.
            let present = sparseCatalogue ? try populatedReadingKeys() : nil
            for key in keys where present?.contains(key) ?? true {
                let next = try scopedValues(key)
                try scoped.merge(next)
            }
            snapshot = scoped
        } else { snapshot = try valueSnapshot() }
        let all = snapshot.values
        diagnostic?.mark(diagnosticScope + ".fetch.return")
        diagnostic?.mark(diagnosticScope + ".json.begin")
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
        let corrections = try all.filter { $0.key.hasPrefix("chapter/") && $0.value.value != "null" }.map { try JSONSerialization.jsonObject(with: Data($0.value.value.utf8)) }
        let result: [String: Any] = ["positions": positions, "metadata": Array(metadata.values), "corrections": corrections,
            "unsupportedPositions": snapshot.blocked.filter { $0.hasPrefix("position/") }.map { String($0.dropFirst(9)) },
            "facts": includeFacts ? try visibleFacts(key: statisticsBook) : [], "generation": generation, "enabled": enabled]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)
        diagnostic?.mark(diagnosticScope + ".json.return")
        if projectionCache.count > 32 { projectionCache.removeAll() }
        projectionCache[cacheKey] = (version, json)
        return json
    }
}
