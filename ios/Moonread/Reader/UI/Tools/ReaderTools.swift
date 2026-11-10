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
    private struct ChapterStructure {
        let version = UUID()
        let query: ReaderQuery
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
    private struct ChapterCoverage {
        let query: ReaderQuery
        let outline: ChapterOutline
    }
    private enum CoverageLoad {
        case notRequested
        case loading(UUID, previous: ChapterCoverage?)
        case ready(UUID, ChapterCoverage)
        case failed(UUID, String, previous: ChapterCoverage?)

        func snapshot(for version: UUID) -> ChapterCoverage? {
            switch self {
            case .loading(let id, let snapshot) where id == version: snapshot
            case .failed(let id, _, let snapshot) where id == version: snapshot
            case .ready(let id, let snapshot) where id == version: snapshot
            default: nil
            }
        }
        mutating func cancel() {
            guard case .loading(let version, let previous) = self else { return }
            self = previous.map { .ready(version, $0) } ?? .notRequested
        }
    }
    private struct DirectoryState {
        var structure = StructureLoad.idle
        var coverage = CoverageLoad.notRequested
        var currentCoverage: ChapterCoverage? {
            structure.snapshot.flatMap { coverage.snapshot(for: $0.version) }
        }
    }
    private var directory = DirectoryState()
    private var allChapters: [ChapterEntry] {
        directory.currentCoverage?.outline.items ?? directory.structure.snapshot?.outline.items ?? []
    }
    var chapterCoverageReady: Bool { directory.currentCoverage != nil }
    var collapsedVolumes: Set<UInt64> = []
    var chapterComplete: Bool { directory.structure.snapshot?.outline.isComplete ?? false }
    var chapterTarget: UInt64?
    var chapterTargetCentered = true
    var chapterJumpRevision = 0
    var loadingChapters: Bool { if case .loading = directory.structure { true } else { false } }
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
        case candidates(key: String, values: [AnnotationCandidate])
        case blocked(key: String)
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
                if snapshot.blocked.contains(id) { marks[id] = .blocked(key: snapshot.key) }
                else if let values = snapshot.groups[id] { marks[id] = .candidates(key: snapshot.key, values: values) }
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
            for (markID, mark) in marks {
                switch mark {
                case .candidates(let markKey, let values) where markKey == key: groups[markID] = values
                case .blocked(let markKey) where markKey == key: blocked.insert(markID)
                default: throw UserDataConflict(candidates: [])
                }
            }
            let ids = Set(marks.keys)
            try await service.deleteNoteSelection(id, expected: NoteCandidates(key: key, groups: groups, blocked: blocked), ids: ids)
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
    private var chapterTask: Task<QueryRefresh<ChapterOutline>, Error>?
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
            chapters = []; directory = DirectoryState(); collapsedVolumes = []; chapterFilter = ""
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
        coverageTask?.cancel(); coverageTask = nil
        directory.structure.cancel()
        directory.coverage.cancel()
    }

    func invalidateChapterCoverage() {
        cancelChapterLoads()
        directory.coverage = .notRequested
        updateChapterRows()
    }

    func refreshChapterStatistics(reset: Bool, presented: Bool) async {
        if reset { invalidateChapterCoverage() }
        guard presented, tab == .chapters else { return }
        await refreshChapters()
    }

    func refreshChapters(jumpTo offset: UInt64? = nil) async {
        guard !isLeaving, !Task.isCancelled, let id = bookID else { return }
        cancelChapterLoads()
        let generation = chapterGeneration
        let previous = directory.structure.snapshot
        directory.structure = .loading(previous: previous)
        // Native list layout must not delay the independent structure read.
        let task = Task.detached(priority: Task.currentPriority) { [service] in
            try await service.chapterStructure(id, reusing: previous?.query)
        }
        chapterTask = task
        defer {
            if generation == chapterGeneration {
                directory.structure.cancel()
                chapterTask = nil
            }
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !isLeaving, !Task.isCancelled, id == bookID, generation == chapterGeneration else { return }
            let current: ChapterStructure
            switch result {
            case .unchanged:
                guard let previous else { return }
                current = previous
            case .replaced(let query, let outline):
                current = ChapterStructure(query: query, outline: outline)
                directory.coverage = .notRequested
            }
            directory.structure = .ready(current)
            if let offset { showChapter(offset) }
            else if current.version != previous?.version { updateChapterRows() }
            if tab == .chapters { loadChapterCoverage(id, generation: generation, structureVersion: current.version) }
        } catch is CancellationError { }
        catch {
            guard !isLeaving, !Task.isCancelled, generation == chapterGeneration else { return }
            let message = ReaderMessages.error(error)
            directory.structure = .failed(message, previous: previous)
            self.error = message
        }
    }

    private func loadChapterCoverage(_ id: String, generation: Int, structureVersion: UUID) {
        let previous = directory.coverage.snapshot(for: structureVersion)
        directory.coverage = .loading(structureVersion, previous: previous)
        coverageTask = Task.detached(priority: Task.currentPriority) { [weak self, service] in
            do {
                let result = try await service.chapters(id, reusing: previous?.query)
                try Task.checkCancellation()
                await self?.publishChapterCoverage(result, id: id, generation: generation, structureVersion: structureVersion)
            } catch is CancellationError { }
            catch { await self?.chapterCoverageFailed(error, generation: generation, structureVersion: structureVersion) }
        }
    }

    private func publishChapterCoverage(_ result: QueryRefresh<ChapterOutline>, id: String, generation: Int, structureVersion: UUID) {
        guard !isLeaving, id == bookID, generation == chapterGeneration,
              let structure = directory.structure.snapshot, structure.version == structureVersion,
              case .loading(let version, let previous) = directory.coverage, version == structureVersion else { return }
        coverageTask = nil
        switch result {
        case .unchanged:
            directory.coverage = previous.map { .ready(version, $0) } ?? .notRequested
        case .replaced(let query, let outline):
            // A structure change between requests must go through the structure owner.
            guard structure.outline.isComplete == outline.isComplete,
                  structure.outline.items.count == outline.items.count,
                  zip(structure.outline.items, outline.items).allSatisfy({ a, b in
                      a.startUtf8 == b.startUtf8 && a.title == b.title && a.level == b.level && a.parentUtf8 == b.parentUtf8
                  }) else {
                directory.coverage = .notRequested
                updateChapterRows()
                return
            }
            directory.coverage = .ready(version, ChapterCoverage(query: query, outline: outline))
            updateChapterRows() // Keep filter, folding, target and scroll revision.
        }
    }

    private func chapterCoverageFailed(_ error: Error, generation: Int, structureVersion: UUID) {
        guard !isLeaving, generation == chapterGeneration,
              directory.structure.snapshot?.version == structureVersion else { return }
        let message = ReaderMessages.error(error)
        directory.coverage = .failed(structureVersion, message, previous: directory.coverage.snapshot(for: structureVersion))
        coverageTask = nil; self.error = message
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
            let displayed = NoteCandidates(key: snapshot.key, groups: displayedGroups, blocked: snapshot.blocked)
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
