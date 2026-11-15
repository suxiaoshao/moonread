import Foundation
import SwiftData
import CryptoKit
import GRDB

extension ReadingKey {
    var storageKey: String { serializeReadingKey(key: self) }
    var formalSHA256: String? {
        if case .formal(let sha256) = self { return sha256 }
        return nil
    }
}

extension AppDataService {
    var userValueClock: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Attribute released stores using the owner's prior explicit consent;
    /// never infer ownership from the current system sign-in. The compatible
    /// source is the published Production store, with CloudKit disabled here.
    func publishedUserSource() throws -> (scope: DataScope, resumeNamespace: String) {
        guard let value = sourceDefaults.object(forKey: "Moonread.userOwner") else {
            return (.local, userDirectoryName + "/local")
        }
        guard let recordName = value as? String, !recordName.isEmpty else {
            throw DataV2Error.invalidOwnerState
        }
        return (try .confirmed(container: CloudConfiguration.containerID, environment: .production, recordName: recordName),
                userDirectoryName + "/" + recordName)
    }

    /// The relational writer and fixed reads must use this prepared capability.
    func relationalUserIndex() throws -> ReaderIndex {
        let index = try indexStore()
        if case .cloud(let account) = userCloudMode {
            let confirmed = try DataScope.confirmed(container: CloudConfiguration.containerID, environment: .production,
                                                    recordName: account.recordName)
            guard index.lease.scope == confirmed else { throw DataV2Error.leaseExpired }
        }
        try index.session.prepareUsers(index.lease) {
            let source = try publishedUserSource()
            guard source.scope == index.lease.scope else { return nil }
            let deviceState = try LegacyUserSnapshot.DeviceState(defaults: sourceDefaults,
                                                                confirmedLegacyResumeScope: source.resumeNamespace)
            let snapshot = try LegacyUserSnapshot.open(directory: dataDirectoryURL(), scope: source.scope,
                                                       deviceState: deviceState)
            if snapshot.formal == nil, snapshot.pending == nil,
               deviceState.hidden.isEmpty, deviceState.preferred.isEmpty, deviceState.resume.isEmpty { return nil }
            return snapshot
        }
        return index
    }

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
            promotedUserKeys.removeAll(); pendingPromotionIDs.removeAll(); recoveredImports = false
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
            let admission = try readingWriteAdmission(indexStore().lease)
            await acquireUserDataOperation(); defer { releaseUserDataOperation() }
            guard try admission.lease == indexStore().lease,
                  admission.configuration == userCloudConfigurationRevision else { return }
            let index = try relationalUserIndex()
            pendingPromotionIDs.formUnion(try index.pendingUserPromotionKeys().compactMap {
                if case let .pending(id) = try parseReadingKey(value: $0) { return id }
                return nil
            })
            // A prior usr commit can have consumed every pending row before
            // the process exited. There is still a completed index job to prove.
            for id in try index.completedReadingImportIDs() {
                // A blocked book cannot prevent another alias from recovering.
                try? promoteUserDataLocked(id, admission: admission, index: index)
            }
            try reclaimImports(index); recoveredImports = true
        } catch { /* No unverified completed reading alias is reclaimed. */ }
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
        try indexStore().resolveBookIdentity(bookId: id).key
    }
    func readingWriteAdmission(_ lease: DataSessionLease) -> ReadingWriteAdmission {
        .init(lease: lease, configuration: userCloudConfigurationRevision, epoch: readingWriteVersions.epoch)
    }

    func promoteUserData(_ id: String, retry: Bool = false) async throws {
        let admission = try readingWriteAdmission(indexStore().lease)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard try admission.lease == indexStore().lease,
              admission.configuration == userCloudConfigurationRevision else { throw CancellationError() }
        if retry { promotedUserKeys.remove(id) }
        try promoteUserDataLocked(id, admission: admission)
    }

    func promoteUserDataLocked(_ id: String, admission: ReadingWriteAdmission, index prepared: ReaderIndex? = nil) throws {
        let index = try prepared ?? indexStore()
        guard !promotedUserKeys.contains(id), try !index.completedReadingImportIDs(bookId: id).isEmpty else { return }
        let original = importWriteAdmissions[id] ?? admission
        let pending = ReadingKey.pending(bookId: id).storageKey
        let configuration = userCloudConfigurationRevision
        guard original.lease == index.lease, original.configuration == configuration else { throw CancellationError() }
        do {
            let versions = readingWriteVersions
            let writer = try prepared ?? relationalUserIndex()
            switch try writer.promotePendingUserData(bookId: id, authorize: { sha in
                let keys = [pending,sha]
                // A caller queued before deletion may not proceed. A current
                // caller may only finish an empty source, not renew the old
                // import's permission to move any of its records.
                guard versions.permits(admission, lease: writer.lease, configuration: configuration, keys: keys)
                else { throw CancellationError() }
                return versions.permits(original, lease: writer.lease, configuration: configuration, keys: keys)
                    ? .merge : .finishEmpty
            }) {
            case .notReady:
                pendingPromotionIDs.insert(id)
                // Without verified identity there is no empty-source proof.
                guard versions.permits(original, lease: writer.lease, configuration: configuration, keys: [pending])
                else { throw CancellationError() }
            case .committed, .emptySource:
                pendingPromotionIDs.remove(id)
                promotedUserKeys.insert(id)
            case .retainedRevokedSource: throw ReadingDataError.changed
            }
        } catch {
            // Keep the source identity/lease recovery path alive while raw pending data is protected.
            pendingPromotionIDs.insert(id); promotedUserKeys.remove(id)
            throw error
        }
    }
    func readingCompatibilityNotice(_ id: String) async throws -> String? {
        let identity = try userKey(id)
        let index = try relationalUserIndex()
        let isolatedAnnotation = try index.session.readUsers(index.lease) { db in
            if try AnnotationRows.hasUnreadable(db, key: identity.storageKey) { return true }
            if case .formal = identity {
                return try AnnotationRows.hasUnreadable(db, key: ReadingKey.pending(bookId: id).storageKey)
            }
            return false
        }
        if isolatedAnnotation { return UserSyncCompatibilityError().localizedDescription }
        if let notice = try await userStore(for: identity).compatibilityNotice(key: identity.storageKey) { return notice }
        if case .formal = identity { return try await userStore(pending: true).compatibilityNotice(key: serializeReadingKey(key: .pending(bookId: id))) }
        return nil
    }
    /// Separate LWW fact: never manufactures a reading position or activity.
    func recordBookOpened(_ id: String, at milliseconds: Int64, admission offered: ReadingWriteAdmission? = nil) async throws {
        let admission = try offered ?? readingWriteAdmission(indexStore().lease)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        try index.writeReadingOpened(bookID: id, openedAt: milliseconds, file: readingSourceIDs[id], device: userDevice,
                                     now: readingClock, token: UUID().uuidString,
                                     authorize: readingWriteAuthorization(id, admission: admission, index: index))
        dataChanged()
    }

    func writePosition(_ id: String, offset: UInt64, expectedConfiguration: UUID? = nil,
                       admission offered: ReadingWriteAdmission? = nil) async throws {
        let admission = try offered ?? readingWriteAdmission(indexStore().lease)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        if let expectedConfiguration, expectedConfiguration != userCloudConfigurationRevision { throw CancellationError() }
        let index = try relationalUserIndex()
        let authorize = readingWriteAuthorization(id, admission: admission, index: index)
        // Do not run promotion on behalf of a stale request. The writer
        // repeats authorization against the actual commit-time key.
        try authorize(index.resolveBookIdentity(bookId: id).key.storageKey)
        try promoteUserDataLocked(id, admission: admission, index: index)
        try index.writeReadingPosition(bookID: id, offset: offset, hint: positionSourceHint(id), file: readingSourceIDs[id],
                                       device: userDevice, now: readingClock, token: UUID().uuidString, authorize: authorize)
        dataChanged()
    }

    private var readingClock: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func readingWriteAuthorization(_ id: String, admission: ReadingWriteAdmission, index: ReaderIndex) -> (String) throws -> Void {
        let versions = readingWriteVersions, lease = index.lease, configuration = userCloudConfigurationRevision
        let pending = ReadingKey.pending(bookId: id).storageKey
        return { key in
            guard versions.permits(admission, lease: lease, configuration: configuration, keys: [pending,key])
            else { throw CancellationError() }
        }
    }

    func annotationActionAdmission() throws -> ReadingWriteAdmission { try readingWriteAdmission(indexStore().lease) }

    // All book-scoped mutations share the operation gate and re-resolve
    // the route within the writer. Admission never comes from the commit.
    private func editAnnotationRows<T: Sendable>(_ id: String, offered: ReadingWriteAdmission?,
                                                 _ operation: (Database, String, ReadingWriteAdmission) throws -> T) async throws -> T {
        let admission = try offered ?? readingWriteAdmission(indexStore().lease)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        let authorize = readingWriteAuthorization(id, admission: admission, index: index)
        try authorize(index.resolveBookIdentity(bookId: id).key.storageKey)
        try promoteUserDataLocked(id, admission: admission, index: index)
        return try index.session.writeUsers(index.lease) { db in
            let key = try ReaderIndex.body(db, id: id, scope: index.lease.scope.key).sha
            try authorize(key)
            return try operation(db, key, admission)
        }
    }

    func annotationSnapshot(_ id: String, offered: ReadingWriteAdmission? = nil) async throws -> NoteCandidates {
        let admission = try offered ?? readingWriteAdmission(indexStore().lease)
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        let authorize = readingWriteAuthorization(id, admission: admission, index: index)
        try authorize(index.resolveBookIdentity(bookId: id).key.storageKey)
        try promoteUserDataLocked(id, admission: admission, index: index)
        let result = try index.session.readUsers(index.lease) { db in
            let key = try ReaderIndex.body(db, id: id, scope: index.lease.scope.key).sha
            return try AnnotationRows.snapshot(db, key: key)
        }
        try authorize(result.key)
        var stamped = result
        stamped.admission = admission
        stamped.sourceBookID = id
        return stamped
    }

    private func marks(_ view: NoteCandidates, kind: MarkKind?, range: Range<UInt64>? = nil) -> [ReaderMark] {
        var result: [ReaderMark] = []
        for (id, heads) in view.groups {
            let values = range == nil ? heads.first(where: { $0.content != nil }).map { [$0] } ?? [] : heads
            for value in values {
                guard let content = value.content else { continue }
                let candidateKind: MarkKind = value.bookmark ? .bookmark : .annotation
                guard kind == nil || kind == candidateKind else { continue }
                if let range, !(content.start < range.upperBound && content.end > range.lowerBound) { continue }
                if let admission = view.admission {
                    shownCandidates[id] = .init(heads: heads, key: view.key, admission: admission, sourceBookID: view.sourceBookID)
                }
                result.append(.init(id: id, kind: candidateKind, startUtf8: content.start, endUtf8: content.end,
                                    excerpt: content.excerpt, note: content.note, created: value.created))
            }
        }
        return result.sorted { ($0.startUtf8, $0.endUtf8, $0.id) < ($1.startUtf8, $1.endUtf8, $1.id) }
    }

    func userMarks(_ id: String, kind: MarkKind? = nil, snapshot: NoteCandidates? = nil) async throws -> [ReaderMark] {
        if let snapshot {
            let index = try indexStore()
            guard snapshot.key == (try index.resolveBookIdentity(bookId: id).key.storageKey) else { throw UserDataConflict(candidates: []) }
            if let admission = snapshot.admission { try readingWriteAuthorization(id, admission: admission, index: index)(snapshot.key) }
            return marks(snapshot, kind: kind)
        }
        return try await marks(annotationSnapshot(id), kind: kind)
    }

    func userAnnotationRanges(_ id: String, start: UInt64, end: UInt64) async throws -> [ReaderMark] {
        guard start <= end else { throw ReaderError.InvalidRange }
        return try await marks(annotationSnapshot(id), kind: .annotation, range: start..<end)
    }

    func removeAnnotationRange(_ id: String, start: UInt64, end: UInt64, offered: ReadingWriteAdmission?) async throws -> [String] {
        guard start <= end else { throw ReaderError.InvalidRange }
        let view = try await annotationSnapshot(id, offered: offered)
        let ids = marks(view, kind: .annotation, range: start..<end).map(\.id)
        try await userDeleteMarks(ids, deleted: true, expected: view)
        return ids
    }

    func prepareUserAnnotation(_ id: String, start: UInt64, end: UInt64,
                               admission: ReadingWriteAdmission? = nil) async throws -> AnnotationEdit {
        guard start < end else { throw ReaderError.InvalidRange }
        let view = try await annotationSnapshot(id, offered: admission)
        var marks = marks(view, kind: .annotation)
        for index in marks.indices {
            let contents = view.groups[marks[index].id, default: []].compactMap(\.content)
            marks[index].startUtf8 = contents.map(\.start).min() ?? marks[index].startUtf8
            marks[index].endUtf8 = contents.map(\.end).max() ?? marks[index].endUtf8
        }
        var from = start, to = end
        while true {
            let overlaps = marks.filter { $0.startUtf8 < to && $0.endUtf8 > from }
            let nextFrom = overlaps.map(\.startUtf8).min().map { min(from, $0) } ?? from
            let nextTo = overlaps.map(\.endUtf8).max().map { max(to, $0) } ?? to
            if nextFrom == from && nextTo == to { marks = overlaps; break }
            from = nextFrom; to = nextTo
        }
        let quote = try indexStore().textRange(bookId: id, startUtf8: from, endUtf8: to).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markID = marks.first?.id ?? UUID().uuidString
        let note = marks.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let baselines = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, view.groups[$0.id] ?? []) })
        var edit = AnnotationEdit(id: markID, bookId: id, startUtf8: from, endUtf8: to, excerpt: String(quote.prefix(160)), note: note,
                                  marks: marks, baselines: baselines, writeAdmission: view.admission)
        for (mark, heads) in try AnnotationRows.editingBundle(view, edit: edit) where edit.baselines[mark] == nil { edit.baselines[mark] = heads }
        return edit
    }

    func saveUserNote(_ edit: AnnotationEdit, text: String) async throws -> ReaderMark {
        guard text.utf8.count <= 64 * 1024, edit.startUtf8 < edit.endUtf8 else { throw ReaderError.InvalidRange }
        let content = AnnotationContent(start: edit.startUtf8, end: edit.endUtf8, excerpt: edit.excerpt, note: text)
        let candidate = try await editAnnotationRows(edit.bookId, offered: edit.writeAdmission) { db, key, _ in
            try AnnotationRows.edit(db, key: key, edit: edit, content: content)
        }
        dataChanged()
        return ReaderMark(id: edit.id, kind: .annotation, startUtf8: content.start, endUtf8: content.end,
                          excerpt: content.excerpt, note: text, created: candidate.created)
    }
    func annotationEditingBundle(_ edit: AnnotationEdit) async throws -> [String: [AnnotationCandidate]] {
        try await AnnotationRows.editingBundle(annotationSnapshot(edit.bookId, offered: edit.writeAdmission), edit: edit)
    }
    func resolveAnnotation(_ edit: AnnotationEdit, expected: [String: [AnnotationCandidate]], content: AnnotationContent?) async throws {
        if let content {
            guard content.note.utf8.count <= 64 * 1024, content.start < content.end else { throw ReaderError.InvalidRange }
        }
        _ = try await editAnnotationRows(edit.bookId, offered: edit.writeAdmission) { db, key, _ in
            try AnnotationRows.edit(db, key: key, edit: edit, content: content, resolving: expected)
        }
        dataChanged()
    }

    func changeBookmark(_ id: String, offset: UInt64, ensure: Bool, admission offered: ReadingWriteAdmission?) async throws -> ReaderMark? {
        let admission = try offered ?? readingWriteAdmission(indexStore().lease)
        let excerpt = try indexStore().paragraphRange(bookId: id, offsetUtf8: offset).text
        let (mark, candidate) = try await editAnnotationRows(id, offered: admission) { db, key, _ in
            try AnnotationRows.bookmark(db, key: key, offset: offset, excerpt: String(excerpt.prefix(160)), ensure: ensure)
        }
        dataChanged()
        guard let content = candidate.content else { return nil }
        return ReaderMark(id: mark, kind: .bookmark, startUtf8: content.start, endUtf8: content.end,
                          excerpt: content.excerpt, note: content.note, created: candidate.created)
    }

    func readAnnotationMark(_ id: String) throws -> ReaderMark {
        let index = try relationalUserIndex(), admission = readingWriteAdmission(index.lease)
        let (key, heads) = try index.session.readUsers(index.lease) { try AnnotationRows.find($0, markID: id) }
        guard let value = heads.first(where: { $0.content != nil }), let content = value.content else { throw ReaderError.NotFound }
        shownCandidates[id] = .init(heads: heads, key: key, admission: admission)
        return ReaderMark(id: id, kind: value.bookmark ? .bookmark : .annotation, startUtf8: content.start, endUtf8: content.end,
                          excerpt: content.excerpt, note: content.note, created: value.created)
    }

    func deleteSelectedAnnotations(_ id: String, expected: NoteCandidates, ids: Set<String>) async throws {
        let groups = try expected.checked(ids)
        guard ids == Set(groups.keys) else { throw UserDataConflict(candidates: []) }
        let receipts: [String: MarkUndo] = try await editAnnotationRows(id, offered: expected.admission) { db, key, admission in
            guard key == expected.key else { throw UserDataConflict(candidates: []) }
            let commands = ids.sorted().map { id in
                let heads = groups[id] ?? []
                return MarkDeletion(id: id, key: key, baseline: heads, content: heads.first(where: { $0.content != nil })?.content, deleted: true)
            }
            let committed = try AnnotationRows.deletions(db, commands: commands, checkingBaseline: true)
            return deletionReceipts(commands, committed: committed, admission: admission, origins: commands.reduce(into: [:]) { $0[$1.id] = id })
        }
        undoCandidates.merge(receipts) { _, new in new }
        dataChanged()
    }

    private func deletionReceipts(_ commands: [MarkDeletion], committed: [String: AnnotationCandidate],
                                  admission: ReadingWriteAdmission, origins: [String: String]) -> [String: MarkUndo] {
        Dictionary(uniqueKeysWithValues: commands.compactMap { cmd in
            committed[cmd.id].map {
                (cmd.id, MarkUndo(baseline: .init(heads: [$0], key: cmd.key, admission: admission, sourceBookID: origins[cmd.id]), content: cmd.content))
            }
        })
    }

    func userDeleteMarks(_ ids: [String], deleted: Bool, expected: NoteCandidates? = nil,
                         offered: ReadingWriteAdmission? = nil) async throws {
        let admission = try offered ?? expected?.admission ?? readingWriteAdmission(indexStore().lease)
        // Capture what was shown / the original undo before waiting for the gate.
        var shown = shownCandidates
        let undo = undoCandidates
        if deleted, let expected, let receipt = expected.admission {
            for (id, heads) in try expected.checked(Set(ids)) {
                shown[id] = .init(heads: heads, key: expected.key, admission: receipt, sourceBookID: expected.sourceBookID)
            }
        }
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex(), configuration = userCloudConfigurationRevision, versions = readingWriteVersions
        let receipts: [String: MarkUndo] = try index.session.writeUsers(index.lease) { db in
            var commands: [MarkDeletion] = []
            var origins: [String: String] = [:]
            for id in Set(ids).sorted() {
                let prior = deleted ? shown[id] : undo[id]?.baseline
                if !deleted && prior == nil { continue }
                let (key, heads) = try AnnotationRows.find(db, markID: id)
                let alias = prior?.sourceBookID.map { ReadingKey.pending(bookId: $0).storageKey }
                let keys = [key] + (prior.map { [$0.key] } ?? []) + (alias.map { [$0] } ?? [])
                guard versions.permits(admission, lease: index.lease, configuration: configuration, keys: keys),
                      prior.map({ versions.permits($0.admission, lease: index.lease, configuration: configuration, keys: keys) }) ?? true
                else { throw CancellationError() }
                if let prior, prior.key != key {
                    guard case let .pending(source) = try parseReadingKey(value: prior.key),
                          try ReaderIndex.body(db, id: source, scope: index.lease.scope.key).sha == key
                    else { throw UserDataConflict(candidates: heads) }
                }
                origins[id] = prior?.sourceBookID
                let baseline = prior?.heads ?? heads
                let content = deleted ? baseline.first(where: { $0.content != nil })?.content : undo[id]?.content
                commands.append(.init(id: id, key: key, baseline: baseline, content: content, deleted: deleted))
            }
            let committed = try AnnotationRows.deletions(db, commands: commands, checkingBaseline: false)
            return deletionReceipts(commands, committed: committed, admission: admission, origins: origins)
        }
        if deleted { undoCandidates.merge(receipts) { _, new in new } }
        else { for id in receipts.keys { undoCandidates[id] = nil } }
        if !receipts.isEmpty { dataChanged() }
    }
}
