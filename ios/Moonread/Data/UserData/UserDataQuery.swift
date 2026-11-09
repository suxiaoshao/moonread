import Foundation

extension AppDataService {
    /// Semantic inputs are resolved again after invalidation, never frozen as derived keys.
    enum UserQuerySource: Sendable {
        case fixed(keys: [String]?, statisticsBook: String?, statisticsKeys: [String]?)
        case book(String), file(String)
        case catalogue(LibraryLocation?, recursive: Bool)
        case recent(UInt32)
    }
    struct UserQueryOptions: Sendable {
        var facts = false
        var statisticsRange: ClosedRange<Int64>? = nil
        var positionsOnly = false
        var scope = "batch"
        var sparseCatalogue = false
        var fields: UserProjectionDomain = .reading
    }
    struct UserQuerySelection: Equatable, Sendable {
        var keys: [String]?
        var statisticsKeys: [String]?
    }
    struct UserQuerySignature: Equatable {
        let configuration: UUID
        let formalID: UUID?, pendingID: UUID?
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
        try await readingQuery(.book(id), options: .init(facts: facts, scope: "book-" + id,
            fields: [.position, .metadata, .chapter]), diagnostic: diagnostic ?? ReaderOpenDiagnostics.trace(book: id))
    }
    func effectiveQuery(facts: Bool = false, keys: [String]? = nil, positionsOnly: Bool = false,
        statisticsBook: String? = nil, statisticsKeys: [String]? = nil, scope: String = "batch",
        sparseCatalogue: Bool = false, fields: UserProjectionDomain = .reading, diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        try await readingQuery(.fixed(keys: keys, statisticsBook: statisticsBook, statisticsKeys: statisticsKeys),
            options: .init(facts: facts, positionsOnly: positionsOnly, scope: scope, sparseCatalogue: sparseCatalogue, fields: fields), diagnostic: diagnostic)
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
                    if let index = try await queryAttempt(.fixed(keys: nil, statisticsBook: nil, statisticsKeys: nil),
                        options: .init(positionsOnly: true, scope: "recent-index"), diagnostic: diagnostic) {
                        let keys = try index.query.recentLibraryEntries(limit: limit).compactMap(\.readingKey)
                        if let detail = try await queryAttempt(.fixed(keys: keys, statisticsBook: nil, statisticsKeys: nil),
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
                    return UserQueryOutput(query: read.query, statisticsIncomplete: read.statisticsIncomplete, statisticsVersion: read.signature.statisticsVersion)
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
    private func querySelection(_ source: UserQuerySource, facts: Bool) throws -> UserQuerySelection {
        let core = try textCore()
        func expand(_ keys: [String]?) throws -> [String]? {
            try keys.map { values in
                try Array(Set(values.flatMap { key in
                    try core.readingScopeKeys(key: parseReadingKey(value: key)).map { serializeReadingKey(key: $0) }
                })).sorted()
            }
        }
        switch source {
        case let .fixed(keys, book, statisticsKeys):
            let scope = try book.map { try core.readingScopeKeys(key: parseReadingKey(value: $0)).map { serializeReadingKey(key: $0) } }
            return try .init(keys: expand(keys ?? scope), statisticsKeys: expand(statisticsKeys ?? scope))
        case let .book(id):
            let keys = try core.readingScopeKeys(key: parseReadingKey(value: userKey(id))).map { serializeReadingKey(key: $0) }.sorted()
            return .init(keys: keys, statisticsKeys: facts ? keys : nil)
        case let .file(id):
            let identity = try core.fileIdentity(fileId: id)
            let keys = (identity.key.map { [$0] } ?? []) + (identity.pendingAlias.map { [$0] } ?? [])
            return .init(keys: keys.map { serializeReadingKey(key: $0) }.sorted())
        case let .catalogue(location, recursive):
            let keys = try core.catalogueContentKeys(scope: catalogueScope(location, recursive: recursive))
            return .init(keys: keys.map { serializeReadingKey(key: $0) }.sorted())
        case .recent: preconditionFailure("Recent queries prepare their index before details")
        }
    }
    private func querySignature(_ source: UserQuerySource, options: UserQueryOptions,
        formal: UserDataStore, pending: UserDataStore) throws -> UserQuerySignature {
        let selection = try querySelection(source, facts: options.facts), preferences = statisticsPreferences()
        let usesRecents = options.positionsOnly || !options.fields.intersection([.position, .opened]).isEmpty
        let allHidden = usesRecents ? Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []) : []
        let hidden = selection.keys.map { allHidden.intersection($0) } ?? allHidden
        let prefix = "Moonread.preferredFile."
        let preferred: [String: String]
        if !usesRecents { preferred = [:] }
        else if let keys = selection.keys {
            preferred = keys.reduce(into: [:]) { result, key in
                if let file = sourceDefaults.string(forKey: prefix + key) { result[key] = file }
            }
        } else {
            preferred = sourceDefaults.dictionaryRepresentation().reduce(into: [:]) { result, item in
                if item.key.hasPrefix(prefix), let file = item.value as? String { result[String(item.key.dropFirst(prefix.count))] = file }
            }
        }
        func version(_ store: UserDataStore) -> String {
            store.version(keys: selection.keys, positionsOnly: options.positionsOnly, includeFacts: options.facts,
                statisticsKeys: selection.statisticsKeys, fields: options.fields)
        }
        return .init(configuration: userCloudConfigurationRevision, formalID: userStoreTask?.id, pendingID: pendingUserStoreTask?.id,
            selection: selection, formalVersion: version(formal), pendingVersion: version(pending), generation: preferences.generation,
            enabled: preferences.enabled, statisticsVersion: options.facts ? "\(userCloudConfigurationRevision)-\(userStoreTask?.id.uuidString ?? "")-\(pendingUserStoreTask?.id.uuidString ?? "")-\(selection.statisticsKeys?.joined(separator: ",") ?? "all")-\(formal.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: selection.statisticsKeys, fields: []))-\(pending.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: selection.statisticsKeys, fields: []))-\(preferences.generation)-\(preferences.enabled)" : "", hidden: hidden, preferred: preferred)
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
        let keys = signature.selection.keys, factKeys = signature.selection.statisticsKeys
        // Import progress can update a readable prefix during this attempt. It
        // expires a cached query on the NEXT call, but is not a reason to starve
        // the current prefix. Identity/scope changes are validated separately.
        let progress = if case let .book(id) = source { "-\(readingChangeRevision(id))" } else { "" }
        let rangeKey = options.statisticsRange.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "full"
        let cacheKey = options.scope + progress + "-" + rangeKey + "-\(options.facts)-\(options.positionsOnly)-\(factKeys?.joined(separator: ",") ?? "all")-\(options.sparseCatalogue)-\(options.fields.rawValue)-" + (keys?.joined(separator: ",") ?? "all")
        if let cached = queryCache[cacheKey], cached.signature == signature {
            let read = UserQueryRead(source: source, options: options, formal: formal, pending: pending, signature: signature,
                cacheKey: cacheKey, query: cached.query, identities: cached.identities, statisticsIncomplete: cached.statisticsIncomplete)
            return read
        }
        let formalJSON = try await formal.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: options.facts,
            keys: keys, positionsOnly: options.positionsOnly, statisticsKeys: factKeys, fields: options.fields, diagnostic: diagnostic,
            diagnosticScope: "formalProjection", sparseCatalogue: options.sparseCatalogue, statisticsRange: options.statisticsRange)
        try Task.checkCancellation()
        let pendingJSON = try await pending.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: options.facts,
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
