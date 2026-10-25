import SwiftUI
import UIKit

enum ReaderPanel: String { case library, search, settings, history, chapterEditor, details, ai }
extension ReaderPanel { var isPage: Bool { self == .settings || self == .details } }
enum ReaderLibraryTab: Hashable { case chapters, bookmarks, notes }
enum ReaderSelectionAction: Equatable {
    case highlight, comment, paragraph, beginRange, chapter, search, copy
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
    var searching = false
    var partialSearch = false
    var searchFinished = false
    var truncatedSearch = false
    var searchProgress: Double = 0
    var searchListPosition: UInt64?
    var noteKind: MarkKind { tab == .bookmarks ? .bookmark : .annotation }
    var notes: [ReaderMark] = []
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
    private var notesGeneration = 0
    private var searchGeneration = 0
    private var job: SearchJob?
    private var searchTask: Task<Void, Never>?
    private let service: ReaderService
    private var isLeaving = false
    private var undoVisible = false
    private var undoRemaining: Duration = .seconds(6)
    private var undoStarted: Duration?
    private let uptime: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var undoTask: Task<Void, Never>?

    init(service: ReaderService = .shared,
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

    func prepare(bookID: String, currentChapter: UInt64, library: Bool) async {
        guard !isLeaving else { return }
        let changed = self.bookID != bookID
        if changed {
            stopSearch(); self.bookID = bookID
            chapters = []; allChapters = []; collapsedVolumes = []; chapterFilter = ""
            notes = []; notesKind = nil; hits = []; query = ""
        }
        guard library else { return }
        self.currentChapter = currentChapter
        await refreshChapters(jumpTo: currentChapter)
        await loadNotes(reset: true)
    }

    /// Chooses the list before it is shown, so its first frame already has the right
    /// title. Rows of the other mark kind are dropped at once; the list waits for its own.
    func select(_ destination: ReaderLibraryTab) {
        tab = destination
        guard destination != .chapters, notesKind != noteKind else { return }
        notesGeneration += 1
        notes = []; notesKind = noteKind; moreNotes = false; loadingNotes = true
    }

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
        jumpToChapter(offset)
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
        guard !isLeaving, let id = bookID else { return }
        chapterGeneration += 1
        let generation = chapterGeneration
        loadingChapters = true
        defer { if generation == chapterGeneration { loadingChapters = false } }
        do {
            let value = try await service.chapters(id)
            guard !isLeaving, !Task.isCancelled, id == bookID, generation == chapterGeneration else { return }
            allChapters = value.items
            chapterComplete = value.isComplete
            if let offset { showChapter(offset) }
            else { updateChapterRows() }
        } catch { if !Task.isCancelled && generation == chapterGeneration { self.error = ReaderMessages.error(error) } }
    }

    func loadNotes(reset: Bool) async {
        guard !isLeaving, let id = bookID else { return }
        if !reset && loadingNotes { return }
        if reset { notesGeneration += 1 }
        let generation = notesGeneration
        let kind = noteKind
        loadingNotes = true
        defer { if generation == notesGeneration { loadingNotes = false } }
        do {
            let value = try await service.marks(id, kind: kind, offset: reset ? 0 : UInt32(notes.count))
            guard id == bookID, kind == noteKind, generation == notesGeneration else { return }
            notes = reset ? value.items : notes + value.items; notesKind = kind; moreNotes = value.hasMore
        } catch { if !isLeaving { self.error = ReaderMessages.error(error) } }
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
        chapterGeneration += 1; notesGeneration += 1
        bookID = nil
        deletedIDs = nil
    }

    func stopSearch() {
        searchGeneration += 1
        job?.cancel(); searchTask?.cancel(); job = nil; searchTask = nil; searching = false
    }
    func startSearch() {
        guard !isLeaving else { return }
        stopSearch()
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
