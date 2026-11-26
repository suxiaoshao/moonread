import MoonreadCoreBindings
import SwiftUI
import Combine
import UIKit

enum ReaderLibraryTab: Hashable { case chapters, bookmarks, notes }
enum ReaderSelectionAction: Equatable {
    case highlight, comment, paragraph, beginRange, chapter, search, copy, shareExcerpt
}

extension AnnotationEdit {
    var presentationID: String { "\(id)-\(startUtf8)-\(endUtf8)" }
}

@MainActor @Observable
final class ReaderToolsModel {
    var tab: ReaderLibraryTab = .chapters
    var chapterFilter = ""
    var chapters: [ChapterEntry] = []
    private struct ChapterStructure {
        let version = UUID()
        let outline: ChapterOutline
    }
    private enum StructureLoad {
        case idle
        case loading(previous: ChapterStructure?)
        case ready(ChapterStructure)
        case failed(String, previous: ChapterStructure?)

        var snapshot: ChapterStructure? {
            switch self {
            case .idle: nil
            case .loading(let previous), .failed(_, let previous): previous
            case .ready(let snapshot): snapshot
            }
        }
        mutating func cancel() {
            guard case .loading(let previous) = self else { return }
            self = previous.map(Self.ready) ?? .idle
        }
    }
    private var chapterStructure = StructureLoad.idle
    private var allChapters: [ChapterEntry] { chapterStructure.snapshot?.outline.items ?? [] }
    @ObservationIgnored private var accountChange: AnyCancellable?
    private(set) var chapterAccountRevision: UUID?
    private var coverage: ChapterOutline?
    private(set) var chapterCoverageError: String?
    var chapterCoverageReady: Bool { coverage?.items.contains { $0.coveredCharacters != nil } ?? false }
    var chapterCoverageRequest: UUID? { chapterStructure.snapshot?.version }

