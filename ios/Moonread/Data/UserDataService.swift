import Foundation
import SwiftData
import CryptoKit

extension ReaderService {
    func userStore(pending: Bool = false, diagnostic: ReaderOpenTrace? = nil) async throws -> UserDataStore {
        let label = pending ? "pendingStore" : "formalStore"
        diagnostic?.mark(label + ".service.begin")
        defer { diagnostic?.mark(label + ".service.return") }
        let initialization: UserStoreInitialization
        if let cached = pending ? pendingUserStoreTask : userStoreTask { initialization = cached }
        else {
            let name = userDirectoryName, factory = userStoreFactory
            let cloud = !pending && userCloudEnabled
            let filename = pending ? "pending-users.store" : "user-data.store"
            let task = Task.detached {
                diagnostic?.mark(label + ".initialize.begin")
                defer { diagnostic?.mark(label + ".initialize.return") }
                if let factory { return try await factory(filename, cloud) }
                let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let configuration = ModelConfiguration("UserData", schema: UserDataStore.schema,
                    url: directory.appendingPathComponent(filename), cloudKitDatabase: cloud ? .private(CloudConfiguration.containerID) : .none)
                let container = try ModelContainer(for: UserDataStore.schema, configurations: [configuration])
                return UserDataStore(modelContainer: container)
            }
            initialization = UserStoreInitialization(task: task)
            if pending { pendingUserStoreTask = initialization } else { userStoreTask = initialization }
        }
        do {
            diagnostic?.mark(label + ".initialize.queued")
            let value = try await initialization.task.value
            diagnostic?.mark(label + ".initialize.resumed")
            return value
        }
        catch {
            // An old waiter may resume after configuration has replaced its task.
            if pending, pendingUserStoreTask?.id == initialization.id { pendingUserStoreTask = nil }
            if !pending, userStoreTask?.id == initialization.id { userStoreTask = nil }
            throw error
        }
    }
    func userStore(for key: String) async throws -> UserDataStore {
        switch try parseReadingKey(value: key) {
        case .pending: try await userStore(pending: true)
        case .formal: try await userStore()
        }
    }
    func markStore(_ id: String) async throws -> UserDataStore {
        let formal = try await userStore()
        do { _ = try await formal.markCandidates(id); return formal }
        catch ReaderError.NotFound { }
        let pending = try await userStore(pending: true)
        do { _ = try await pending.markCandidates(id); return pending }
        catch ReaderError.NotFound { }
        throw ReaderError.NotFound
    }
    func configureUserCloud(_ enabled: Bool, account: String?, allowAccountChange: Bool = false) async throws {
        await acquireUserDataOperation()
        var holdsOperation = true
        defer { if holdsOperation { releaseUserDataOperation() } }
        if enabled {
            guard let account else { throw CocoaError(.userCancelled) }
            if let previous = sourceDefaults.string(forKey: "Moonread.userOwner"), previous != account, !allowAccountChange { throw ReaderError.CloudAccountChanged }
            // The verified user consent remains valid even if initialization fails.
            if sourceDefaults.string(forKey: "Moonread.userOwner") == nil { try? adoptLocalShelfBindings(account: account) }
            sourceDefaults.set(account, forKey: "Moonread.userOwner")
        }
        if userCloudEnabled != enabled {
            cancelRecentRestoration()
            userStoreTask = nil; userCloudEnabled = enabled
            userCloudConfigurationRevision = UUID()
            let revision = userCloudConfigurationRevision
            // The configuration switch is serialized with deletion, not store
            // bootstrap: a newer configuration must be able to replace a stuck
            // initialization (the existing revision guard rejects its late result).
            releaseUserDataOperation(); holdsOperation = false
            do { _ = try await userStore() }
            catch {
                if userCloudConfigurationRevision == revision { userCloudEnabled = false }
                throw error
            }
            guard userCloudConfigurationRevision == revision else { return }
            scheduleRecentRestoration()
        }
    }
    func startUserRecovery() {
        guard !recoveredImports, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in await self?.recoverUserImports() }
    }
    func waitForUserRecovery() async { await recoveryTask?.value }
    private func recoverUserImports() async {
        ReaderOpenDiagnostics.background("recovery.begin")
        defer { ReaderOpenDiagnostics.background("recovery.return") }
        defer { recoveryTask = nil; scheduleRecentRestoration() }
        do {
            try cleanupOldBackupExports()
            let pending = try await userStore(pending: true)
            let keys = try await pending.pendingKeys()
            pendingPromotionIDs.formUnion(try keys.compactMap { if case let .pending(id) = try parseReadingKey(value: $0) { return id }; return nil })
            for id in Array(pendingPromotionIDs) where (try? textCore().importStatus(bookId: id).phase) == .complete { try await promoteUserData(id) }
            try reclaimImports(textCore()); recoveredImports = true
        } catch { /* Startup can retry; reads continue to include pending data. */ }
    }
    func receivedUserImport() async {
        defer { scheduleRecentRestoration() }
        queryCache.removeAll()
        if let store = try? await userStore() { try? await store.importedChanges() }
        if let store = try? await userStore(pending: true) { try? await store.importedChanges() }
    }
    func bookQuery(_ id: String, diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        let diagnostic = diagnostic ?? ReaderOpenDiagnostics.trace(book: id)
        diagnostic?.mark("bookQuery.actor.begin")
        defer { diagnostic?.mark("bookQuery.actor.return") }
        let generation = readingChangeRevision(id)
        diagnostic?.mark("userKey.begin")
        let key = try userKey(id)
        diagnostic?.mark("userKey.return")
        diagnostic?.mark("effectiveQuery.queued")
        let query = try await effectiveQuery(keys: Array(Set([key, serializeReadingKey(key: .pending(bookId: id))])), scope: "book-\(id)-\(generation)", diagnostic: diagnostic)
        diagnostic?.mark("effectiveQuery.resumed")
        return query
    }
    func effectiveQuery(facts: Bool = false, keys: [String]? = nil, positionsOnly: Bool = false, statisticsBook: String? = nil, scope: String = "batch", diagnostic: ReaderOpenTrace? = nil) async throws -> ReaderQuery {
        diagnostic?.mark("effectiveQuery.actor.begin")
        defer { diagnostic?.mark("effectiveQuery.actor.return") }
        diagnostic?.mark("formalStore.queued")
        let store = try await userStore(diagnostic: diagnostic)
        diagnostic?.mark("formalStore.resumed")
        diagnostic?.mark("pendingStore.queued")
        let pending = try await userStore(pending: true, diagnostic: diagnostic)
        diagnostic?.mark("pendingStore.resumed")
        diagnostic?.mark("inputSignature.begin")
        let preferences = statisticsPreferences(), core = try textCore()
        let formalVersion = store.projectionVersion, pendingVersion = pending.projectionVersion
        let hidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
        let prefix = "Moonread.preferredFile."
        let preferred: [String: String]
        if let keys {
            preferred = keys.reduce(into: [:]) { result, key in
                if let file = sourceDefaults.string(forKey: prefix + key) { result[key] = file }
            }
        } else {
            preferred = sourceDefaults.dictionaryRepresentation().reduce(into: [:]) { result, item in
                if item.key.hasPrefix(prefix), let file = item.value as? String { result[String(item.key.dropFirst(prefix.count))] = file }
            }
        }
        let cacheKey = scope + "-\(facts)-\(positionsOnly)-\(statisticsBook ?? "all")-" + (keys?.sorted().joined(separator: ",") ?? "all")
        let signature = "\(userCloudConfigurationRevision)-\(formalVersion)-\(pendingVersion)-\(preferences.generation)-\(preferences.enabled)-" + hidden.sorted().joined(separator: ",") + preferred.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: ",")
        diagnostic?.mark("inputSignature.return")
        if let cached = queryCache[cacheKey], cached.signature == signature { diagnostic?.mark("query.cacheHit"); return cached.query }
        diagnostic?.mark("formalProjection.queued")
        let formalJSON = try await store.projection(generation: preferences.generation, enabled: preferences.enabled, includeFacts: facts, keys: keys, positionsOnly: positionsOnly, statisticsBook: statisticsBook, diagnostic: diagnostic, diagnosticScope: "formalProjection")
        diagnostic?.mark("formalProjection.resumed")
        diagnostic?.mark("pendingProjection.queued")
        let pendingJSON = try await pending.projection(generation: preferences.generation, enabled: preferences.enabled, includeFacts: facts, keys: keys, positionsOnly: positionsOnly, statisticsBook: statisticsBook, diagnostic: diagnostic, diagnosticScope: "pendingProjection")
        diagnostic?.mark("pendingProjection.resumed")
        // Full JSON/TEMP work runs independently, so an exiting reader's batch cannot occupy this actor.
        diagnostic?.mark("queryBuild.queued")
        let query = try await Task.detached {
            diagnostic?.mark("queryBuild.worker.begin")
            defer { diagnostic?.mark("queryBuild.worker.return") }
            var combined = try JSONSerialization.jsonObject(with: Data(formalJSON.utf8)) as! [String: Any]
            let extra = try JSONSerialization.jsonObject(with: Data(pendingJSON.utf8)) as! [String: Any]
            for field in ["positions", "facts", "metadata", "corrections"] { combined[field] = (combined[field] as! [Any]) + (extra[field] as! [Any]) }
            let rawPositions = combined["positions"] as! [[String: Any]]
            var blockedPositions = Set((combined["unsupportedPositions"] as? [String] ?? []) + (extra["unsupportedPositions"] as? [String] ?? []))
            let rawKeys = Set(rawPositions.compactMap { $0["content_key"] as? String }).union(hidden).union(blockedPositions)
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
            let positions = PositionCandidate.reduce(candidates)
            combined["positions"] = try positions.keys.sorted().map { key -> [String: Any] in
                let candidate = positions[key]!
                var item = try candidate.projection()
                item["visible"] = !effectiveHidden.contains(key)
                item["preferred"] = preferred[key] ?? preferred[candidate.sourceKey] ?? NSNull() as Any
                return item
            }
            return try core.querySnapshot(json: String(decoding: JSONSerialization.data(withJSONObject: combined), as: UTF8.self))
        }.value
        diagnostic?.mark("queryBuild.resumed")
        if store.projectionVersion == formalVersion, pending.projectionVersion == pendingVersion {
            if queryCache.count >= 32 { queryCache.removeAll() }
            queryCache[cacheKey] = CachedQuery(signature: signature, query: query)
        }
        return query
    }
    var userDevice: String {
        if let id = sourceDefaults.string(forKey: "Moonread.userDevice") { return id }
        let id = UUID().uuidString; sourceDefaults.set(id, forKey: "Moonread.userDevice"); return id
    }
    func userKey(_ id: String) throws -> String {
        serializeReadingKey(key: try textCore().resolveBookIdentity(bookId: id).key)
    }
    func promoteUserData(_ id: String) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try await promoteUserDataLocked(id)
    }
    func promoteUserDataLocked(_ id: String) async throws {
        let key = try userKey(id)
        guard case .formal = try parseReadingKey(value: key) else { return }
        let pending = try await userStore(pending: true)
        do {
            // A late CloudKit/import arrival must not be bypassed by the promotion fast path.
            try await pending.requirePendingReadable(key: serializeReadingKey(key: .pending(bookId: id)))
            guard !promotedUserKeys.contains(id) else { return }
            let transfer = try await pending.exportPending(key: serializeReadingKey(key: .pending(bookId: id)))
            try await userStore().importPending(transfer, from: serializeReadingKey(key: .pending(bookId: id)), to: key)
            try await pending.removePending(key: serializeReadingKey(key: .pending(bookId: id)))
            let sourceKey = "Moonread.preferredFile." + serializeReadingKey(key: .pending(bookId: id))
            if let file = sourceDefaults.string(forKey: sourceKey) {
                sourceDefaults.set(file, forKey: "Moonread.preferredFile." + key); sourceDefaults.removeObject(forKey: sourceKey)
            }
            var hidden = Set(sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? [])
            if hidden.remove(serializeReadingKey(key: .pending(bookId: id))) != nil { hidden.insert(key); sourceDefaults.set(Array(hidden), forKey: "Moonread.hiddenRecent") }
            pendingPromotionIDs.remove(id)
            promotedUserKeys.insert(id)
        } catch {
            // Keep the source identity/lease recovery path alive while raw pending data is protected.
            pendingPromotionIDs.insert(id); promotedUserKeys.remove(id)
            throw error
        }
    }
    func readingCompatibilityNotice(_ id: String) async throws -> String? {
        let key = try userKey(id)
        if let notice = try await userStore(for: key).compatibilityNotice(key: key) { return notice }
        if case .formal = try parseReadingKey(value: key) { return try await userStore(pending: true).compatibilityNotice(key: serializeReadingKey(key: .pending(bookId: id))) }
        return nil
    }
    func writePosition(_ id: String, offset: UInt64) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try await promoteUserDataLocked(id)
        let core = try textCore(), key = try userKey(id)
        let normalized = try core.normalizedPosition(bookId: id, offsetUtf8: offset)
        if let file = readingSourceIDs[id] { sourceDefaults.set(file, forKey: "Moonread.preferredFile." + key) }
        var hidden = sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []; hidden.removeAll { $0 == key }
        sourceDefaults.set(hidden, forKey: "Moonread.hiddenRecent")
        let store = try await userStore(for: key)
        var hint = positionSourceHint(id)
        if hint == nil, let old = try await store.value("position/" + key) {
            hint = try UserSyncJSON.decode(PositionValue.self, old, as: UserSyncJSON.position).source_hint
        }
        let value = PositionValue(content_key: key, offset: normalized, source_hint: hint)
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try await store.put("position/\(key)", value: json, device: userDevice)
        dataChanged()
    }
    func userMarks(_ id: String, kind: MarkKind? = nil) async throws -> [ReaderMark] {
        try await promoteUserData(id)
        let key = try userKey(id)
        let groups = try await userStore(for: key).candidates(key: key)
        var values: [ReaderMark] = []
        for (markID, heads) in groups {
            guard let candidate = heads.first(where: { $0.content != nil }), let content = candidate.content else { continue }
            let candidateKind: MarkKind = candidate.bookmark ? .bookmark : .annotation
            guard kind == nil || kind == candidateKind else { continue }
            shownCandidates[markID] = heads
            values.append(ReaderMark(id: markID, kind: candidateKind, startUtf8: content.start, endUtf8: content.end,
                excerpt: content.excerpt, note: content.note, created: candidate.created))
        }
        return values.sorted { ($0.startUtf8, $0.endUtf8, $0.id) < ($1.startUtf8, $1.endUtf8, $1.id) }
    }
    func userAnnotationRanges(_ id: String, start: UInt64, end: UInt64) async throws -> [ReaderMark] {
        try await promoteUserData(id)
        let key = try userKey(id), store = try await userStore(for: key)
        let groups = try await store.candidates(key: key)
        var result: [ReaderMark] = []
        for (markID, heads) in groups {
            shownCandidates[markID] = heads
            for candidate in heads where !candidate.bookmark {
                guard let content = candidate.content, content.start < end, content.end > start else { continue }
                result.append(ReaderMark(id: markID, kind: .annotation, startUtf8: content.start, endUtf8: content.end,
                    excerpt: content.excerpt, note: content.note, created: candidate.created))
            }
        }
        return result.sorted { ($0.startUtf8, $0.endUtf8, $0.id) < ($1.startUtf8, $1.endUtf8, $1.id) }
    }
    func prepareUserAnnotation(_ id: String, start: UInt64, end: UInt64) async throws -> AnnotationEdit {
        guard start < end else { throw ReaderError.InvalidRange }
        try await promoteUserData(id)
        let key = try userKey(id)
        let groups = try await userStore(for: key).candidates(key: key)
        var marks = try await userMarks(id, kind: .annotation)
        for index in marks.indices {
            let contents = groups[marks[index].id, default: []].compactMap(\.content)
            marks[index].startUtf8 = contents.map(\.start).min() ?? marks[index].startUtf8
            marks[index].endUtf8 = contents.map(\.end).max() ?? marks[index].endUtf8
        }
        var from = start, to = end
        while true {
            let overlaps = marks.filter { $0.startUtf8 < to && $0.endUtf8 > from }
            let nextFrom = overlaps.map(\.startUtf8).min().map { min(from, $0) } ?? from
            let nextTo = overlaps.map(\.endUtf8).max().map { max(to, $0) } ?? to
            if from == nextFrom && to == nextTo { marks = overlaps; break }
            from = nextFrom; to = nextTo
        }
        let quote = try textCore().textRange(bookId: id, startUtf8: from, endUtf8: to).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markID = marks.first?.id ?? UUID().uuidString
        let note = marks.map { $0.note }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let baselines = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, groups[$0.id] ?? []) })
        var edit = AnnotationEdit(id: markID, bookId: id, startUtf8: from, endUtf8: to, excerpt: String(quote.prefix(160)), note: note, marks: marks, baselines: baselines)
        let bundle = try await userStore(for: key).editingBundle(key: key, edit: edit)
        for (mark, heads) in bundle where edit.baselines[mark] == nil { edit.baselines[mark] = heads }
        return edit
    }
    func saveUserNote(_ edit: AnnotationEdit, text: String) async throws -> ReaderMark {
        guard text.utf8.count <= 64 * 1024, edit.startUtf8 < edit.endUtf8 else { throw ReaderError.InvalidRange }
        let content = AnnotationContent(start: edit.startUtf8, end: edit.endUtf8, excerpt: edit.excerpt, note: text)
        let key = try userKey(edit.bookId)
        let created = edit.marks.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try await userStore(for: key).saveAnnotation(key: key, edit: edit, content: content)
        dataChanged()
        return ReaderMark(id: edit.id, kind: .annotation, startUtf8: content.start, endUtf8: content.end,
            excerpt: content.excerpt, note: text, created: created)
    }
    func annotationEditingBundle(_ edit: AnnotationEdit) async throws -> [String: [AnnotationCandidate]] {
        let key = try userKey(edit.bookId)
        return try await userStore(for: key).editingBundle(key: key, edit: edit)
    }
    func resolveAnnotation(_ edit: AnnotationEdit, expected: [String: [AnnotationCandidate]], content: AnnotationContent?) async throws {
        let key = try userKey(edit.bookId)
        if let content {
            guard content.note.utf8.count <= 64 * 1024, content.start < content.end else { throw ReaderError.InvalidRange }
        }
        try await userStore(for: key).resolveBundle(key: key, id: edit.id, expected: expected, content: content, edit: edit)
        dataChanged()
    }
    func userDeleteMarks(_ ids: [String], deleted: Bool) async throws {
        var grouped: [ObjectIdentifier: (UserDataStore, [MarkDeletion])] = [:]
        var restoration: [String: AnnotationContent] = [:]
        for id in Set(ids) {
            let store = try await markStore(id)
            let command: MarkDeletion
            if deleted {
                let (key, heads) = try await store.markCandidates(id)
                let baseline = shownCandidates[id] ?? heads, content = baseline.first(where: { $0.content != nil })?.content
                command = MarkDeletion(id: id, key: key, baseline: baseline, content: content, deleted: true)
                restoration[id] = content
            } else {
                guard let (baseline, content) = undoCandidates[id] else { continue }
                let (key, _) = try await store.markCandidates(id)
                command = MarkDeletion(id: id, key: key, baseline: baseline, content: content, deleted: false)
            }
            let identity = ObjectIdentifier(store)
            if grouped[identity] == nil { grouped[identity] = (store, []) }
            grouped[identity]!.1.append(command)
        }
        for (_, (store, commands)) in grouped {
            let result = try await store.applyDeletions(commands)
            for command in commands {
                if deleted, let tombstone = result[command.id] { undoCandidates[command.id] = ([tombstone], restoration[command.id]) }
                else { undoCandidates[command.id] = nil }
            }
        }
        dataChanged()
    }
}
