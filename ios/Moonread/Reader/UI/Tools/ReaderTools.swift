import SwiftUI
import UIKit

enum ReaderLibraryTab: Hashable { case chapters, bookmarks, notes }
enum ReaderSelectionAction: Equatable {
    case highlight, comment, paragraph, beginRange, chapter, search, copy, shareExcerpt
    case removeAnnotations
}

/// Both tap and manual selection use the actual selected range. The core
/// resolves the full overlap set when editing or removing annotations.
struct AnnotationSelection {
    let marks: [ReaderMark]
    let start: UInt64
    let end: UInt64
    init(start: UInt64, end: UInt64, annotations: [ReaderMark]) {
        self.start = start; self.end = end
        marks = annotations.filter { $0.startUtf8 < end && $0.endUtf8 > start }
    }
}

extension AnnotationEdit {
    var presentationID: String { "\(id)-\(startUtf8)-\(endUtf8)" }
}

@MainActor @Observable
final class ReaderToolsModel {
    var tab: ReaderLibraryTab = .chapters
    var chapterFilter = ""
    var chapters: [ChapterEntry] = []
    private var allChapters: [ChapterEntry] = []
    private var chapterQuery: ReaderQuery?
    private var coverageQuery: ReaderQuery?
    private(set) var chapterCoverageReady = false
    var collapsedVolumes: Set<UInt64> = []
    var chapterComplete = false
    var chapterTarget: UInt64?
    var chapterTargetCentered = true
    var chapterJumpRevision = 0
    var loadingChapters = false
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
    var notes: [ReaderMark] = []
    var selectingNotes = false
    private(set) var selectedNotes: Set<String> = []
    private(set) var selectedCandidates: [String: [AnnotationCandidate]] = [:]
    var noteLocations: [String: String] = [:]
    var notesLoadError: String?
    var noteSnapshot: NoteCandidates?
    var noteBookID: String? { bookID }
    /// List selection records the candidates the user actually saw. Retained
    /// selections keep their baseline when later pages or remote edits arrive.
    func updateNoteSelection(_ ids: Set<String>) {
        for id in ids.subtracting(selectedNotes) { selectedCandidates[id] = noteSnapshot?.groups[id] }
        selectedCandidates = selectedCandidates.filter { ids.contains($0.key) }
        selectedNotes = ids
    }
    func clearNoteSelection() { updateNoteSelection([]) }
    func deleteSelectedNotes(_ expected: NoteCandidates, ids: Set<String>) async {
        guard let id = bookID else { return }
        do {
            try await service.deleteNoteSelection(id, expected: expected, ids: ids)
            deletedIDs = ids.sorted(); clearNoteSelection()
            await loadNotes(reset: true)
        } catch is UserDataConflict {
            clearNoteSelection(); await loadNotes(reset: true)
            error = String(localized: "这些记录已变化，本次未删除，请重新选择。")
        } catch { self.error = ReaderMessages.error(error) }
    }
    /// The kind `notes` holds; bookmarks and annotations share the list.
    private var notesKind: MarkKind?
    var moreNotes = false
    var loadingNotes = false
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
    private var chapterTask: Task<AppDataService.ChapterResult, Error>?
    private var coverageTask: Task<Void, Never>?
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
            chapters = []; allChapters = []; chapterQuery = nil; coverageQuery = nil; chapterCoverageReady = false; collapsedVolumes = []; chapterFilter = ""
            clearNoteSelection(); selectingNotes = false; noteSnapshot = nil
            notes = []; notesKind = nil; noteLocations = [:]; notesLoadError = nil
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
        if tab != destination { clearNoteSelection(); selectingNotes = false }
        tab = destination
        if destination != .chapters { cancelChapterLoads() }
        guard destination != .chapters, notesKind != noteKind else { return }
        notesGeneration += 1
        notes = []; notesKind = noteKind; moreNotes = false; loadingNotes = true
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
        coverageTask?.cancel(); coverageTask = nil
        loadingChapters = false
    }

    func invalidateChapterCoverage() {
        cancelChapterLoads()
        coverageQuery = nil
        chapterCoverageReady = false
    }

    func refreshChapterStatistics(reset: Bool, presented: Bool) async {
        if reset { invalidateChapterCoverage() }
        guard presented, tab == .chapters else { return }
        await refreshChapters()
    }

    func refreshChapters(jumpTo offset: UInt64? = nil) async {
        guard !isLeaving, !Task.isCancelled, let id = bookID else { return }
        cancelChapterLoads()
        let generation = chapterGeneration, previous = chapterQuery
        loadingChapters = true
        // No MainActor child task before service admission: native List layout
        // must not delay the independent structure read.
        let task = Task.detached(priority: Task.currentPriority) { [service] in
            try await service.chapterStructure(id, reusing: previous)
        }
        chapterTask = task
        defer {
            if generation == chapterGeneration { loadingChapters = false; chapterTask = nil }
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !isLeaving, !Task.isCancelled, id == bookID, generation == chapterGeneration else { return }
            if let value = result.outline {
                allChapters = value.items; chapterComplete = value.isComplete
                coverageQuery = nil; chapterCoverageReady = false
            }
            chapterQuery = result.query
            if let offset { showChapter(offset) } else if result.outline != nil { updateChapterRows() }
            if tab == .chapters { loadChapterCoverage(id, generation: generation) }
        } catch is CancellationError { }
        catch {
            guard !isLeaving, !Task.isCancelled, generation == chapterGeneration else { return }
            self.error = ReaderMessages.error(error)
        }
    }

    private func loadChapterCoverage(_ id: String, generation: Int) {
        let previous = coverageQuery
        coverageTask = Task.detached(priority: Task.currentPriority) { [weak self, service] in
            do {
                let result = try await service.chapters(id, reusing: previous)
                try Task.checkCancellation()
                await self?.publishChapterCoverage(result, id: id, generation: generation)
            } catch is CancellationError { }
            catch { await self?.chapterCoverageFailed(error, generation: generation) }
        }
    }

    private func publishChapterCoverage(_ result: AppDataService.ChapterResult, id: String, generation: Int) {
        guard !isLeaving, id == bookID, generation == chapterGeneration else { return }
        if let value = result.outline {
            allChapters = value.items; chapterComplete = value.isComplete
            updateChapterRows() // Never change filter, folding, target or scroll revision.
        }
        coverageQuery = result.query; chapterCoverageReady = true; coverageTask = nil
    }

    private func chapterCoverageFailed(_ error: Error, generation: Int) {
        guard !isLeaving, generation == chapterGeneration else { return }
        coverageTask = nil; self.error = ReaderMessages.error(error)
    }

    func loadNotes(reset: Bool, preservingCount: Int = 0) async {
        guard !isLeaving, let id = bookID else { return }
        if !reset && loadingNotes { return }
        if reset { notesGeneration += 1 }
        let generation = notesGeneration
        let kind = noteKind
        loadingNotes = true; notesLoadError = nil
        defer { if generation == notesGeneration { loadingNotes = false } }
        do {
            let snapshot = try await service.noteCandidates(id)
            var items: [ReaderMark] = []
            var more = false
            repeat {
                let offset = (reset ? 0 : notes.count) + items.count
                let value = try await service.marks(id, kind: kind, offset: UInt32(offset), snapshot: snapshot)
                guard !isLeaving, !Task.isCancelled, id == bookID, kind == noteKind, generation == notesGeneration else { return }
                items += value.items; more = value.hasMore
                if value.items.isEmpty { break }
            } while reset && more && items.count < preservingCount
            if notesKind != kind { clearNoteSelection(); selectingNotes = false }
            notes = reset ? items : notes + items; notesKind = kind; moreNotes = more
            // Appended pages do not replace the rows already on screen. Keep
            // their candidates too, including rows selected after pagination.
            var displayedGroups = reset ? [:] : (noteSnapshot?.groups ?? [:])
            for item in items where reset || displayedGroups[item.id] == nil {
                displayedGroups[item.id] = snapshot.groups[item.id]
            }
            noteSnapshot = NoteCandidates(key: snapshot.key, groups: displayedGroups, blocked: snapshot.blocked)
            let locations = (try? await service.noteLocations(id, marks: items)) ?? [:]
            guard !isLeaving, id == bookID, kind == noteKind, generation == notesGeneration else { return }
            if reset { noteLocations = locations } else { noteLocations.merge(locations) { _, new in new } }
            let valid = Set(snapshot.groups.filter { $0.value.contains { $0.content != nil } }.keys).union(snapshot.blocked)
            selectedNotes.formIntersection(valid)
            selectedCandidates = selectedCandidates.filter { selectedNotes.contains($0.key) }
            if reset {
                // Only refreshed, displayed rows may advance an existing baseline.
                for item in items where selectedNotes.contains(item.id) {
                    selectedCandidates[item.id] = snapshot.groups[item.id]
                }
            }
        } catch { if !isLeaving { notesLoadError = ReaderMessages.error(error) } }
    }

    func refreshVisibleMarks() async {
        guard tab != .chapters else { return }
        await loadNotes(reset: true)
    }

    func delete(_ mark: ReaderMark) async {
        await delete([mark.id])
    }
    func delete(_ ids: [String]) async {
        guard !isLeaving, !ids.isEmpty else { return }
        error = nil
        do {
            try await service.deleteMarks(ids, deleted: true)
            guard !isLeaving else { return }
            deletedIDs = ids; await loadNotes(reset: true)
        }
        catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
    }
    func removeAnnotations(bookID: String, start: UInt64, end: UInt64) async {
        guard !isLeaving else { return }
        error = nil
        do {
            let ids = try await service.removeAnnotations(bookID, start: start, end: end)
            guard !isLeaving else { return }
            deletedIDs = ids; await loadNotes(reset: true)
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
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
        clearNoteSelection(); selectingNotes = false; noteSnapshot = nil
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
