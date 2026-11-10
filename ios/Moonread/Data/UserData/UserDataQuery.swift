import Foundation

extension AppDataService {
    enum RecordSelection: Equatable, Sendable {
        case all, only([ReadingKey])

        var storageKeys: [String]? {
            if case .only(let keys) = self { return keys.map { serializeReadingKey(key: $0) } }
            return nil
        }
    }

    enum FactsSelection: Equatable, Sendable {
        case none, all, only([ReadingKey])

        var included: Bool { self != .none }
        var storageKeys: [String]? {
            if case .only(let keys) = self { return keys.map { serializeReadingKey(key: $0) } }
            return nil
        }
    }

    /// Semantic inputs are resolved again after invalidation, never frozen as derived keys.
    enum UserQuerySource: Equatable, Sendable {
        case fixed(records: RecordSelection, facts: FactsSelection)
        case book(BookTarget, facts: Bool = false)
        case catalogue(CatalogueScope)
        case recent(UInt32)
    }
    struct UserQueryOptions: Sendable {
        var statisticsRange: ClosedRange<Int64>? = nil
        var positionsOnly = false
        var scope = "batch"
        var sparseCatalogue = false
        var fields: UserProjectionDomain = .reading
    }
    struct UserQuerySelection: Equatable, Sendable {
        let records: RecordSelection
        let facts: FactsSelection
        var resolution: BookResolution? = nil
    }
    struct UserQuerySignature: Equatable {
        let configuration: UUID
        let formalID: UUID?, pendingID: UUID?
        let source: UserQuerySource
        let selection: UserQuerySelection
        let formalVersion: String, pendingVersion: String
        let generation: UInt64, enabled: Bool
        let statisticsVersion: String
        let hidden: Set<String>, preferred: [String: String]
    }
    struct UserQueryOutput: Sendable {
        let query: ReaderQuery
        let statisticsIncomplete: Bool
        let statisticsVersion: String
        let resolution: BookResolution?
        var compatibilityNotice: String? {
            statisticsIncomplete ? String(localized: "统计不完整：部分记录当前版本无法理解，请更新 App。") : nil
        }
    }
    private struct UserQueryRead {
        let source: UserQuerySource
        let options: UserQueryOptions
        let formal: UserDataStore, pending: UserDataStore
        let signature: UserQuerySignature
        let cacheKey: String
        let query: ReaderQuery
        let identities: [String: String]
        let statisticsIncomplete: Bool
    }
    #if DEBUG
    // Deterministic gates at real query boundaries; no production timing or data changes.
    enum UserQueryTestPhase: Sendable, Equatable { case built, retry }
    #endif