    func chapterWithCoverage(_ entry: ChapterEntry) -> ChapterEntry {
        guard let coverage else { return entry }
        var lo = 0, hi = coverage.items.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if coverage.items[mid].startUtf8 < entry.startUtf8 { lo = mid + 1 } else { hi = mid }
        }
        return lo < coverage.items.count && coverage.items[lo].startUtf8 == entry.startUtf8 ? coverage.items[lo] : entry
    }

    func releaseCoverage() { coverage = nil; chapterCoverageError = nil }

    func observeCoverage(_ request: UUID) async {
        guard let id = bookID, chapterCoverageRequest == request, !Task.isCancelled, tab == .chapters else { return }

        do {
            try await service.observeChapterCoverage(id) { [weak self] result in
                guard let self, chapterCoverageRequest == request, !Task.isCancelled, tab == .chapters else { return }
                switch result {
                case .success(let value):
                    guard let value else { coverage = nil; chapterCoverageError = nil; return }
                    var structure = value
                    for i in structure.items.indices { structure.items[i].coveredCharacters = nil }
                    if structure == chapterStructure.snapshot?.outline { coverage = value }
                case .failure(let error): chapterCoverageError = ReaderMessages.error(error)
                }
            }
        } catch is CancellationError { }
        catch { if chapterCoverageRequest == request, !Task.isCancelled { chapterCoverageError = ReaderMessages.error(error) } }
    }
    var collapsedVolumes: Set<UInt64> = []
    var chapterComplete: Bool { chapterStructure.snapshot?.outline.isComplete ?? false }
    var chapterTarget: UInt64?
    var chapterTargetCentered = true
    var chapterJumpRevision = 0
    var loadingChapters: Bool { if case .loading = chapterStructure { true } else { false } }
    private struct SearchDraft {
        var query = ""
        var regex = false
        var caseSensitive = false
        var hits: [SearchHit] = []
        var partial = false
        var truncated = false
        var progress = 0.0
        var listPosition: UInt64?
    }
    private struct SearchRequest {
        let id = UUID()
        let book: String
        let query: String
        let regex: Bool
        let sensitive: Bool
    }
    private enum SearchCompletion {
        case editing, completed, cancelled, failed(String)
    }
    private enum SearchPhase {
        case waiting(SearchRequest), searching(SearchRequest), finished(SearchCompletion)

        var completion: SearchCompletion {
            if case .finished(let value) = self { return value }
            return .cancelled
        }
        var requestID: UUID? {
            switch self {
            case .waiting(let request), .searching(let request): request.id
            case .finished: nil
            }
        }
    }
    private enum SearchSessionState {
        case closed(SearchDraft, SearchCompletion)
        case open(SearchDraft, SearchPhase)

        var draft: SearchDraft {
            switch self {
            case .closed(let draft, _), .open(let draft, _): draft
            }
        }
        var completion: SearchCompletion {
            switch self {
            case .closed(_, let result): result
            case .open(_, let phase): phase.completion
            }
        }
    }
    private var searchState = SearchSessionState.closed(.init(), .editing)
    var query: String {
        get { searchState.draft.query }
        set { updateDraft { $0.query = newValue } }
    }
    var regex: Bool {
        get { searchState.draft.regex }
        set { updateDraft { $0.regex = newValue } }
    }
    var caseSensitive: Bool {
        get { searchState.draft.caseSensitive }
        set { updateDraft { $0.caseSensitive = newValue } }
    }
    var searchListPosition: UInt64? {
        get { searchState.draft.listPosition }
        set { updateDraft { $0.listPosition = newValue } }
    }
    var hits: [SearchHit] { searchState.draft.hits }
    var partialSearch: Bool { searchState.draft.partial }
    var truncatedSearch: Bool { searchState.draft.truncated }
    var searchProgress: Double { searchState.draft.progress }
    var searchActive: Bool {
        if case .open = searchState { return true }
        return false
    }
    var searching: Bool {
        if case .open(_, let phase) = searchState { return phase.requestID != nil }
        return false
    }
    var searchFinished: Bool {
        if case .completed = searchState.completion { return true }
        return false
    }
    var searchError: String? {
        if case .failed(let message) = searchState.completion { return message }
        return nil
    }
    private func updateDraft(_ update: (inout SearchDraft) -> Void) {
        var draft = searchState.draft
        update(&draft)
        switch searchState {
        case .closed(_, let completion): searchState = .closed(draft, completion)
        case .open(_, let phase): searchState = .open(draft, phase)
        }
    }
    var noteKind: MarkKind { tab == .bookmarks ? .bookmark : .annotation }

    struct NotePageSnapshot {
        let kind: MarkKind
        var items: [ReaderMark]
        var hasMore: Bool
        var locations: [String: String]
        var candidates: NoteCandidates?
    }
    enum NotesLoad {
        case idle
        case loading(MarkKind, previous: NotePageSnapshot?)
        case ready(NotePageSnapshot)
        case failed(MarkKind, String, previous: NotePageSnapshot?)

        var page: NotePageSnapshot? {
            switch self {
            case .idle: nil
            case .loading(_, let previous), .failed(_, _, let previous): previous
            case .ready(let page): page
            }
        }
        var kind: MarkKind? {
            switch self {
            case .idle: nil
            case .loading(let kind, _), .failed(let kind, _, _): kind
            case .ready(let page): page.kind
            }
        }
    }
    private(set) var notesLoad = NotesLoad.idle
    private enum SelectedMark {
        case candidates(key: String, values: [AnnotationCandidate], admission: DataSessionLease?)
        case blocked(key: String, admission: DataSessionLease?)
        case unavailable
    }
    private enum NoteSelection {
        case inactive
        case active([String: SelectedMark])
    }
    private var noteSelection = NoteSelection.inactive
    var notes: [ReaderMark] { notesLoad.page?.items ?? [] }
    var noteLocations: [String: String] { notesLoad.page?.locations ?? [:] }
    var noteSnapshot: NoteCandidates? { notesLoad.page?.candidates }
    var moreNotes: Bool { notesLoad.page?.hasMore ?? false }
    var loadingNotes: Bool { if case .loading = notesLoad { true } else { false } }
    var notesLoadError: String? { if case .failed(_, let error, _) = notesLoad { error } else { nil } }
    var noteBookID: String? { bookID }
    var selectingNotes: Bool { if case .active = noteSelection { true } else { false } }
    var selectedNotes: Set<String> {
        if case .active(let marks) = noteSelection { Set(marks.keys) } else { [] }
    }

    func beginNoteSelection() {
        if !selectingNotes { noteSelection = .active([:]) }
    }
    func finishNoteSelection() { noteSelection = .inactive }
    func clearNoteSelection() {
        if selectingNotes { noteSelection = .active([:]) }
    }

    /// A retained selection keeps the baseline the user actually selected.
    func updateNoteSelection(_ ids: Set<String>) {
        guard case .active(var marks) = noteSelection else { return }
        marks = marks.filter { ids.contains($0.key) }
        for id in ids where marks[id] == nil {
            if let snapshot = noteSnapshot {
                if snapshot.unknownMarks || snapshot.blocked.contains(id) { marks[id] = .blocked(key: snapshot.key, admission: snapshot.admission) }
                else if let values = snapshot.groups[id] { marks[id] = .candidates(key: snapshot.key, values: values, admission: snapshot.admission) }
                else { marks[id] = .unavailable }
            } else { marks[id] = .unavailable }
        }
        noteSelection = .active(marks)
    }

    func deleteSelectedNotes() async {
        guard !isLeaving, let id = bookID, case .active(let marks) = noteSelection, !marks.isEmpty else { return }
        do {
            guard let key = noteSnapshot?.key else { throw UserDataConflict(candidates: []) }
            var groups: [String: [AnnotationCandidate]] = [:]
            var blocked = Set<String>()
            var selectedAccount: DataSessionLease?
            for (markID, mark) in marks {
                let admission: DataSessionLease?
                switch mark {
                case .candidates(let markKey, let values, let stamp) where markKey == key: groups[markID] = values; admission = stamp
                case .blocked(let markKey, let stamp) where markKey == key: blocked.insert(markID); admission = stamp
                default: throw UserDataConflict(candidates: [])
                }
                guard let admission else { throw UserDataConflict(candidates: []) }
                if let selectedAccount, selectedAccount != admission {
                    throw UserDataConflict(candidates: [])
                }
                selectedAccount = admission
            }
            let ids = Set(marks.keys)
            try await service.deleteNoteSelection(id, expected: NoteCandidates(key: key, groups: groups, blocked: blocked, admission: selectedAccount), ids: ids)
            guard !isLeaving, id == bookID else { return }
            deletedIDs = ids.sorted(); clearNoteSelection()
            await loadNotes(reset: true)
        } catch is UserDataConflict {
            guard !isLeaving, id == bookID else { return }
            clearNoteSelection(); await loadNotes(reset: true)
            error = String(localized: "这些记录已变化，本次未删除，请重新选择。")
        } catch { if !isLeaving, id == bookID { self.error = ReaderMessages.error(error) } }
    }
    var deletedIDs: [String]? {
        didSet {
            guard deletedIDs != oldValue else { return }
            pauseUndoCountdown()
            undoRemaining = .seconds(6)
            resumeUndoCountdown()
        }
    }
    var error: String?
    private var bookID: String?
    private var currentChapter: UInt64 = 0
    private var chapterGeneration = 0
    private var chapterTask: Task<ChapterOutline, Error>?
    private var notesGeneration = 0
    private var job: SearchJob?
    private var searchTask: Task<Void, Never>?
    private let service: AppDataService
    private var isLeaving = false
    private var undoVisible = false
    private var undoRemaining: Duration = .seconds(6)
    private var undoStarted: Duration?
    private let uptime: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var undoTask: Task<Void, Never>?

    init(service: AppDataService = .shared,
         uptime: @escaping @Sendable () -> Duration = { .nanoseconds(Int64(DispatchTime.now().uptimeNanoseconds)) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.service = service; self.uptime = uptime; self.sleep = sleep
        accountChange = MainActorNotifications.observe(.readingContinuationInvalidated, object: service) { [weak self] in
            guard let self else { return }
            cancelChapterLoads()
            chapterStructure = .idle; chapters = []; collapsedVolumes = []
            releaseCoverage()
            chapterAccountRevision = UUID()
        }
    }

    // Count only the time the reader can actually reach the undo capsule.
    // Moving it with the toolbar does not restart its lifetime.
    func setUndoVisible(_ visible: Bool) {
        guard visible != undoVisible else { return }
        pauseUndoCountdown()
        undoVisible = visible
        resumeUndoCountdown()
    }

    private func pauseUndoCountdown() {
        undoTask?.cancel(); undoTask = nil
        if let started = undoStarted {
            undoRemaining = max(.zero, undoRemaining - (uptime() - started))
        }
        undoStarted = nil
    }

    private func resumeUndoCountdown() {
        guard undoVisible, !isLeaving, let ids = deletedIDs else { return }
        undoStarted = uptime()
        let remaining = undoRemaining, wait = sleep
        undoTask = Task { [weak self] in
            do {
                try await wait(remaining)
                try Task.checkCancellation()
                guard let self, self.deletedIDs == ids else { return }
                self.deletedIDs = nil
            } catch { }
        }
    }

    func prepare(bookID: String, currentChapter: UInt64, library: Bool, preservingPosition: Bool = false) async {
        guard !isLeaving else { return }
        let changed = self.bookID != bookID
        if changed {
            cancelSearchJob(); cancelChapterLoads(); self.bookID = bookID
            chapters = []; chapterStructure = .idle; releaseCoverage(); collapsedVolumes = []; chapterFilter = ""
            finishNoteSelection()
            notesGeneration += 1
            notesLoad = .idle
            searchState = searchActive ? .open(.init(), .finished(.editing)) : .closed(.init(), .editing)
        }
        guard library else { return }
        self.currentChapter = currentChapter
        if preservingPosition && !changed {
            await refreshChapters(jumpTo: allChapters.isEmpty ? currentChapter : nil)
            guard !Task.isCancelled, !isLeaving, self.bookID == bookID else { return }
            if tab != .chapters { await loadNotes(reset: true, preservingCount: notes.count) }
            return
        }
        await refreshChapters(jumpTo: currentChapter)
        guard !Task.isCancelled, !isLeaving, self.bookID == bookID else { return }
        if tab != .chapters { await loadNotes(reset: true) }
    }

    /// Chooses the list before it is shown, so its first frame already has the right
    /// title. Rows of the other mark kind are dropped at once; the list waits for its own.
    func select(_ destination: ReaderLibraryTab) {
        if tab != destination { finishNoteSelection() }
        tab = destination
        if destination != .chapters { cancelChapterLoads() }
        guard destination != .chapters, notesLoad.kind != noteKind else { return }
        notesGeneration += 1
        notesLoad = .loading(noteKind, previous: nil)
    }

    /// Editing lists every chapter without changing the reader's folded volumes.
    var chapterSnapshot: [ChapterEntry] { allChapters }

    func containsChapter(_ offset: UInt64) -> Bool { allChapters.contains { $0.startUtf8 == offset } }

    func showChapter(_ offset: UInt64) {
        guard !isLeaving else { return }
        currentChapter = offset
        chapterFilter = ""
        if let parent = allChapters.last(where: { $0.startUtf8 <= offset })?.parentUtf8 {
            collapsedVolumes.remove(parent)
        }
        updateChapterRows()
        jumpToChapter(offset)
    }

    func filterChapters(_ value: String) {
        guard !isLeaving, value != chapterFilter else { return }
        chapterFilter = value
        updateChapterRows()
        if value.isEmpty { showChapter(currentChapter) }
        else { jumpToChapter(nil) }
    }

    func toggleVolume(_ offset: UInt64) {
        if collapsedVolumes.contains(offset) { collapsedVolumes.remove(offset) }
        else { collapsedVolumes.insert(offset) }
        updateChapterRows()
    }

    private func updateChapterRows() {
        if chapterFilter.isEmpty {
            chapters = allChapters.filter { $0.parentUtf8.map { !collapsedVolumes.contains($0) } ?? true }
        } else {
            // Search the entire snapshot, including children of folded volumes.
            chapters = allChapters.filter { $0.title.localizedCaseInsensitiveContains(chapterFilter) }
        }
    }

    private func jumpToChapter(_ offset: UInt64?) {
        chapterTarget = offset.flatMap { target in chapters.last(where: { $0.startUtf8 <= target })?.startUtf8 }
            ?? chapters.first?.startUtf8
        chapterTargetCentered = offset != nil
        chapterJumpRevision += 1
    }

    /// Cancel actual data work when its directory owner goes away. Keep the last
    /// valid snapshot for reopening; cancellation is not a user-facing failure.
    func cancelChapterLoads() {
        chapterGeneration += 1
        chapterTask?.cancel(); chapterTask = nil
        chapterStructure.cancel()
    }

    func refreshChapters(jumpTo offset: UInt64? = nil) async {
        guard !isLeaving, !Task.isCancelled, let id = bookID else { return }
        cancelChapterLoads()
        let generation = chapterGeneration
        let previous = chapterStructure.snapshot
        chapterStructure = .loading(previous: previous)
        // Native list layout must not delay the independent structure read.
        let task = Task.detached(priority: Task.currentPriority) { [service] in
            try await service.chapterStructure(id)
        }
        chapterTask = task
        defer {
            if generation == chapterGeneration {
                chapterStructure.cancel()
                chapterTask = nil
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !isLeaving, !Task.isCancelled, id == bookID, generation == chapterGeneration else { return }
            let current = if let previous, previous.outline == result { previous }
                          else { ChapterStructure(outline: result) }
            if current.version != previous?.version { releaseCoverage() }
            chapterStructure = .ready(current)
            if let offset { showChapter(offset) }
            else if current.version != previous?.version { updateChapterRows() }
        } catch is CancellationError { }
        catch {
            guard !isLeaving, !Task.isCancelled, generation == chapterGeneration else { return }
            let message = ReaderMessages.error(error)
            chapterStructure = .failed(message, previous: previous)
            self.error = message
        }
    }

    func loadNotes(reset: Bool, preservingCount: Int = 0) async {
        guard !isLeaving, let id = bookID, reset || !loadingNotes else { return }
        if reset { notesGeneration += 1 }
        let generation = notesGeneration
        let kind = noteKind
        let previous = notesLoad.page.flatMap { $0.kind == kind ? $0 : nil }
        notesLoad = .loading(kind, previous: previous)
        func current() -> Bool {
            !isLeaving && !Task.isCancelled && id == bookID && kind == noteKind && generation == notesGeneration
        }
        defer {
            if generation == notesGeneration, case .loading(_, let page) = notesLoad {
                notesLoad = page.map(NotesLoad.ready) ?? .idle
            }
        }
        do {
            let snapshot = try await service.noteCandidates(id)
            if !reset, let old = previous?.candidates {
                guard old.key == snapshot.key, let before = old.admission, before == snapshot.admission
                else { throw UserDataConflict(candidates: []) }
            }
            var items: [ReaderMark] = []
            var more = false
            repeat {
                let offset = (reset ? 0 : previous?.items.count ?? 0) + items.count
                let value = try await service.marks(id, kind: kind, offset: UInt32(offset), snapshot: snapshot)
                guard current() else { return }
                items += value.items; more = value.hasMore
                if value.items.isEmpty { break }
            } while reset && more && items.count < preservingCount
            // Appended pages leave displayed rows and their candidate baselines intact.
            var displayedGroups = reset ? [:] : (previous?.candidates?.groups ?? [:])
            for item in items where reset || displayedGroups[item.id] == nil {
                displayedGroups[item.id] = snapshot.groups[item.id]
            }
            let displayed = NoteCandidates(key: snapshot.key, groups: displayedGroups, blocked: snapshot.blocked,
                                           unknownMarks: snapshot.unknownMarks, admission: snapshot.admission)
            var page = NotePageSnapshot(kind: kind, items: reset ? items : (previous?.items ?? []) + items,
                                        hasMore: more, locations: previous?.locations ?? [:], candidates: displayed)
            notesLoad = .loading(kind, previous: page)
            let locations = (try? await service.noteLocations(id, marks: items)) ?? [:]
            guard current() else { return }
            if reset { page.locations = locations } else { page.locations.merge(locations) { _, new in new } }
            notesLoad = .ready(page)
            let valid = Set(snapshot.groups.filter { $0.value.contains { $0.content != nil } }.keys).union(snapshot.blocked)
            if case .active(let marks) = noteSelection {
                noteSelection = .active(marks.filter { valid.contains($0.key) })
            }
        } catch is CancellationError { }
        catch {
            if current() { notesLoad = .failed(kind, ReaderMessages.error(error), previous: notesLoad.page) }
        }
    }

    func refreshVisibleMarks() async {
        guard tab != .chapters else { return }
        await loadNotes(reset: true)
    }

    func delete(_ mark: ReaderMark) async {
        await delete([mark.id])
    }
    func delete(_ ids: [String], expected: NoteCandidates? = nil) async {
        guard !isLeaving, !ids.isEmpty else { return }
        error = nil
        do {
            try await service.deleteMarks(ids, deleted: true, expected: expected ?? noteSnapshot)
            guard !isLeaving else { return }
            deletedIDs = ids; await loadNotes(reset: true)
        }
        catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
    }
    func undoDelete() async {
        guard !isLeaving, let ids = deletedIDs else { return }
        do {
            try await service.deleteMarks(ids, deleted: false)
            guard !isLeaving else { return }
            deletedIDs = nil; await loadNotes(reset: true)
        }
        catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
    }

    func leave() {
        isLeaving = true
        stopSearch()
        cancelChapterLoads()
        notesGeneration += 1
        finishNoteSelection(); notesLoad = .idle
        bookID = nil
        deletedIDs = nil
    }

    func beginSearchSession() {
        if case .closed(let draft, let completion) = searchState { searchState = .open(draft, .finished(completion)) }
    }
    func stopSearch() {
        cancelSearchJob()
        searchState = .closed(searchState.draft, searchState.completion)
    }
    private func cancelSearchJob() {
        job?.cancel(); searchTask?.cancel(); job = nil; searchTask = nil
    }
    private func accepts(_ request: SearchRequest) -> Bool {
        guard case .open(_, let phase) = searchState else { return false }
        return !isLeaving && bookID == request.book && phase.requestID == request.id && !Task.isCancelled
    }
    func startSearch() {
        guard !isLeaving else { return }
        cancelSearchJob()
        var draft = searchState.draft
        draft.hits = []; draft.progress = 0; draft.partial = false; draft.truncated = false; draft.listPosition = nil
        guard let bookID, !draft.query.isEmpty else { searchState = .open(draft, .finished(.editing)); return }
        let request = SearchRequest(book: bookID, query: draft.query, regex: draft.regex, sensitive: draft.caseSensitive)
        searchState = .open(draft, .waiting(request))
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let job = try await service.search(request.book, query: request.query, regex: request.regex, caseSensitive: request.sensitive)
                guard accepts(request) else { job.cancel(); return }
                self.job = job
                searchState = .open(searchState.draft, .searching(request))
                while !Task.isCancelled {
                    let batch = try await Task.detached(priority: .userInitiated) { try job.nextBatch() }.value
                    guard accepts(request) else { return }
                    var draft = searchState.draft
                    draft.hits += batch.hits
                    draft.partial = batch.partialBook
                    draft.truncated = draft.truncated || batch.truncated
                    draft.progress = Double(batch.scannedUtf8) / Double(max(1, batch.availableUtf8))
                    if batch.done || batch.cancelled {
                        searchState = .open(draft, .finished(batch.done ? .completed : .cancelled))
                        return
                    }
                    searchState = .open(draft, .searching(request))
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch is CancellationError { }
            catch {
                if accepts(request) { searchState = .open(searchState.draft, .finished(.failed(ReaderMessages.error(error)))) }
            }
        }
    }
}
