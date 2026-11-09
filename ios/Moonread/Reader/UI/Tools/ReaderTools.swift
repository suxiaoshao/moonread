import SwiftUI
import UIKit

enum ReaderPanel: String { case library, search, settings, history, chapterEditor, details, ai }
extension ReaderPanel { var isPage: Bool { self == .settings || self == .details } }
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
    var collapsedVolumes: Set<UInt64> = []
    var chapterComplete = false
    var chapterTarget: UInt64?
    var chapterTargetCentered = true
    var chapterJumpRevision = 0
    var loadingChapters = false
    var query = ""
    var regex = false
    var caseSensitive = false
    var hits: [SearchHit] = []
    private(set) var searchActive = false
    var searching = false
    var partialSearch = false
    var searchFinished = false
    var truncatedSearch = false
    var searchProgress: Double = 0
    var searchListPosition: UInt64?
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
    private var chapterTask: Task<Void, Never>?
    private var notesGeneration = 0
    private var searchGeneration = 0
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
            cancelSearchJob(); chapterTask?.cancel(); chapterTask = nil; chapterGeneration += 1; loadingChapters = false; self.bookID = bookID
            chapters = []; allChapters = []; chapterQuery = nil; collapsedVolumes = []; chapterFilter = ""
            clearNoteSelection(); selectingNotes = false; noteSnapshot = nil
            notes = []; notesKind = nil; noteLocations = [:]; notesLoadError = nil; hits = []; query = ""
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

    func refreshChapters(jumpTo offset: UInt64? = nil) async {
        guard !isLeaving, !Task.isCancelled, let id = bookID else { return }
        chapterTask?.cancel(); chapterGeneration += 1
        let generation = chapterGeneration
        loadingChapters = true
        let task = Task { [weak self, service] in
            defer { if let self, generation == self.chapterGeneration { self.loadingChapters = false; self.chapterTask = nil } }
            do {
                let result = try await service.chapters(id, reusing: self?.chapterQuery)
                guard let self, !self.isLeaving, !Task.isCancelled, id == self.bookID, generation == self.chapterGeneration else { return }
                if let value = result.outline {
                    self.allChapters = value.items; self.chapterComplete = value.isComplete
                }
                self.chapterQuery = result.query
                if let offset { self.showChapter(offset) } else { self.updateChapterRows() }
            } catch is CancellationError { }
            catch {
                guard let self, !self.isLeaving, !Task.isCancelled, generation == self.chapterGeneration else { return }
                self.error = ReaderMessages.error(error)
            }
        }
        chapterTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
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
        chapterTask?.cancel(); chapterTask = nil
        chapterGeneration += 1; notesGeneration += 1; loadingChapters = false
        clearNoteSelection(); selectingNotes = false; noteSnapshot = nil
        bookID = nil
        deletedIDs = nil
    }

    func beginSearchSession() { searchActive = true }
    func stopSearch() { searchActive = false; cancelSearchJob() }
    private func cancelSearchJob() {
        searchGeneration += 1
        job?.cancel(); searchTask?.cancel(); job = nil; searchTask = nil; searching = false
    }
    func startSearch() {
        guard !isLeaving else { return }
        cancelSearchJob()
        searchActive = true
        guard let id = bookID else { return }
        hits = []; error = nil; searchFinished = false; truncatedSearch = false; partialSearch = false; searchProgress = 0
        searchListPosition = nil
        guard !query.isEmpty else { return }
        let generation = searchGeneration
        let query = query; let regex = regex; let sensitive = caseSensitive
        searching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let job = try await service.search(id, query: query, regex: regex, caseSensitive: sensitive)
                guard generation == searchGeneration, !Task.isCancelled else { job.cancel(); return }
                self.job = job
                while !Task.isCancelled {
                    let batch = try await Task.detached(priority: .userInitiated) { try job.nextBatch() }.value
                    guard generation == searchGeneration, !Task.isCancelled else { return }
                    hits += batch.hits
                    partialSearch = batch.partialBook
                    truncatedSearch = truncatedSearch || batch.truncated
                    searchProgress = Double(batch.scannedUtf8) / Double(max(1, batch.availableUtf8))
                    if batch.done || batch.cancelled {
                        searchFinished = batch.done; searching = false; return
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } catch is CancellationError { }
            catch { if generation == searchGeneration { searching = false; self.error = ReaderMessages.error(error) } }
        }
    }
}
