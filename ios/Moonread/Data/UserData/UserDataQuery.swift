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
        case catalogueRecord(String)
        case directoryActivity(CatalogueScope)
        case directoryDetails(direct: [ReadingKey], covers: [ReadingKey])
        case metadataExchange([ReadingKey])

        var isDirectoryActivity: Bool {
            if case .directoryActivity = self { return true }
            return false
        }
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
        var coverOnly: Set<String> = []
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
        let directoryActivity: ReaderQuery?
        let formalBlockedMetadata: Set<String>
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
        try await withValidQueryInputs(scope: options.scope) {
            guard let read = try await queryAttempt(source, options: options, diagnostic: diagnostic) else { return nil }
            return ([read], UserQueryOutput(query: read.query, statisticsIncomplete: read.statisticsIncomplete,
                statisticsVersion: read.signature.statisticsVersion, resolution: read.signature.selection.resolution))
        }
    }

    func recentLibraryEntries(_ limit: UInt32, cold: Bool) async throws -> [LibraryEntry] {
        try await withValidQueryInputs(scope: cold ? "home-cold" : "recent") {
            guard let index = try await queryAttempt(.fixed(records: .all, facts: .none),
                options: .init(positionsOnly: true, scope: "recent-index"), diagnostic: nil) else { return nil }
            let ranking = try index.query.recentLibraryRanking(limit: limit)
            let keys = try ranking.readingKeys()
            guard let detail = try await queryAttempt(.fixed(records: .only(keys), facts: .none),
                options: .init(scope: "recent", fields: [.card, .chapter]), diagnostic: nil) else { return nil }
            // Hydration cannot reselect a copy. Recheck the live index too:
            // unchanged user inputs can still admit a new source into the rank.
            guard let entries = try detail.query.hydrateRecentLibraryCards(ranking: ranking),
                  try index.query.recentLibraryRankingMatches(ranking: ranking) else { return nil }
            return ([index, detail], entries)
        }
    }

    func bookInformation(_ target: BookTarget, fileID: String?, includeRecordSource: Bool) async throws
        -> (LibraryEntry?, BookDetailsResult) {
        let (entry, details, blocked, missingSource): (LibraryEntry?, BookDetailsResult, Bool, Bool) =
            try await withValidQueryInputs(scope: "book-information") {
                guard let detail = try await queryAttempt(.book(target),
                    options: .init(scope: "book-information", fields: [.position, .metadata, .chapter]),
                    diagnostic: nil) else { return nil }
                let details = try detail.query.bookDetails(target: target)
                if case .missing = details { return ([detail], (nil, details, false, false)) }
                if case .identified(_, let value) = details, detail.formalBlockedMetadata.contains(value.metadata.sha) {
                    return ([detail], (nil, details, true, false))
                }

                let sourceTarget: BookTarget
                let source: UserQuerySource
                if let fileID {
                    sourceTarget = .file(fileId: fileID)
                    source = .book(sourceTarget)
                } else if includeRecordSource,
                          case .identified(let identity, _) = details,
                          case .associated = identity.body,
                          case .formal(let sha) = identity.key {
                    sourceTarget = .record(key: identity.key)
                    source = .catalogueRecord(sha)
                } else {
                    return ([detail], (nil, details, false, false))
                }
                let sourceRead: UserQueryRead
                if sourceTarget == target, case .file = target {
                    sourceRead = detail
                } else {
                    guard let scoped = try await queryAttempt(source,
                        options: .init(scope: "book-information-source", fields: .position), diagnostic: nil)
                    else { return nil }
                    sourceRead = scoped
                }
                let entry = try sourceRead.query.bookInformationSource(target: sourceTarget)
                let missingSource = fileID != nil && entry == nil
                return (sourceRead.query === detail.query ? [detail] : [detail, sourceRead],
                        (entry, details, false, missingSource))
            }
        if blocked { throw UserSyncCompatibilityError() }
        if missingSource { throw ReaderError.NotFound }
        return (entry, details)
    }

    func directoryEntries(_ location: LibraryLocation, sort: LibrarySort) async throws -> [LibraryEntry] {
        try await withValidQueryInputs(scope: "directory") {
            let source = UserQuerySource.directoryActivity(catalogueScope(location, recursive: true))
            guard let index = try await queryAttempt(source,
                options: .init(scope: "directory-activity", fields: [.position, .opened]), diagnostic: nil) else { return nil }
            let keys = try index.query.libraryDirectoryDetailKeys(shelfId: location.shelfID, parentPath: location.path)
            let direct = Set(keys.direct)
            let covers = Set(keys.covers)
            func includingAliases(_ keys: Set<ReadingKey>) throws -> [ReadingKey] {
                let selected = Set(keys.map(\.storageKey))
                let aliases = try index.identities.compactMap { raw, effective in
                    raw != effective && selected.contains(effective) ? try parseReadingKey(value: raw) : nil
                }
                return (Array(keys) + aliases).sorted { $0.storageKey < $1.storageKey }
            }
            guard let detail = try await queryAttempt(.directoryDetails(direct: includingAliases(direct), covers: includingAliases(covers)),
                options: .init(scope: "directory-details", fields: [.position, .chapter, .card]), diagnostic: nil,
                directoryActivity: index.query) else { return nil }
            let entries = try detail.query.libraryDirectoryCards(shelfId: location.shelfID, parentPath: location.path, sort: sort)
            let loaded = direct.union(covers)
            guard entries.allSatisfy({ entry in
                (entry.readingIdentity.map(direct.contains) ?? true)
                    && (entry.folderRow?.coverPreviews.allSatisfy { preview in
                        preview.readingKey.map(loaded.contains) ?? true
                    } ?? true)
            }) else {
                // Evict a cached activity snapshot if a changed alias caused
                // the mismatch, so the next attempt can choose a new scope.
                _ = try validateQueryInputs([index, detail])
                return nil
            }
            return ([index, detail], entries)
        }
    }

    func libraryCatalogueSearch(_ scope: CatalogueScope, spec: LibraryQueryRules.SearchSpec) async throws -> LibraryQueryRules.SearchOutcome {
        try await withValidQueryInputs(scope: "library-search") {
            guard let match = try await queryAttempt(.catalogue(scope),
                options: .init(scope: "library-search-match", fields: LibraryQueryRules.matchDomains(spec)),
                diagnostic: nil) else { return nil }
            let candidates = try match.query.librarySearchMatches(scope: scope, booksOnly: spec.configuration.booksOnly)
            var found = LibraryQueryRules.searchOutcome(candidates, spec: spec)
            guard !found.entries.isEmpty else { return ([match], found) }
            let ids = found.entries.map(\.id)
            let keys = try match.query.librarySearchDetailKeys(fileIds: ids)
            let direct = Set(keys.direct), covers = Set(keys.covers)
            // Search previously used the whole recursive catalogue. Include
            // its actual participating aliases, including metadata/chapter-only
            // records, rather than expanding all historical aliases.
            let aliasKeys = (match.signature.selection.records.storageKeys ?? []).filter { $0.hasPrefix("pending:") }
            let aliases = try queryIdentities(aliasKeys)
            func scoped(_ keys: Set<ReadingKey>) throws -> [ReadingKey] {
                let effective = Set(keys.map(\.storageKey))
                return try (Array(keys) + aliases.compactMap { raw, resolved in
                    raw != resolved && effective.contains(resolved) ? try parseReadingKey(value: raw) : nil
                }).sorted { $0.storageKey < $1.storageKey }
            }
            guard let detail = try await queryAttempt(.directoryDetails(direct: scoped(direct), covers: scoped(covers)),
                options: .init(scope: "library-search-cards", fields: [.position, .chapter, .card]),
                diagnostic: nil, directoryActivity: match.query) else { return nil }
            let cards = try detail.query.librarySearchCards(fileIds: ids)
            let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            let loaded = direct.union(covers)
            var ordered: [LibraryEntry] = []
            for hit in found.entries {
                guard let card = byID[hit.id], hit.directory == card.directory,
                      hit.readingIdentity == card.readingIdentity, hit.relativePath == card.relativePath,
                      hit.name.utf8.elementsEqual(card.name.utf8), hit.shelfId == card.shelfId,
                      (card.readingIdentity.map(direct.contains) ?? true),
                      (card.folderRow?.coverPreviews.allSatisfy { $0.readingKey.map(loaded.contains) ?? true } ?? true)
                else { return nil }
                ordered.append(card)
            }
            guard try queryIdentities(aliasKeys) == aliases else { return nil }
            found.entries = ordered
            return ([match, detail], found)
        }
    }

    struct MetadataExchangeInputs: Sendable {
        let read: MetadataExchangeRead
        let formalBlockedMetadata: Set<String>
    }

    func metadataExchangeInputs(_ request: MetadataExchangeRequest, configuration: UUID) async throws -> MetadataExchangeInputs {
        try await withValidQueryInputs(scope: "metadata-exchange") {
            guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            let core = try textCore()
            let inventory = try core.metadataExchangeInventory(request: request)
            let source = UserQuerySource.metadataExchange(inventory.recordKeys())
            guard let read = try await queryAttempt(source, options: .init(scope: "metadata-exchange",
                fields: [.position, .metadata]), diagnostic: nil) else { return nil }
            guard configuration == userCloudConfigurationRevision else { throw ReadingDataError.changed }
            // On the same Rust read transaction, compare the live source rows
            // and counts before producing results. Retry reads only.
            guard let result = try read.query.metadataExchangeRead(request: request, inventory: inventory) else { return nil }
            return ([read], .init(read: result, formalBlockedMetadata: read.formalBlockedMetadata))
        }
    }

    private func withValidQueryInputs<Output>(scope: String,
        attempt: () async throws -> ([UserQueryRead], Output)?) async throws -> Output {
        do {
            var discarded = 0
            while true {
                try Task.checkCancellation()
                let result = try await attempt()
                try Task.checkCancellation()
                if let (reads, output) = result, try validateQueryInputs(reads) {
                    if queryCache.count >= 32 { queryCache.removeAll() }
                    for read in reads {
                        queryCache[read.cacheKey] = CachedQuery(signature: read.signature, identities: read.identities,
                            query: read.query, statisticsIncomplete: read.statisticsIncomplete, directoryActivity: read.directoryActivity,
                            formalBlockedMetadata: read.formalBlockedMetadata)
                    }
                    return output
                }
                discarded += 1
                #if DEBUG
                try await queryTestBoundary?(scope, .retry)
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
        case let .catalogue(scope), let .directoryActivity(scope):
            return .init(records: .only(try sorted(core.catalogueContentKeys(scope: scope))), facts: .none)
        case let .catalogueRecord(sha):
            return .init(records: .only(try sorted(core.catalogueRecordKeys(sha: sha))), facts: .none)
        case let .directoryDetails(direct, covers):
            return .init(records: .only(sorted(direct + covers)), facts: .none,
                         coverOnly: Set(covers.map(\.storageKey)).subtracting(direct.map(\.storageKey)))
        case let .metadataExchange(keys):
            // Inventory already selected the catalogue's participating aliases.
            return .init(records: .only(sorted(keys)), facts: .none)
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
        if !usesRecents || source.isDirectoryActivity { preferred = [:] }
        else if let keys = recordKeys {
            preferred = keys.reduce(into: [:]) { result, key in
                if let file = sourceDefaults.string(forKey: prefix + key) { result[key] = file }
            }
        } else {
            preferred = sourceDefaults.dictionaryRepresentation().reduce(into: [:]) { result, item in
                if item.key.hasPrefix(prefix), let file = item.value as? String { result[String(item.key.dropFirst(prefix.count))] = file }
            }
        }
        func version(_ store: UserDataStore, pending: Bool) -> String {
            store.version(keys: recordKeys, positionsOnly: options.positionsOnly, includeFacts: selection.facts.included,
                statisticsKeys: factKeys, fields: options.fields,
                          filter: .init(coverOnly: selection.coverOnly, openedAliasesOnly: source.isDirectoryActivity,
                                        preserveMetadataWinner: pending))
        }
        return .init(configuration: userCloudConfigurationRevision, formalID: userStoreTask?.id, pendingID: pendingUserStoreTask?.id,
            source: source, selection: selection, formalVersion: version(formal, pending: false), pendingVersion: version(pending, pending: true), generation: preferences.generation,
            enabled: preferences.enabled, statisticsVersion: selection.facts.included ? "\(userCloudConfigurationRevision)-\(userStoreTask?.id.uuidString ?? "")-\(pendingUserStoreTask?.id.uuidString ?? "")-\(factKeys?.joined(separator: ",") ?? "all")-\(formal.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: factKeys, fields: []))-\(pending.version(keys: [], positionsOnly: false, includeFacts: true, statisticsKeys: factKeys, fields: []))-\(preferences.generation)-\(preferences.enabled)" : "", hidden: hidden, preferred: preferred)
    }
    private func queryReadIsValid(_ read: UserQueryRead) throws -> Bool {
        guard read.signature.configuration == userCloudConfigurationRevision,
              read.signature.formalID == userStoreTask?.id, read.signature.pendingID == pendingUserStoreTask?.id else { return false }
        guard try querySignature(read.source, options: read.options, formal: read.formal, pending: read.pending) == read.signature else { return false }
        return try queryIdentities(read.identities.keys.map { $0 }) == read.identities
    }
    private func validateQueryInputs(_ reads: [UserQueryRead]) throws -> Bool {
        var valid = true
        for read in reads where try !queryReadIsValid(read) {
            // An alias can change without a version change in either store.
            // Drop that cached snapshot so a retry doesn't read it again.
            if queryCache[read.cacheKey]?.query === read.query { queryCache[read.cacheKey] = nil }
            valid = false
        }
        return valid
    }
    private func queryIdentities(_ keys: [String]) throws -> [String: String] {
        let resolutions = try textCore().resolveReadingKeys(keys: keys.map { try parseReadingKey(value: $0) })
        return Dictionary(uniqueKeysWithValues: resolutions.map { (serializeReadingKey(key: $0.original), serializeReadingKey(key: $0.effective)) })
    }
    private func queryAttempt(_ source: UserQuerySource, options: UserQueryOptions, diagnostic: ReaderOpenTrace?,
        directoryActivity: ReaderQuery? = nil) async throws -> UserQueryRead? {
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
        if let cached = queryCache[cacheKey], cached.signature == signature,
           cached.directoryActivity === directoryActivity {
            let read = UserQueryRead(source: source, options: options, formal: formal, pending: pending, signature: signature,
                cacheKey: cacheKey, query: cached.query, identities: cached.identities,
                statisticsIncomplete: cached.statisticsIncomplete, directoryActivity: directoryActivity,
                formalBlockedMetadata: cached.formalBlockedMetadata)
            return read
        }
        guard let formalProjection = try await formal.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: selection.facts.included,
            keys: keys, positionsOnly: options.positionsOnly, statisticsKeys: factKeys, fields: options.fields, diagnostic: diagnostic,
            diagnosticScope: "formalProjection", sparseCatalogue: options.sparseCatalogue, statisticsRange: options.statisticsRange,
            filter: .init(coverOnly: selection.coverOnly, openedAliasesOnly: source.isDirectoryActivity)) else { return nil }
        try Task.checkCancellation()
        guard let pendingProjection = try await pending.projection(generation: signature.generation, enabled: signature.enabled, includeFacts: selection.facts.included,
            keys: keys, positionsOnly: options.positionsOnly, statisticsKeys: factKeys, fields: options.fields, diagnostic: diagnostic,
            diagnosticScope: "pendingProjection", sparseCatalogue: options.sparseCatalogue, statisticsRange: options.statisticsRange,
            filter: .init(coverOnly: selection.coverOnly, openedAliasesOnly: source.isDirectoryActivity, preserveMetadataWinner: true)) else { return nil }
        try Task.checkCancellation()
        guard configuration == userCloudConfigurationRevision,
              signature.formalID == userStoreTask?.id, signature.pendingID == pendingUserStoreTask?.id else { return nil }
        let core = try textCore(), hidden = signature.hidden, preferred = signature.preferred
        let activityOnly = source.isDirectoryActivity
        let includeFacts = selection.facts.included
        let geometry: FactGeometry = options.statisticsRange == nil ? .full : .firstExposure
        let build = Task.detached(priority: Task.currentPriority) {
            try Task.checkCancellation()
            var combined = try JSONSerialization.jsonObject(with: Data(formalProjection.json.utf8)) as! [String: Any]
            let extra = try JSONSerialization.jsonObject(with: Data(pendingProjection.json.utf8)) as! [String: Any]
            for field in ["positions", "opened", "metadata", "corrections"] { combined[field] = (combined[field] as! [Any]) + (extra[field] as! [Any]) }
            let incomplete = formalProjection.statisticsIncomplete || pendingProjection.statisticsIncomplete
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
            // Directory activity only used opened to find participating aliases.
            // No directory sort or cover rule uses opened timestamps.
            for row in activityOnly ? [] : rawOpened {
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
                if activityOnly { return ["content_key": key, "updated": candidate.stored.updated, "offset": 0, "visible": true] }
                var item = try candidate.projection()
                item["visible"] = !effectiveHidden.contains(key)
                item["preferred"] = preferred[key] ?? preferred[candidate.sourceKey] ?? NSNull() as Any
                return item
            }
            try Task.checkCancellation()
            let json = String(decoding: try JSONSerialization.data(withJSONObject: combined), as: UTF8.self)
            let query = if let directoryActivity { try core.querySnapshotWithDirectoryActivity(json: json, activity: directoryActivity) }
                else if includeFacts {
                    try core.querySnapshotWithFacts(nonFactJson: json, formal: formalProjection.facts, pending: pendingProjection.facts, geometry: geometry)
                } else { try core.querySnapshot(json: json) }
            try Task.checkCancellation()
            return (query, mapping, incomplete)

        }
        let (query, identities, incomplete) = try await withTaskCancellationHandler { try await build.value } onCancel: { build.cancel() }
        #if DEBUG
        try await queryTestBoundary?(options.scope, .built)
        #endif
        try Task.checkCancellation()
        return UserQueryRead(source: source, options: options, formal: formal, pending: pending, signature: signature,
            cacheKey: cacheKey, query: query, identities: identities, statisticsIncomplete: incomplete,
            directoryActivity: directoryActivity, formalBlockedMetadata: formalProjection.input.blockedMetadata)
    }
}
