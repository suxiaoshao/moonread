import MoonreadReader
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import SwiftData
import CryptoKit

enum UserAuthorityPreparationError: LocalizedError {
    case ownership, unreadableSource, verification

    var errorDescription: String? {
        switch self {
        case .ownership: String(localized: "无法确认旧阅读数据的归属。请保留原数据，并在恢复原有账户归属后重试。")
        case .unreadableSource: String(localized: "暂时无法读取旧阅读数据。请确认本机数据可访问后重试。")
        case .verification: String(localized: "未能完成阅读数据迁入或校验。请检查可用存储空间后重试。")
        }
    }
}

extension AppDataService {
    var userValueClock: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// The relational writer and fixed reads must use this prepared capability.
    func relationalUserIndex() throws -> ReaderIndex {
        let index = try indexStore()
        try prepareUserIndex(index)
        return index
    }

    func prepareUserIndex(_ index: ReaderIndex, progress: (@Sendable (LegacyImportProgress) -> Void)? = nil) throws {
        try index.session.prepareUsers(index.lease, progress: progress) {
            guard index.session.releasedLayout != .otherEnvironment else { return nil }
            let source = try publishedUserSource()
            guard source == index.lease.scope else { return nil }
            let deviceState: LegacyUserSnapshot.DeviceState
            let snapshot: LegacyUserSnapshot
            do {
                #if DEBUG
                if testSession != nil, ProcessInfo.processInfo.arguments.contains("--ui-test-migration-read-failure"),
                   !injectedLegacyReadFailure {
                    injectedLegacyReadFailure = true
                    throw CocoaError(.fileReadNoPermission)
                }
                #endif
                // Defaults still holds the old suffix for these two migration inputs.
                // The database scope above is the authority for reading the source.
                let suffix = source == .local ? "local" : sourceDefaults.string(forKey: "Moonread.userOwner")
                deviceState = try .init(defaults: sourceDefaults, confirmedLegacyResumeScope: suffix.map { userDirectoryName + "/" + $0 })
                snapshot = try LegacyUserSnapshot.open(directory: dataDirectoryURL(), scope: source,
                                                       deviceState: deviceState, progress: progress)
            } catch { throw UserAuthorityPreparationError.unreadableSource }
            if snapshot.formal == nil, snapshot.pending == nil,
               deviceState.hidden.isEmpty, deviceState.preferred.isEmpty, deviceState.resume.isEmpty, deviceState.shelfRecovery == nil { return nil }
            return snapshot
        }
    }

