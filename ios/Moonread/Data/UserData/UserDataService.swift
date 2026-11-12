import Foundation
import SwiftData
import CryptoKit

extension ReadingKey {
    var storageKey: String { serializeReadingKey(key: self) }
    var formalSHA256: String? {
        if case .formal(let sha256) = self { return sha256 }
        return nil
    }
}

extension AppDataService {
    func userStore(pending: Bool = false, diagnostic: ReaderOpenTrace? = nil) async throws -> UserDataStore {
        let label = pending ? "pendingStore" : "formalStore"
        diagnostic?.mark(label + ".service.begin")
        defer { diagnostic?.mark(label + ".service.return") }
        let initialization: UserStoreInitialization
        if let cached = pending ? pendingUserStoreTask : userStoreTask { initialization = cached }
        else {
            let name = userDirectoryName, factory = userStoreFactory
            let cloud = !pending && userCloudMode.isCloud
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
        try await userStore(for: parseReadingKey(value: key))
    }
    func userStore(for key: ReadingKey) async throws -> UserDataStore {
        switch key {
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
    func configureUserCloud(_ configuration: CloudConfiguration) async throws {
        await acquireUserDataOperation()
        var holdsOperation = true
        defer { if holdsOperation { releaseUserDataOperation() } }
        let mode: UserCloudStoreMode
        switch configuration {
        case .local: mode = .local
        case .cloud(let verified, let consent):
            let account = verified.recordName
            if let previous = sourceDefaults.string(forKey: "Moonread.userOwner"), previous != account,
               case .currentOwner = consent { throw ReaderError.CloudAccountChanged }
            // Verified user consent remains valid even if initialization fails.
            if sourceDefaults.string(forKey: "Moonread.userOwner") == nil { try? adoptLocalShelfBindings(account: account) }
            sourceDefaults.set(account, forKey: "Moonread.userOwner")
            mode = .cloud(verified)
        }
        if userCloudMode != mode {
            cancelRecentRestoration()
            userStoreTask = nil; userCloudMode = mode
            userCloudConfigurationRevision = UUID()
            resetSystemReadingCatalog()
            NotificationCenter.default.post(name: .readingContinuationInvalidated, object: nil)
            NotificationCenter.default.post(name: .statisticsChanged, object: nil, userInfo: ["reset": true])
            let revision = userCloudConfigurationRevision
            // The configuration switch is serialized with deletion, not store
            // bootstrap: a newer configuration must be able to replace a stuck
            // initialization (the existing revision guard rejects its late result).
            releaseUserDataOperation(); holdsOperation = false
            do { _ = try await userStore() }
            catch {
                if userCloudConfigurationRevision == revision { userCloudMode = .local }
                throw error
            }
            guard userCloudConfigurationRevision == revision else { return }
            scheduleRecentRestoration(); scheduleSystemReadingCatalog(immediate: true)
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
    var userDevice: String {
        if let id = sourceDefaults.string(forKey: "Moonread.userDevice") { return id }
        let id = UUID().uuidString; sourceDefaults.set(id, forKey: "Moonread.userDevice"); return id
    }
    func userKey(_ id: String) throws -> ReadingKey {
        try textCore().resolveBookIdentity(bookId: id).key
    }
    func promoteUserData(_ id: String, retry: Bool = false) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        if retry { promotedUserKeys.remove(id) }
        try await promoteUserDataLocked(id)
    }
    func promoteUserDataLocked(_ id: String) async throws {
        guard case .formal(let key) = try userKey(id) else { return }
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
            if !transfer.facts.isEmpty { NotificationCenter.default.post(name: .statisticsChanged, object: nil) }
        } catch {
            // Keep the source identity/lease recovery path alive while raw pending data is protected.
            pendingPromotionIDs.insert(id); promotedUserKeys.remove(id)
            throw error
        }
    }
    func readingCompatibilityNotice(_ id: String) async throws -> String? {
        let identity = try userKey(id)
        if let notice = try await userStore(for: identity).compatibilityNotice(key: identity.storageKey) { return notice }
        if case .formal = identity { return try await userStore(pending: true).compatibilityNotice(key: serializeReadingKey(key: .pending(bookId: id))) }
        return nil
    }
    /// Separate LWW fact: never manufactures a reading position or activity.
    func recordBookOpened(_ id: String, at milliseconds: Int64) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let key = try userKey(id).storageKey
        if let file = readingSourceIDs[id] { sourceDefaults.set(file, forKey: "Moonread.preferredFile." + key) }
        var hidden = sourceDefaults.stringArray(forKey: "Moonread.hiddenRecent") ?? []
        hidden.removeAll { $0 == key }; sourceDefaults.set(hidden, forKey: "Moonread.hiddenRecent")
        _ = try await userStore(for: key).put("opened/" + key, value: String(milliseconds), device: userDevice)
        dataChanged()
    }
    func writePosition(_ id: String, offset: UInt64, expectedConfiguration: UUID? = nil) async throws {
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        if let expectedConfiguration, expectedConfiguration != userCloudConfigurationRevision { throw CancellationError() }
        try await promoteUserDataLocked(id)
        let core = try textCore(), key = try userKey(id).storageKey
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
        let stored = try await store.put("position/\(key)", value: json, device: userDevice)
        // A missing device receipt may suppress a hint, but cannot turn a
        // committed position into a failed write or rewrite that sync fact.
        do { try rememberLocalReadingPosition(key: key, offset: normalized, token: stored.token) }
        catch { UserSyncJSON.quarantined("local reading baseline") }
        dataChanged()
    }
    func userMarks(_ id: String, kind: MarkKind? = nil, snapshot: NoteCandidates? = nil) async throws -> [ReaderMark] {
        try await promoteUserData(id)
        let key = try userKey(id).storageKey
        let groups: [String: [AnnotationCandidate]]
        if let snapshot {
            guard snapshot.key == key else { throw UserDataConflict(candidates: []) }
            groups = snapshot.groups
        } else { groups = try await userStore(for: key).candidates(key: key) }
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
        let key = try userKey(id).storageKey, store = try await userStore(for: key)
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
        let key = try userKey(id).storageKey
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
        let key = try userKey(edit.bookId).storageKey
        let created = edit.marks.map(\.created).min() ?? UInt64(Date().timeIntervalSince1970 * 1000)
        _ = try await userStore(for: key).saveAnnotation(key: key, edit: edit, content: content)
        dataChanged()
        return ReaderMark(id: edit.id, kind: .annotation, startUtf8: content.start, endUtf8: content.end,
            excerpt: content.excerpt, note: text, created: created)
    }
    func annotationEditingBundle(_ edit: AnnotationEdit) async throws -> [String: [AnnotationCandidate]] {
        let key = try userKey(edit.bookId).storageKey
        return try await userStore(for: key).editingBundle(key: key, edit: edit)
    }
    func resolveAnnotation(_ edit: AnnotationEdit, expected: [String: [AnnotationCandidate]], content: AnnotationContent?) async throws {
        let key = try userKey(edit.bookId).storageKey
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