    func bookQuery(_ id: String, facts: Bool = false, diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        try await readingQuery(.book(.cached(bookId: id), facts: facts), options: .init(scope: "book-" + id,
            fields: [.position, .metadata, .chapter]), diagnostic: diagnostic ?? ReaderOpenDiagnostics.trace(book: id))
    }
    func effectiveQuery(records: RecordSelection = .all, facts: FactsSelection = .none,
        positionsOnly: Bool = false, scope: String = "batch", sparseCatalogue: Bool = false,
        fields: UserProjectionDomain = .reading, diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        try await readingQuery(.fixed(records: records, facts: facts),
            options: .init(positionsOnly: positionsOnly, scope: scope, sparseCatalogue: sparseCatalogue, fields: fields), diagnostic: diagnostic)
    }
    func readingQuery(_ source: UserQuerySource, options: UserQueryOptions, diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        try await readingQueryResult(source, options: options, diagnostic: diagnostic).query
    }
    func readingQueryResult(_ source: UserQuerySource, options: UserQueryOptions, diagnostic: ReaderOpenTrace? = nil) async throws -> UserQueryOutput {
        do {
            var discarded = 0
            while true {
                try Task.checkCancellation()
                let reads: [UserQueryRead]?
                if case let .recent(limit) = source {
                    // The detail scope depends on the index. Validate BOTH after the
                    // detail build, otherwise a new recent book can disappear from this result.
                    if let index = try await queryAttempt(.fixed(records: .all, facts: .none),
                        options: .init(positionsOnly: true, scope: "recent-index"), diagnostic: diagnostic) {
                        let keys = try index.query.recentLibraryEntries(limit: limit).compactMap(\.readingIdentity)
                        if let detail = try await queryAttempt(.fixed(records: .only(keys), facts: .none),
                            options: options, diagnostic: diagnostic) { reads = [index, detail] }
                        else { reads = nil }
                    } else { reads = nil }
                } else if let read = try await queryAttempt(source, options: options, diagnostic: diagnostic) { reads = [read] }
                else { reads = nil }
                try Task.checkCancellation()
                if let reads, try reads.allSatisfy({ try queryReadIsValid($0) }) {
                    if queryCache.count >= 32 { queryCache.removeAll() }
                    for read in reads {
                        queryCache[read.cacheKey] = CachedQuery(signature: read.signature, identities: read.identities, query: read.query, statisticsIncomplete: read.statisticsIncomplete)
                    }
                    let read = reads.last!
                    return UserQueryOutput(query: read.query, statisticsIncomplete: read.statisticsIncomplete, statisticsVersion: read.signature.statisticsVersion, resolution: read.signature.selection.resolution)
                }
                discarded += 1
                #if DEBUG
                try await queryTestBoundary?(options.scope, .retry)
                #endif
                try Task.checkCancellation()
                if discarded > 1 { try await Task.sleep(for: .milliseconds(100)) }
            }
        } catch {
            try Task.checkCancellation()
            // A dependency ending on its own is a failed read, not a cancelled caller.
            if error is CancellationError { throw CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: error]) }
            throw error
        }
    }
    private func querySelection(_ source: UserQuerySource) throws -> UserQuerySelection {
        let core = try textCore()
        func sorted(_ keys: [ReadingKey]) -> [ReadingKey] {
            Set(keys).sorted { serializeReadingKey(key: $0) < serializeReadingKey(key: $1) }
        }
        func expand(_ keys: [ReadingKey]) throws -> [ReadingKey] {
            try sorted(keys.flatMap { try core.readingScopeKeys(key: $0) })
        }
        switch source {
        case let .fixed(records, facts):
            let records: RecordSelection = switch records {
            case .all: .all
            case .only(let keys): .only(try expand(keys))
            }
            let facts: FactsSelection = switch facts {
            case .none: .none
            case .all: .all
            case .only(let keys): .only(try expand(keys))
            }
            return .init(records: records, facts: facts)
        case let .book(target, facts):
            let resolution = try core.resolveBookTarget(target: target)
            let keys: [ReadingKey]
            switch resolution {
            case .resolved(let record): keys = sorted([record.key] + record.aliases)
            case .unidentified, .missing: keys = []
            }
            return .init(records: .only(keys), facts: facts ? .only(keys) : .none, resolution: resolution)
        case let .catalogue(scope):
            return .init(records: .only(try sorted(core.catalogueContentKeys(scope: scope))), facts: .none)
        case .recent: preconditionFailure("Recent queries prepare their index before details")
        }
    }
    private func querySignature(_ source: UserQuerySource, options: UserQueryOptions,
        formal: UserDataStore, pending: UserDataStore) throws -> UserQuerySignature {
        let selection = try querySelection(source), preferences = statisticsPreferences()
        let recordKeys = selection.records.storageKeys, factKeys = selection.facts.storageKeys
        let usesRecents = options.positionsOnly || !options.fields.intersection([.position, .opened]).isEmpty
        let allHidden = usesRecents ? Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []) : []
        let hidden = recordKeys.map { allHidden.intersection($0) } ?? allHidden
        let prefix = "Moonread.preferredFile."
        let preferred: [String: String]
        if !usesRecents { preferred = [:] }
        else if let keys = recordKeys {
            preferred = keys.reduce(into: [:]) { result, key in
                if let file = sourceDefaults.string(forKey: prefix + key) { result[key] = file }
            }
        } else {
            preferred = sourceDefaults.dictionaryRepresentation().reduce(into: [:]) { result, item in
                if item.key.hasPrefix(prefix), let file = item.value as? String { result[String(item.key.dropFirst(prefix.count))] = file }
            }
        }
        func version(_ store: UserDataStore) -> String {
            store.version(keys: recordKeys, positionsOnly: options.positionsOnly, includeFacts: selection.facts.included,
                statisticsKeys: factKeys, fields: options.fields)
        }
        return .init(configuration: userCloudConfigurationRevision, formalID: userStoreTask?.id, pendingID: pendingUserStoreTask?.id,
            source: source, selection: selection, formalVersion: version(formal), pendingVersion: version(pending), generation: preferences.generation,
            enabled: preferences.enabled, statisticsVersion: selection.facts.included ? "\(userCloudConfigurationRevision)-\(userStoreTask?.id.uuidString ?? "")-\(pendingUserStoreTask?.id.uuidString ?? "")-\(factKeys?.joined(separator: ",") ?? "all")-\(formal.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: factKeys, fields: []))-\(pending.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: factKeys, fields: []))-\(preferences.generation)-\(preferences.enabled)" : "", hidden: hidden, preferred: preferred)
    }
    private func queryReadIsValid(_ read: UserQueryRead) throws -> Bool {
        guard read.signature.configuration == userCloudConfigurationRevision,
              read.signature.formalID == userStoreTask?.id, read.signature.pendingID == pendingUserStoreTask?.id else { return false }
        guard try querySignature(read.source, options: read.options, formal: read.formal, pending: read.pending) == read.signature else { return false }
        return try queryIdentities(read.identities.keys.map { $0 }) == read.identities
    }
    private func queryIdentities(_ keys: [String]) throws -> [String: String] {
        let resolutions = try textCore().resolveReadingKeys(keys: keys.map { try parseReadingKey(value: $0) })
        return Dictionary(uniqueKeysWithValues: resolutions.map { (serializeReadingKey(key: $0.original), serializeReadingKey(key: $0.effective)) })
    }
    private func queryAttempt(_ source: UserQuerySource, options: UserQueryOptions, diagnostic: ReaderOpenTrace?) async throws -> UserQueryRead? {
        try Task.checkCancellation()
        let configuration = userCloudConfigurationRevision
        let formal: UserDataStore, pending: UserDataStore
        do {
            formal = try await userStore(diagnostic: diagnostic)
            try Task.checkCancellation()
            guard configuration == userCloudConfigurationRevision else { return nil }
            let formalID = userStoreTask?.id
            pending = try await userStore(pending: true, diagnostic: diagnostic)
            try Task.checkCancellation()
            guard configuration == userCloudConfigurationRevision, formalID == userStoreTask?.id else { return nil }
        } catch {
            try Task.checkCancellation()
            if configuration != userCloudConfigurationRevision { return nil }
            throw error
        }
        let signature = try querySignature(source, options: options, formal: formal, pending: pending)
        let selection = signature.selection
        let keys = selection.records.storageKeys, factKeys = selection.facts.storageKeys
        // Import progress can update a readable prefix during this attempt. It
        // expires a cached query on the NEXT call, but is not a reason to starve
        // the current prefix. Identity/scope changes are validated separately.
        let progress = if case let .book(.cached(id), _) = source { "-\(readingChangeRevision(id))" } else { "" }
        let rangeKey = options.statisticsRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "full"
        let cacheKey = options.scope + progress + "-" + rangeKey + "-\(selection.facts.included)-\(options.positionsOnly)-\(factKeys?.joined(separator: ",") ?? "all")-\(options.sparseCatalogue)-\(options.fields.rawValue)-" + (keys?.joined(separator: ",") ?? "all")
        if let cached = queryCache[cacheKey], cached.signature == signature {
            let read = UserQueryRead(source: source, options: options, formal: formal, pending: pending, signature: signature,
                cacheKey: cacheKey, query: cached.query, identities: cached.identities, statisticsIncomplete: cached.statisticsIncomplete)
            return read
        }
        let formalJSON = try await formal.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: selection.facts.included,
            keys: keys, positionsOnly: options.positionsOnly, statisticsKeys: factKeys, fields: options.fields, diagnostic: diagnostic,
            diagnosticScope: "formalProjection", sparseCatalogue: options.sparseCatalogue, statisticsRange: options.statisticsRange)
        try Task.checkCancellation()
        let pendingJSON = try await pending.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: selection.facts.included,
            keys: keys, positionsOnly: options.positionsOnly, statisticsKeys: factKeys, fields: options.fields, diagnostic: diagnostic,
            diagnosticScope: "pendingProjection", sparseCatalogue: options.sparseCatalogue, statisticsRange: options.statisticsRange)
        try Task.checkCancellation()
        let core = try textCore(), hidden = signature.hidden, preferred = signature.preferred
        let build = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            var combined = try JSONSerialization.jsonObject(with: Data(formalJSON.utf8)) as! [String: Any]
            let extra = try JSONSerialization.jsonObject(with: Data(pendingJSON.utf8)) as! [String: Any]
            for field in ["positions", "opened", "facts", "metadata", "corrections"] { combined[field] = (combined[field] as! [Any]) + (extra[field] as! [Any]) }
            let incomplete = (combined["statisticsIncomplete"] as? Bool ?? false) || (extra["statisticsIncomplete"] as? Bool ?? false)
            combined.removeValue(forKey: "statisticsIncomplete")
            let rawPositions = combined["positions"] as! [[String: Any]]
            var blockedPositions = Set((combined["unsupportedPositions"] as? [String] ?? []) + (extra["unsupportedPositions"] as? [String] ?? []))
            let rawOpened = combined["opened"] as! [[String: Any]]
            let rawKeys = Set(rawPositions.compactMap { $0["content_key"] as? String }).union(rawOpened.compactMap { $0["content_key"] as? String }).union(hidden).union(blockedPositions)
            let resolutions = try core.resolveReadingKeys(keys: rawKeys.compactMap { try? parseReadingKey(value: $0) })
            let mapping = Dictionary(uniqueKeysWithValues: resolutions.map { (serializeReadingKey(key: $0.original), serializeReadingKey(key: $0.effective)) })
            let effectiveHidden = hidden.union(hidden.compactMap { mapping[$0] })
            blockedPositions.formUnion(blockedPositions.compactMap { mapping[$0] })
            combined.removeValue(forKey: "unsupportedPositions")
            let candidates = try rawPositions.compactMap { input -> PositionCandidate? in
                let candidate = try PositionCandidate(projection: input)
                guard let key = mapping[candidate.value.content_key], !blockedPositions.contains(key) else { return nil }
                return try candidate.rekeyed(to: key)
            }
            var opened = UserDataStore.ValueSnapshot()
            var openedSources: [String: [String: String]] = [:]
            for row in rawOpened {
                guard let source = row["content_key"] as? String, let key = mapping[source],
                      !effectiveHidden.contains(key), let at = row["opened_ms"] as? NSNumber,
                      let updated = row["updated"] as? NSNumber, let token = row["token"] as? String else { continue }
                // Use the existing value LWW owner even while formal/pending coexist.
                try opened.select(key: key, value: StoredValue(updated: updated.int64Value, token: token, value: at.stringValue))
                openedSources[key, default: [:]][token] = source
            }
            combined["opened"] = opened.values.map { key, stored -> [String: Any] in
                let source = openedSources[key]?[stored.token] ?? key
                return ["content_key": key, "updated": Int64(stored.value) ?? 0,
                        "preferred": preferred[key] ?? preferred[source] ?? NSNull() as Any]
            }
            let positions = PositionCandidate.reduce(candidates)
            combined["positions"] = try positions.keys.sorted().map { key -> [String: Any] in
                let candidate = positions[key]!
                var item = try candidate.projection()
                item["visible"] = !effectiveHidden.contains(key)
                item["preferred"] = preferred[key] ?? preferred[candidate.sourceKey] ?? NSNull() as Any
                return item
            }
            try Task.checkCancellation()
            let query = try core.querySnapshot(json: String(decoding: JSONSerialization.data(withJSONObject: combined), as: UTF8.self))
            try Task.checkCancellation()
            return (query, mapping, incomplete)

        }
        let (query, identities, incomplete) = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
        #if DEBUG
        try await queryTestBoundary?(options.scope, .built)
        #endif
        try Task.checkCancellation()
        return UserQueryRead(source: source, options: options, formal: formal, pending: pending, signature: signature,
            cacheKey: cacheKey, query: query, identities: identities, statisticsIncomplete: incomplete)
    }
}