    /// The root cannot mount normal reading, settings or import views before
    /// both authorities have prepared successfully. Retrying reuses the
    /// ordinary transaction and completion marker, never resets either store.
    func prepareUserAuthorityForStartup(progress: (@Sendable (LegacyImportProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        do {
            let index = try indexStore()
            try prepareUserIndex(index, progress: progress)
            try await cleanLegacyLocalState(index)
        }
        catch let error as UserAuthorityPreparationError { throw error }
        catch DataV2Error.invalidOwnerState { throw UserAuthorityPreparationError.ownership }
        catch { throw UserAuthorityPreparationError.verification }
    }

    private func cleanLegacyLocalState(_ index: ReaderIndex) async throws {
        guard libraryDirectoryOverride == nil, testSession == nil, let domain = Bundle.main.bundleIdentifier else { return }
        guard try index.needsLegacyLocalCleanup() else { return }
        try await clearLegacySpotlight()
        try await clearLegacyDonations()
        let handoff = try dataDirectoryURL().appending(path: "CloudHandoff", directoryHint: .isDirectory)
        do { try FileManager.default.removeItem(at: handoff) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        try approveReadingCloudDuringLegacyCleanup()
        Self.removeLegacyLocalDefaults(sourceDefaults, domain: domain)
        try index.completeLegacyLocalCleanup()
    }

    static func removeLegacyLocalDefaults(_ defaults: UserDefaults, domain: String) {
        guard let saved = defaults.persistentDomain(forName: domain) else { return }
        let names: Set<String> = [
            "Moonread.hiddenRecent", "Moonread.seededExampleFileID", "Moonread.userDevice", "Moonread.userOwner",
            "Moonread.cloudLibraryOwner", "Moonread.fullIndex.request.v1", "Moonread.systemSpotlight.v1",
            "Moonread.systemReadingDonations.v1", "Moonread.systemReadingScope.v1",
            LocalReadingResumeState.key, ShelfReferenceBindings.key,
        ]
        let keys = saved.keys.filter {
            names.contains($0) || $0.hasPrefix(IndexImport.legacySourcePrefix) ||
            $0.hasPrefix(IndexImport.legacyDraftPrefix) || $0.hasPrefix("Moonread.preferredFile.")
        }
        for key in keys { defaults.removeObject(forKey: key) }
    }

    func startUserRecovery() {
        guard !changingUserScope, !recoveredImports, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in await self?.recoverUserImports() }
    }
    func waitForUserRecovery() async { await recoveryTask?.value }
    private func recoverUserImports() async {
        ReaderOpenDiagnostics.background("recovery.begin")
        defer { ReaderOpenDiagnostics.background("recovery.return") }
        defer { recoveryTask = nil; scheduleRecentRestoration() }
        do {
            try cleanupOldBackupExports()
            let admission = try indexStore().lease
            await acquireUserDataOperation(); defer { releaseUserDataOperation() }
            guard try admission == indexStore().lease else { return }
            let index = try relationalUserIndex()
            try index.session.prepareReadingHistory(index.lease, owner: index.session.readingInstallationID())
            pendingPromotionIDs.formUnion(try index.pendingUserPromotionKeys().compactMap {
                if case let .pending(id) = try parseReadingKey(value: $0) { return id }
                return nil
            })
            // A prior usr commit can have consumed every pending row before
            // the process exited. There is still a completed index job to prove.
            for id in try index.completedReadingImportIDs() {
                // A blocked book cannot prevent another alias from recovering.
                try? promoteUserDataLocked(id, index: index)
            }
            try reclaimImports(index); recoveredImports = true
        } catch { /* No unverified completed reading alias is reclaimed. */ }
    }
    func userKey(_ id: String) throws -> ReadingKey {
        try indexStore().resolveBookIdentity(bookId: id).key
    }
    func promoteUserData(_ id: String, retry: Bool = false) async throws {
        let admission = try indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        guard try admission == indexStore().lease else { throw CancellationError() }
        if retry { promotedUserKeys.remove(id) }
        try promoteUserDataLocked(id)
    }

    private func promoteUserDataLocked(_ id: String, index prepared: ReaderIndex? = nil) throws {
        let index = try prepared ?? indexStore()
        guard !promotedUserKeys.contains(id), try !index.completedReadingImportIDs(bookId: id).isEmpty else { return }
        do {
            let writer = try prepared ?? relationalUserIndex()
            switch try writer.promotePendingUserData(bookId: id) {
            case .notReady:
                pendingPromotionIDs.insert(id)
            case .committed:
                pendingPromotionIDs.remove(id)
                promotedUserKeys.insert(id)
            }
        } catch {
            pendingPromotionIDs.insert(id); promotedUserKeys.remove(id)
            throw error
        }
    }

    func readingCompatibilityNotice(_ id: String) async throws -> String? {
        let identity = try userKey(id)
        let index = try relationalUserIndex()
        let blocked = try index.hasReaderCompatibilityBarrier(keys: [identity.storageKey, ReadingKey.pending(bookId: id).storageKey])
        return blocked ? UserSyncCompatibilityError().localizedDescription : nil
    }
    /// Separate LWW fact: never manufactures a reading position or activity.
    func recordBookOpened(_ id: String, at milliseconds: Int64, admission offered: DataSessionLease? = nil) async throws {
        let admission = try offered ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        guard admission == index.lease else { throw CancellationError() }
        try index.writeReadingOpened(bookID: id, openedAt: milliseconds, file: readingSourceIDs[id], device: userDevice,
                                     now: readingClock, token: UUID().uuidString)
        dataChanged()
    }

    func writePosition(_ id: String, offset: UInt64, at now: Int64? = nil, expectedConfiguration: UUID? = nil,
                       admission offered: DataSessionLease? = nil) async throws {
        let admission = try offered ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        if let expectedConfiguration, expectedConfiguration != userCloudConfigurationRevision { throw CancellationError() }
        let index = try relationalUserIndex()
        guard admission == index.lease else { throw CancellationError() }
        try promoteUserDataLocked(id, index: index)
        try index.writeReadingPosition(bookID: id, offset: offset, hint: positionSourceHint(id), file: readingSourceIDs[id],
                                       device: userDevice, now: now ?? readingClock, token: UUID().uuidString)
        dataChanged()
    }

    private var readingClock: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func annotationActionAdmission() throws -> DataSessionLease { try indexStore().lease }

    private func annotationIndex(_ id: String, admission: DataSessionLease) throws -> ReaderIndex {
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        guard admission == index.lease else { throw CancellationError() }
        try promoteUserDataLocked(id, index: index)
        return index
    }

    func annotationSnapshot(_ id: String, offered: DataSessionLease? = nil) async throws -> NoteCandidates {
        let admission = try offered ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        return try annotationIndex(id, admission: admission).annotationSnapshot(bookID: id)
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
                    shownCandidates[id] = .init(heads: heads, key: view.key, admission: admission)
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
            if let admission = snapshot.admission, admission != index.lease { throw CancellationError() }
            return marks(snapshot, kind: kind)
        }
        return try await marks(annotationSnapshot(id), kind: kind)
    }

    func annotationWindow(_ id: String, start: UInt64, end: UInt64) async throws -> ReaderAnnotationWindow {
        guard start <= end else { throw ReaderError.InvalidRange }
        let snapshot = try await annotationSnapshot(id)
        let visible = marks(snapshot, kind: .annotation, range: start..<end)
        let ids = Set(visible.map(\.id))
        let candidates = NoteCandidates(key: snapshot.key, groups: snapshot.groups.filter { ids.contains($0.key) },
            blocked: snapshot.blocked.intersection(ids), unknownMarks: snapshot.unknownMarks, admission: snapshot.admission)
        return .init(marks: visible, candidates: candidates)
    }

    func prepareUserAnnotation(_ id: String, start: UInt64, end: UInt64,
                               admission: DataSessionLease? = nil) async throws -> AnnotationEdit {
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
        let quote = try indexStore().textRange(bookId: id, startUtf8: from, endUtf8: to).text
        let markID = marks.first?.id ?? UUID().uuidString
        let note = marks.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let baselines = Dictionary(uniqueKeysWithValues: marks.map { ($0.id, view.groups[$0.id] ?? []) })
        var edit = AnnotationEdit(id: markID, bookId: id, startUtf8: from, endUtf8: to, excerpt: AnnotationEdit.excerpt(from: quote), note: note,
                                  marks: marks, baselines: baselines, writeAdmission: view.admission)
        for (mark, heads) in try AnnotationRows.editingBundle(view, edit: edit) where edit.baselines[mark] == nil { edit.baselines[mark] = heads }
        return edit
    }

    func saveUserNote(_ edit: AnnotationEdit, text: String) async throws -> ReaderMark {
        guard text.utf8.count <= 64 * 1024, edit.startUtf8 < edit.endUtf8 else { throw ReaderError.InvalidRange }
        let content = AnnotationContent(start: edit.startUtf8, end: edit.endUtf8, excerpt: edit.excerpt, note: text)
        let admission = try edit.writeAdmission ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let candidate = try annotationIndex(edit.bookId, admission: admission).saveAnnotation(edit, content: content)
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
        let admission = try edit.writeAdmission ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        _ = try annotationIndex(edit.bookId, admission: admission).saveAnnotation(edit, content: content, resolving: expected)
        dataChanged()
    }

    func changeBookmark(_ id: String, offset: UInt64, ensure: Bool, admission offered: DataSessionLease?) async throws -> ReaderMark? {
        let admission = try offered ?? indexStore().lease
        let excerpt = try indexStore().paragraphRange(bookId: id, offsetUtf8: offset).text
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let (mark, candidate) = try annotationIndex(id, admission: admission)
            .changeBookmark(bookID: id, offset: offset, excerpt: String(excerpt.prefix(160)), ensure: ensure)
        dataChanged()
        guard let content = candidate.content else { return nil }
        return ReaderMark(id: mark, kind: .bookmark, startUtf8: content.start, endUtf8: content.end,
                          excerpt: content.excerpt, note: content.note, created: candidate.created)
    }

    func readAnnotationMark(_ id: String) throws -> ReaderMark {
        let index = try relationalUserIndex(), admission = index.lease
        let (key, heads) = try index.annotationHeads(markID: id)
        guard let value = heads.first(where: { $0.content != nil }), let content = value.content else { throw ReaderError.NotFound }
        shownCandidates[id] = .init(heads: heads, key: key, admission: admission)
        return ReaderMark(id: id, kind: value.bookmark ? .bookmark : .annotation, startUtf8: content.start, endUtf8: content.end,
                          excerpt: content.excerpt, note: content.note, created: value.created)
    }

    func deleteSelectedAnnotations(_ id: String, expected: NoteCandidates, ids: Set<String>) async throws {
        let groups = try expected.checked(ids)
        guard ids == Set(groups.keys) else { throw UserDataConflict(candidates: []) }
        let admission = try expected.admission ?? indexStore().lease
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        let receipts = try annotationIndex(id, admission: admission)
            .deleteSelectedAnnotations(bookID: id, expectedKey: expected.key, groups: groups)
        undoCandidates.merge(receipts) { _, new in new }
        dataChanged()
    }

    func userDeleteMarks(_ ids: [String], deleted: Bool, expected: NoteCandidates? = nil,
                         offered: DataSessionLease? = nil) async throws {
        let admission = try offered ?? expected?.admission ?? indexStore().lease
        // Capture what was shown / the original undo before waiting for the gate.
        var shown = shownCandidates
        let undo = undoCandidates
        if deleted, let expected, let receipt = expected.admission {
            for (id, heads) in try expected.checked(Set(ids)) {
                shown[id] = .init(heads: heads, key: expected.key, admission: receipt)
            }
        }
        await acquireUserDataOperation(); defer { releaseUserDataOperation() }
        try Task.checkCancellation()
        let index = try relationalUserIndex()
        guard admission == index.lease else { throw CancellationError() }
        let receipts = try index.changeAnnotationsDeletion(ids, deleted: deleted, shown: shown, undo: undo)
        if deleted { undoCandidates.merge(receipts) { _, new in new } }
        else { for id in receipts.keys { undoCandidates[id] = nil } }
        if !receipts.isEmpty { dataChanged() }
    }
}
