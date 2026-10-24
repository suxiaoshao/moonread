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

struct ReaderLibrarySheet: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    let close: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @FocusState private var chapterFilterFocused: Bool
    @State private var visibleChapters: Set<UInt64> = []
    @State private var chapterVisibilityKnown = false
    @State private var editingOutline = false
    @State private var chapterEdit: ChapterEditDraft?
    @State private var rebuildingOutline = false
    @State private var restoringOutline = false
    @State private var removedChapter: ChapterEntry?

    private var listTitle: String {
        switch model.tab {
        case .chapters: String(localized: "目录")
        case .bookmarks: String(localized: "书签")
        case .notes: String(localized: "标注与笔记")
        }
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        if model.tab == .chapters {
            // Rare outline repairs stay with the chapters they change.
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(editingOutline ? "结束整理" : "整理目录", systemImage: "pencil") { editingOutline.toggle() }
                    Button("重新识别目录", systemImage: "arrow.clockwise") { rebuildingOutline = true }
                    Button("恢复自动目录", systemImage: "arrow.uturn.backward") { restoringOutline = true }
                } label: {
                    Label("目录操作", systemImage: editingOutline ? "pencil.circle.fill" : "ellipsis")
                }
                .disabled(session.incomplete).toolbarGlyph().accessibilityIdentifier("chapterActions")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("关闭", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly).toolbarGlyph()
                .accessibilityIdentifier("closeReaderLibrary")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch model.tab {
                case .chapters: chapterList
                case .bookmarks, .notes: notesList
                }
            }
            .dismissKeyboardOnOutsideTap($chapterFilterFocused)
            .background(Color(uiColor: theme.surface))
            .navigationTitle(listTitle)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let removed = removedChapter, let id = session.readingID {
                    HStack {
                        Text("已移除目录项").foregroundStyle(Color(uiColor: theme.secondary))
                        Spacer()
                        Button("撤销") {
                            Task {
                                do {
                                    try await ReaderService.shared.correctChapter(id, offset: removed.startUtf8, title: removed.title, level: removed.level)
                                    removedChapter = nil; await refreshOutline()
                                } catch { model.error = ReaderMessages.error(error) }
                            }
                        }.accessibilityIdentifier("undoChapterRemoval")
                    }.padding().background(Color(uiColor: theme.raised))
                }
            }
            .navigationDestination(item: $chapterEdit) { draft in
                if let id = session.readingID { ChapterEditor(bookID: id, draft: draft) { await refreshOutline() } }
            }
            .navigationDestination(isPresented: $rebuildingOutline) {
                if let id = session.readingID { ChapterRebuildView(bookID: id) { await refreshOutline() } }
            }
            .confirmationDialog("恢复自动目录？", isPresented: $restoringOutline, titleVisibility: .visible) {
                Button("清除人工修正", role: .destructive) {
                    guard let id = session.readingID else { return }
                    Task {
                        do { try await ReaderService.shared.restoreChapterCorrections(id); await refreshOutline() }
                        catch { model.error = ReaderMessages.error(error) }
                    }
                }
            } message: { Text("仅清除目录的人工修正，正文、书签和笔记保持不变。") }
            .toolbar { libraryToolbar }
            .task {
                guard let id = session.readingID else { return }
                var available = session.book?.byteCount
                var complete = !session.incomplete
                await session.activity.flush()
                await model.prepare(bookID: id, currentChapter: session.chapter?.startUtf8 ?? 0, library: true)
                // While this sheet is open, publish newly parsed headings/counts
                // without scrolling the reader's current directory viewport.
                while !Task.isCancelled {
                    let next = session.book?.byteCount, done = !session.incomplete
                    if next != available || done != complete {
                        await model.refreshChapters()
                        available = next; complete = done
                    }
                    if done { return }
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                }
            }
            .onDisappear { session.notesChanged() }
            .onChange(of: model.tab) { _, value in
                chapterFilterFocused = false
                if value != .chapters { Task { await model.loadNotes(reset: true) } }
            }
            .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }

    private var chapterList: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                chapterSearchField
                .padding(.horizontal, LayoutTokens.content)
                .padding(.bottom, LayoutTokens.compact)
                if session.incomplete {
                    HStack {
                        Text("目录准备中").foregroundStyle(Color(uiColor: theme.secondary))
                        Button("刷新目录", systemImage: "arrow.clockwise") {
                            Task { await model.refreshChapters() }
                        }.labelStyle(.iconOnly).frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                        Spacer()
                    }
                    .font(.caption).padding(.horizontal, LayoutTokens.content)
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.chapterFilter.isEmpty {
                            Button { navigate(0, nil, .cover) } label: {
                                VStack(spacing: 0) {
                                    HStack(spacing: LayoutTokens.control) {
                                        Image(systemName: "book.closed")
                                        Text("封面")
                                        Spacer()
                                    }.font(.body)
                                        .foregroundStyle(Color(uiColor: session.showingCover ? theme.accent : theme.ink))
                                        .padding(.vertical, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                                    Rectangle().fill(Color(uiColor: theme.separator)).frame(height: 0.5)
                                }
                                .padding(.horizontal, LayoutTokens.content).contentShape(.rect)
                            }.buttonStyle(.plain).id("reader-cover")
                                .accessibilityIdentifier("showBookCover")
                                .accessibilityAddTraits(session.showingCover ? .isSelected : [])
                        }
                        if let first = model.chapters.first, let parent = first.parentUtf8, let title = first.parentTitle {
                            Button { toggleVolume(parent) } label: {
                                HStack { Text(title).font(.headline); Spacer(); Image(systemName: "chevron.down") }
                                    .padding(LayoutTokens.content).frame(minHeight: 44)
                            }.id("parent-\(parent)")
                        }
                        ForEach(model.chapters, id: \.startUtf8) { chapter in
                            chapterRow(chapter).id(chapter.startUtf8)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("chapterList")
                .onScrollTargetVisibilityChange(idType: UInt64.self, threshold: 0.6) { ids in
                    visibleChapters = Set(ids); chapterVisibilityKnown = true
                }
                // Reserved below the list, so the last rows scroll clear of the action.
                .safeAreaInset(edge: .bottom) {
                    if let target = returnTarget {
                        Button {
                            chapterFilterFocused = false
                            // Moves the directory only; reading stays where it is.
                            if model.chapterFilter.isEmpty, model.chapters.contains(where: { $0.startUtf8 == target }) {
                                withAnimation(reduceMotion ? nil : MotionTokens.panel(reduced: false)) { proxy.scrollTo(target, anchor: .center) }
                            } else { model.showChapter(target) }
                        } label: {
                            Label("回到当前章", systemImage: "scope").font(.subheadline.weight(.medium))
                                .padding(.horizontal, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                                .background(Color(uiColor: theme.raised), in: .capsule)
                                .overlay { Capsule().strokeBorder(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
                        }
                        .buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                        .accessibilityIdentifier("returnToCurrentChapter")
                        .padding(.vertical, LayoutTokens.compact)
                    }
                }
                .onChange(of: model.chapterJumpRevision, initial: true) { _, _ in
                    if session.showingCover && model.chapterFilter.isEmpty { proxy.scrollTo("reader-cover", anchor: .top) }
                    else if let target = model.chapterTarget {
                        proxy.scrollTo(target, anchor: model.chapterTargetCentered ? .center : .top)
                    }
                }
                .overlay {
                    if model.chapters.isEmpty {
                        if model.loadingChapters { LoadingActivity(fullPage: true) }
                        else { ThemedEmptyState(title: String(localized: "没有找到章节"), symbol: "list.bullet") }
                    }
                }
            }
        }
    }

    /// The current chapter, when it is a real outline entry hidden by scrolling, a
    /// filter or a folded volume, and the keyboard is not up. The cover needs none.
    private var returnTarget: UInt64? {
        guard !chapterFilterFocused, chapterVisibilityKnown, !session.showingCover,
              let target = session.chapter?.startUtf8, model.containsChapter(target) else { return nil }
        let listed = model.chapters.contains { $0.startUtf8 == target }
        return listed && visibleChapters.contains(target) ? nil : target
    }

    private var chapterSearchField: some View {
        HStack(spacing: LayoutTokens.compact) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary))
            TextField("查找章节", text: Binding(get: { model.chapterFilter }, set: model.filterChapters))
                .textFieldStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($chapterFilterFocused).submitLabel(.search)
                .onSubmit { chapterFilterFocused = false }
                .accessibilityIdentifier("chapterFilter")
            if !model.chapterFilter.isEmpty {
                Button("清除章节搜索", systemImage: "xmark.circle.fill") { model.filterChapters("") }
                    .labelStyle(.iconOnly).foregroundStyle(Color(uiColor: theme.secondary))
                    .frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
            }
        }
        .padding(.leading, LayoutTokens.content).padding(.trailing, 4)
        .frame(minHeight: LayoutTokens.hit)
        .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.inputRadius)
            .strokeBorder(Color(uiColor: chapterFilterFocused ? theme.focus : theme.border), lineWidth: LayoutTokens.border))
        .keyboardInputRegion()
    }

    private func toggleVolume(_ offset: UInt64) { model.toggleVolume(offset) }

    private func refreshOutline() async {
        await session.refreshOutline()
        await model.refreshChapters(jumpTo: session.anchor)
    }

    private func removeChapter(_ chapter: ChapterEntry) {
        guard let id = session.readingID else { return }
        Task {
            do {
                try await ReaderService.shared.correctChapter(id, offset: chapter.startUtf8, title: chapter.title, level: chapter.level, excluded: true)
                removedChapter = chapter; await refreshOutline()
            } catch { model.error = ReaderMessages.error(error) }
        }
    }

    private func chapterRow(_ chapter: ChapterEntry) -> some View {
        let current = !session.showingCover && session.chapter?.startUtf8 == chapter.startUtf8
        let count = chapter.countComplete ? String(localized: "\(chapter.wordCount.formatted()) 字") : String(localized: "\(chapter.wordCount.formatted())+ 字")
        let summary = current ? String(localized: "当前章节，\(count)") : count
        let accessibilitySummary = chapter.level == 0 ? summary : String(localized: "\(summary)，\(chapter.coverageLabel)")
        return Button {
            chapterFilterFocused = false
            if editingOutline { chapterEdit = ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level) }
            else if chapter.level == 0 { toggleVolume(chapter.startUtf8) }
            else { navigate(chapter.startUtf8, nil, .start) }
        } label: {
            VStack(spacing: 0) {
                // Short titles keep their data on the same line; a title that would not fit
                // wraps to two lines with the data beneath, never squeezed by it.
                HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                    if chapter.level == 0 {
                        chapterTitle(chapter, current: current).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: model.collapsedVolumes.contains(chapter.startUtf8) ? "chevron.right" : "chevron.down")
                    } else {
                        let meta = [count, chapter.listCoverageLabel].compactMap { $0 }.joined(separator: " · ")
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline, spacing: LayoutTokens.control) {
                                chapterTitle(chapter, current: current).lineLimit(1).fixedSize()
                                Spacer(minLength: LayoutTokens.control)
                                chapterMeta(meta, current: current).fixedSize()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                chapterTitle(chapter, current: current).lineLimit(2)
                                chapterMeta(meta, current: current)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.leading, chapter.parentUtf8 == nil ? 0 : 12)
                .padding(.vertical, LayoutTokens.content).frame(minHeight: LayoutTokens.hit)
                Rectangle().fill(Color(uiColor: theme.separator)).frame(height: 0.5)
            }
            .padding(.horizontal, LayoutTokens.content).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从这里阅读", systemImage: "book") { navigate(chapter.startUtf8, nil, .start) }
            if !session.incomplete {
                Button("编辑目录项", systemImage: "pencil") { chapterEdit = ChapterEditDraft(start: chapter.startUtf8, title: chapter.title, level: chapter.level) }
                Button("从目录移除", systemImage: "trash", role: .destructive) { removeChapter(chapter) }
            }
        }
        .accessibilityLabel(Text(verbatim: chapter.title))
        .accessibilityValue(accessibilitySummary)
        .accessibilityAddTraits(current ? .isSelected : [])
        .accessibilityIdentifier("chapter-\(chapter.startUtf8)")
    }

    private func chapterTitle(_ chapter: ChapterEntry, current: Bool) -> some View {
        Text(verbatim: chapter.title)
            .font(chapter.level == 0 ? .headline : .body)
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.ink))
    }
    private func chapterMeta(_ text: String, current: Bool) -> some View {
        Text(verbatim: text).font(.caption).monospacedDigit()
            .foregroundStyle(Color(uiColor: current ? theme.accent : theme.secondary))
    }

    private var notesList: some View {
        VStack(spacing: 0) {
            if model.deletedIDs != nil {
                HStack { Text("已删除"); Spacer(); Button("撤销") { Task { await model.undoDelete(); session.notesChanged() } } }
                    .font(.subheadline).padding(.horizontal).padding(.vertical, 8)
            }
            List {
                ForEach(model.notes, id: \.id) { mark in
                    HStack(alignment: .top, spacing: 12) {
                        Button { navigate(mark.startUtf8, mark.kind == .annotation ? mark.endUtf8 : nil,
                                          mark.kind == .annotation ? .context : .start) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: mark.excerpt).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(3)
                                if !mark.note.isEmpty { Text(verbatim: mark.note).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(2) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        if mark.kind == .annotation {
                            Button { edit(mark) } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("编辑批注").accessibilityIdentifier("editNote-\(mark.id)")
                        }
                    }.padding(.vertical, 8)
                        .listRowBackground(Color(uiColor: theme.surface))
                        .listRowSeparatorTint(Color(uiColor: theme.separator))
                        .swipeActions {
                            Button("删除", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(mark); session.notesChanged() }
                            }
                            .labelStyle(.titleAndIcon)
                            .tint(Color(uiColor: theme.destructive))
                        }
                }
                if model.moreNotes { LoadingActivity().task(id: model.notes.count) { await model.loadNotes(reset: false) } }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .overlay {
                    if model.notes.isEmpty && model.loadingNotes {
                        LoadingActivity(fullPage: true, waitingLabel: "正在加载")
                    } else if model.notes.isEmpty && !model.loadingNotes {
                        ThemedEmptyState(title: model.noteKind == .bookmark ? String(localized: "暂无书签") : String(localized: "暂无笔记"), symbol: model.noteKind == .bookmark ? "bookmark" : "square.and.pencil")
                    }
                }
        }
    }

}


struct ReaderSearchContent: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    @Binding var expanded: Bool
    let showsDetails: Bool
    let readyForInput: Bool
    let compactHeight: CGFloat
    let showsHistory: Bool
    let showHistory: () -> Void
    let closeSearch: () -> Void
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @FocusState private var queryFocused: Bool
    private var panelAnimation: Animation { MotionTokens.panel(reduced: reduceMotion) }
    private var activeIndex: Int? {
        guard let range = session.focusRange else { return nil }
        return model.hits.firstIndex { $0.startUtf8 == range.startUtf8 && $0.endUtf8 == range.endUtf8 }
    }

    var body: some View {
        Group {
            if showsDetails { searchDetails }
            else { searchCapsule }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerSearchPanel")
        .dismissKeyboardOnOutsideTap($queryFocused)
        .task(id: readyForInput) {
            guard showsDetails else { return }
            if let id = session.readingID { await model.prepare(bookID: id, currentChapter: 0, library: false) }
            if !Task.isCancelled, readyForInput, expanded, model.query.isEmpty { queryFocused = true }
        }
        .onChange(of: expanded) { _, value in
            if !value { queryFocused = false }
        }
        .onChange(of: model.query) { _, _ in searchChanged() }
        .onChange(of: model.regex) { _, _ in searchChanged() }
        .onChange(of: model.caseSensitive) { _, _ in searchChanged() }
    }

    private var searchDetails: some View {
        VStack(spacing: 0) {
            HStack {
                Button("收起搜索结果", systemImage: "chevron.down", action: collapse)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("collapseSearch")
                Spacer()
                Text("搜索").font(.headline)
                Spacer()
                Button("关闭搜索", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .tint(Color(uiColor: theme.ink))
                    .accessibilityIdentifier("closeSearch")
            }
            .padding(.horizontal, 12).padding(.top, 16)
            searchField.padding(.horizontal, 16).padding(.top, 4)
            if !model.query.isEmpty || model.error != nil {
                searchStatus.padding(.horizontal, 20)
                ThemedDivider().padding(.horizontal, 20)
            }
            searchList
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.secondary)).padding(.trailing, 4)
            TextField("搜索这本书", text: $model.query)
                .textFieldStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityIdentifier("bookSearchQuery")
                .focused($queryFocused)
                .submitLabel(.search)
                .onSubmit {
                    queryFocused = false
                    if !model.searching && !model.searchFinished { model.startSearch() }
                }
            if !model.query.isEmpty {
                Button("清除搜索", systemImage: "xmark.circle.fill") { model.query = ""; queryFocused = true }
                    .labelStyle(.iconOnly).foregroundStyle(Color(uiColor: theme.secondary)).frame(width: 32, height: 44)
            }
            ThemedDivider().frame(height: 22).padding(.horizontal, 3)
            optionButton("正则", value: $model.regex, id: "searchRegex") {
                Text(verbatim: ".*").font(.system(.body, design: .monospaced).weight(.semibold))
            }
            optionButton("区分大小写", value: $model.caseSensitive, id: "searchMatchCase") {
                Text(verbatim: "Aa").font(.system(.body, design: .serif).weight(.semibold))
            }
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 4)
        .background(Color(uiColor: theme.input), in: .rect(cornerRadius: LayoutTokens.inputRadius))
        .overlay(RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).strokeBorder(Color(uiColor: queryFocused ? theme.focus : theme.border), lineWidth: LayoutTokens.border))
        .keyboardInputRegion()
    }

    private func optionButton<Icon: View>(_ title: LocalizedStringKey, value: Binding<Bool>, id: String,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            icon().frame(width: 44, height: 44)
                .foregroundStyle(Color(uiColor: value.wrappedValue ? theme.accent : theme.secondary))
                .background(value.wrappedValue ? Color(uiColor: theme.accentSurface) : .clear, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value.wrappedValue ? Text("开启") : Text("停用"))
        .accessibilityAddTraits(value.wrappedValue ? .isSelected : [])
        .accessibilityIdentifier(id)
    }

    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
            if model.searching {
                LoadingActivity(size: 18, fraction: model.searchProgress, progressLabel: "搜索进度")
            }
            if !model.query.isEmpty { Text("已找到 \(model.hits.count) 处").monospacedDigit() }
            Spacer()
            if !model.query.isEmpty {
                Button(model.searching ? String(localized: "停止") : String(localized: "重新搜索"),
                       systemImage: model.searching ? "stop.fill" : "arrow.clockwise") {
                    if model.searching { model.stopSearch() } else { searchChanged() }
                }
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                .accessibilityIdentifier("refreshSearch")
            }
        }
        .frame(minHeight: 44)
        if model.partialSearch || model.truncatedSearch {
            VStack(alignment: .leading, spacing: 4) {
                if model.partialSearch { Text("搜索范围：已准备的正文") }
                if model.truncatedSearch { Text("部分超长段落未执行正则搜索，其他结果仍可查看。") }
            }.accessibilityIdentifier("searchCoverageNotice")
        }
        if let error = model.error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive)) }
        }.font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).padding(.bottom, 8).accessibilityIdentifier("searchStatus")
    }

    private var searchList: some View {
        let restorePosition = model.searchListPosition
        return ScrollViewReader { proxy in
            List {
                ForEach(model.hits, id: \.startUtf8) { hit in
                    resultRow(hit).id(hit.startUtf8)
                        .onGeometryChange(for: Bool.self) { geometry in
                            let frame = geometry.frame(in: .named("searchResultsViewport"))
                            return frame.minY <= 1 && frame.maxY > 1
                        } action: { atTop in
                            if atTop && expanded { model.searchListPosition = hit.startUtf8 }
                        }
                        // List reads traits on the outer row. Putting them
                        // inside the geometry adapter leaves system backgrounds.
                        .listRowInsets(EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20))
                        .listRowBackground(Color(uiColor: isCurrent(hit) ? theme.selected : theme.surface))
                        .listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: theme.surface))
            .contentMargins(.top, 0)
            .coordinateSpace(name: "searchResultsViewport")
            .onAppear { if let restorePosition { proxy.scrollTo(restorePosition, anchor: .top) } }
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("searchResults")
        .overlay {
            if !model.query.isEmpty && model.hits.isEmpty && !model.searching && model.error == nil {
                ThemedEmptyState(title: searchEmptyTitle, symbol: "magnifyingglass")
            }
        }
    }

    private func isCurrent(_ hit: SearchHit) -> Bool {
        session.focusRange?.startUtf8 == hit.startUtf8 && session.focusRange?.endUtf8 == hit.endUtf8
    }

    private func resultRow(_ hit: SearchHit) -> some View {
        let selected = isCurrent(hit)
        return Button { select(hit) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let chapter = hit.chapter { Text(verbatim: chapter).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)) }
                    Spacer(minLength: 8)
                    if selected { Image(systemName: "location.fill").font(.caption).foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true) }
                }
                Text(searchExcerpt(hit)).font(.body).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(session.navigating)
        .accessibilityIdentifier("searchHit-\(hit.startUtf8)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchCapsule: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { withAnimation(panelAnimation) { expanded = true } } label: {
                    HStack(spacing: 10) {
                        Group {
                            if model.searching {
                                LoadingActivity(size: 18, fraction: model.searchProgress, progressLabel: "搜索进度")
                            } else {
                                Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.accent))
                            }
                        }.frame(width: 44, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.query.isEmpty ? String(localized: "搜索这本书") : model.query)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let index = activeIndex {
                                Text("第 \(index + 1) 处，共 \(model.hits.count) 处")
                                    .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                            } else {
                                Text("已找到 \(model.hits.count) 处").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityLabel("展开搜索结果").accessibilityIdentifier("expandSearch")
                Button("上一个结果", systemImage: "chevron.up") { moveResult(-1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || (activeIndex ?? 0) == 0).accessibilityIdentifier("previousSearchHit")
                Button("下一个结果", systemImage: "chevron.down") { moveResult(1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || model.hits.isEmpty || (activeIndex.map { $0 + 1 >= model.hits.count } ?? false))
                    .accessibilityIdentifier("nextSearchHit")
            }
            if session.browseOrigin != nil {
                ReaderBrowseActions(session: session, showsHistory: showsHistory, showHistory: showHistory, finished: close)
            } else {
                HStack {
                    Spacer()
                    Button("关闭搜索", systemImage: "xmark", action: close)
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                        .tint(Color(uiColor: theme.ink))
                        .accessibilityIdentifier("closeCollapsedSearch")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("searchCapsule")
    }

    private func searchChanged() {
        guard showsDetails else { return }
        session.focusRange = nil
        model.searchListPosition = nil
        model.startSearch()
    }
    private func collapse() {
        queryFocused = false
        withAnimation(panelAnimation) { expanded = false }
    }
    private func close() { queryFocused = false; closeSearch() }
    private func select(_ hit: SearchHit) {
        model.searchListPosition = hit.startUtf8
        session.browse(to: hit.startUtf8, end: hit.endUtf8, bottomObstruction: compactHeight)
        collapse()
    }
    private func moveResult(_ direction: Int) {
        let index = activeIndex.map { $0 + direction } ?? 0
        guard model.hits.indices.contains(index) else { return }
        let hit = model.hits[index]
        model.searchListPosition = hit.startUtf8
        select(hit)
    }

    private func searchExcerpt(_ hit: SearchHit) -> AttributedString {
        let coordinates = TextCoordinates(hit.excerpt)
        let start = coordinates.utf16Offset(atUTF8: Int(hit.highlightStart))
        let end = coordinates.utf16Offset(atUTF8: Int(hit.highlightEnd))
        var value = AttributedString(hit.excerpt)
        value.foregroundColor = Color(uiColor: theme.ink)
        if let lower = AttributedString.Index(String.Index(utf16Offset: start, in: hit.excerpt), within: value),
           let upper = AttributedString.Index(String.Index(utf16Offset: end, in: hit.excerpt), within: value) {
            value[lower..<upper].backgroundColor = Color(uiColor: isCurrent(hit) ? theme.searchCurrent : theme.search)
            value[lower..<upper].font = .body.weight(.semibold)
        }
        return value
    }
    private var searchEmptyTitle: String {
        return model.searchFinished ? String(localized: "没有找到匹配内容") : String(localized: "搜索已停止")
    }

}

@MainActor @Observable
final class NoteEditorModel {
    var edit: AnnotationEdit
    var conflicts: [AnnotationCandidate] = []
    private var conflictBaselines: [String: [AnnotationCandidate]] = [:]
    let service: ReaderService
    var conflictChoice = false
    var loadingConflicts = true
    var deleteChoice = false
    var text: String
    var error: String?
    private var committed = false
    @ObservationIgnored private let aiCommit: AIAnnotationCommitHooks?
    @ObservationIgnored private let onCommitted: (() -> Void)?
    init(edit: AnnotationEdit, service: ReaderService = .shared, onCommitted: (() -> Void)? = nil, aiCommit: AIAnnotationCommitHooks? = nil) {
        self.edit = edit; self.service = service; text = edit.note; self.onCommitted = onCommitted; self.aiCommit = aiCommit
    }
    func loadConflicts() async {
        defer { loadingConflicts = false }
        do {
            let bundle = try await service.annotationEditingBundle(edit)
            let next = (bundle.values.contains(where: AnnotationReduction.conflicts) || edit.baselines.values.contains(where: AnnotationReduction.conflicts))
                ? bundle.values.flatMap { $0 }.filter { $0.mergedInto == nil }.sorted { ($0.created, $0.id) < ($1.created, $1.id) } : []
            if bundle.mapValues({ Set($0.map(\.id)) }) != conflictBaselines.mapValues({ Set($0.map(\.id)) }) {
                conflictChoice = false; deleteChoice = false
            }
            conflictBaselines = bundle
            conflicts = next
            for (id, heads) in bundle where edit.baselines[id] == nil { edit.baselines[id] = heads }
        } catch { self.error = ReaderMessages.error(error) }
    }
    func choose(_ value: AnnotationCandidate) {
        error = nil
        deleteChoice = value.content == nil
        if let content = value.content {
            edit.startUtf8 = content.start; edit.endUtf8 = content.end; edit.excerpt = content.excerpt; text = content.note
        } else { text = "" }
        conflictChoice = true
    }
    func keepBoth() async {
        let contents = conflicts.compactMap(\.content).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard let first = contents.first, let last = contents.map(\.end).max() else { return }
        do {
            edit.startUtf8 = contents.map(\.start).min() ?? first.start; edit.endUtf8 = last
            edit.excerpt = String(try await service.textRange(edit.bookId, start: edit.startUtf8, end: last).text.prefix(160))
            text = contents.map(\.note).filter { !$0.isEmpty }.joined(separator: "\n\n")
            deleteChoice = false; conflictChoice = true
        } catch { self.error = ReaderMessages.error(error) }
    }
    func commit() async -> Bool {
        guard !committed else { return true }
        guard error == nil else { return false }
        var ticket: AIAnnotationCommitTicket?
        defer { if let ticket { aiCommit?.finish(ticket) } }
        do {
            if !conflicts.isEmpty && !conflictChoice { return false }
            ticket = try aiCommit?.begin()
            if !conflicts.isEmpty {
                let content = deleteChoice ? nil : AnnotationContent(start: edit.startUtf8, end: edit.endUtf8, excerpt: edit.excerpt, note: text)
                try await service.resolveAnnotation(edit, expected: conflictBaselines, content: content)
            } else {
                _ = try await service.saveNote(edit, text: text)
                await loadConflicts()
                if !conflicts.isEmpty { return false }
            }
            committed = true; aiCommit?.saved(); onCommitted?(); return true
        } catch {
            await loadConflicts(); self.error = ReaderMessages.error(error); return false
        }
    }
}

struct NoteEditor: View {
    @Environment(\.theme) private var theme
    @State private var model: NoteEditorModel
    @State private var saving = false
    let close: () -> Void
    init(edit: AnnotationEdit, onCommitted: (() -> Void)? = nil, aiCommit: AIAnnotationCommitHooks? = nil, close: @escaping () -> Void) {
        _model = State(initialValue: NoteEditorModel(edit: edit, onCommitted: onCommitted, aiCommit: aiCommit))
        self.close = close
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.conflicts.isEmpty && model.conflictChoice {
                    HStack {
                        Text(model.deleteChoice ? "已选择删除，完成后移除批注" : "已选定结果，可继续编辑").font(.callout)
                        Spacer()
                        Button("重新选择") { model.conflictChoice = false; model.deleteChoice = false }
                    }.padding()
                } else if !model.conflicts.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LayoutTokens.control) {
                            Text("批注存在并发修改").font(.headline)
                            // Each version carries its own choice; nothing depends on card order.
                            ForEach(model.conflicts) { candidate in
                                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                                    if let content = candidate.content {
                                        Text(verbatim: content.excerpt).font(.callout).foregroundStyle(Color(uiColor: theme.secondary))
                                        Text(verbatim: content.note.isEmpty ? String(localized: "仅高亮") : content.note)
                                    } else { Text("删除这条批注") }
                                    Button("使用这一版") { model.choose(candidate) }
                                        .buttonStyle(.bordered).tint(Color(uiColor: theme.accent))
                                        // The scope's ink foreground would otherwise override the tinted label.
                                        .foregroundStyle(Color(uiColor: theme.accent))
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                        .accessibilityIdentifier(candidate.content == nil ? "chooseAnnotationDeletion" : "chooseAnnotation-\(candidate.id)")
                                }.padding(LayoutTokens.control).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 8))
                                    .accessibilityElement(children: .contain)
                            }
                            Button { Task { await model.keepBoth() } } label: { Text("保留两者").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).tint(Color(uiColor: theme.ink))
                            Text("选择范围后，可在下方手动编辑最终评论。").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                        }.padding()
                    }.frame(maxHeight: 300)
                }
                if model.deleteChoice && model.conflictChoice {
                    Text("已选择删除，完成后移除批注").foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("noteDeletionState")
                } else {
                    NoteEditorForm(model: model, enabled: !saving, text: model.text, excerpt: model.edit.excerpt, focus: !model.loadingConflicts && (model.conflicts.isEmpty || model.conflictChoice))
                }
            }
                // UIKit owns keyboard avoidance for this form. There must not
                // be a second SwiftUI resize while the sheet is closing.
                .ignoresSafeArea(.keyboard)
            .navigationTitle("批注").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { close() }
                        .labelStyle(.titleOnly)
                        .disabled(saving).accessibilityIdentifier("closeNote")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { finish() }
                        .labelStyle(.titleOnly)
                        .disabled(saving || (!model.conflicts.isEmpty && !model.conflictChoice)).accessibilityIdentifier("saveNote")
                }
            }
            .task { await model.loadConflicts() }
            .onReceive(NotificationCenter.default.publisher(for: .cloudDataReceived).receive(on: DispatchQueue.main)) { _ in Task { await model.loadConflicts() } }
            .onChange(of: model.text) { _, _ in model.error = nil }
            .interactiveDismissDisabled(saving)
            .alert("暂时无法保存", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
        }
    }
    private func finish() {
        guard !saving else { return }
        saving = true
        Task {
            if await model.commit() {
                close()
            }
            saving = false
        }
    }
}

private struct NoteEditorForm: UIViewControllerRepresentable {
    @Environment(\.theme) private var theme
    let model: NoteEditorModel
    let enabled: Bool
    let text: String
    let excerpt: String
    let focus: Bool

    func makeUIViewController(context: Context) -> NoteEditorFormController {
        NoteEditorFormController(model: model)
    }

    func updateUIViewController(_ controller: NoteEditorFormController, context: Context) {
        controller.editingEnabled = enabled
        controller.applyTheme(theme)
        controller.applyContent(text: text, excerpt: excerpt)
        controller.shouldFocus = focus
    }
}

/// One native scroll view owns the keyboard and a content-sized input. Empty
/// space below a short note belongs to the form, not an invisible tall editor.
@MainActor
private final class NoteEditorFormController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    private let model: NoteEditorModel
    private let scroll = UIScrollView()
    private let input = UITextView()
    private let excerpt = UILabel()
    private let quote = UIView()
    private var theme = ThemeSurface.initial
    private var initiallyFocused = false
    private var appeared = false
    var shouldFocus = false {
        didSet {
            if !shouldFocus && isViewLoaded { input.resignFirstResponder(); initiallyFocused = false }
            else if appeared { focusInitially() }
        }
    }
    var editingEnabled = true

    init(model: NoteEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = theme.surface
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "noteEditorScroll"
        view.addSubview(scroll)

        excerpt.text = model.edit.excerpt
        excerpt.numberOfLines = 0
        excerpt.font = .preferredFont(forTextStyle: .subheadline)
        excerpt.adjustsFontForContentSizeCategory = true
        excerpt.textColor = theme.secondary
        excerpt.accessibilityIdentifier = "noteExcerpt"
        excerpt.translatesAutoresizingMaskIntoConstraints = false
        quote.backgroundColor = theme.raised
        quote.layer.cornerRadius = LayoutTokens.inputRadius
        quote.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        quote.addSubview(excerpt)

        input.text = model.text
        input.font = .preferredFont(forTextStyle: .body)
        input.adjustsFontForContentSizeCategory = true
        input.backgroundColor = theme.input
        input.textContainerInset = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        input.textContainer.lineFragmentPadding = 0
        input.layer.cornerRadius = LayoutTokens.inputRadius
        input.layer.cornerCurve = .continuous
        input.layer.borderWidth = LayoutTokens.border
        input.isScrollEnabled = false
        input.delegate = self
        input.accessibilityLabel = String(localized: "批注内容")
        input.accessibilityIdentifier = "noteEditorText"

        let content = UIStackView(arrangedSubviews: [quote, input])
        content.axis = .vertical
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            excerpt.topAnchor.constraint(equalTo: quote.layoutMarginsGuide.topAnchor),
            excerpt.leadingAnchor.constraint(equalTo: quote.layoutMarginsGuide.leadingAnchor),
            excerpt.trailingAnchor.constraint(equalTo: quote.layoutMarginsGuide.trailingAnchor),
            excerpt.bottomAnchor.constraint(equalTo: quote.layoutMarginsGuide.bottomAnchor),
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 104)
        ])

        applyTheme(theme)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (controller: NoteEditorFormController, _: UITraitCollection) in
            controller.updateInputBorder()
        }

        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = self
        view.addGestureRecognizer(outsideTap)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        // SwiftUI can forward a child's appearance before its sheet transition
        // finishes. Focus after that transition's own responder restoration.
        if let coordinator = transitionCoordinator,
           coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
               if !context.isCancelled { self?.focusInitially() }
           }) { return }
        focusInitially()
    }

    private func focusInitially() {
        guard shouldFocus, !initiallyFocused else { return }
        initiallyFocused = input.becomeFirstResponder()
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard editingEnabled, input.isFirstResponder else { return false }
        // Native cursor placement, text selection and its handles keep their taps.
        return touch.view !== input && touch.view?.isDescendant(of: input) != true
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        editingEnabled
    }

    private func updateInputBorder() {
        let color = input.isFirstResponder ? theme.focus : theme.border
        input.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    func applyContent(text: String, excerpt: String) {
        guard isViewLoaded else { return }
        self.excerpt.text = excerpt
        if input.text != text {
            input.text = text
            input.selectedRange = NSRange(location: (text as NSString).length, length: 0)
            input.invalidateIntrinsicContentSize()
        }
    }

    func applyTheme(_ value: ThemeSurface) {
        theme = value
        overrideUserInterfaceStyle = value.style
        guard isViewLoaded else { return }
        view.backgroundColor = value.surface
        quote.backgroundColor = value.raised
        excerpt.textColor = value.secondary
        input.backgroundColor = value.input
        input.textColor = value.ink
        input.tintColor = value.selection
        updateInputBorder()
    }

    func textViewDidBeginEditing(_ textView: UITextView) { updateInputBorder() }
    func textViewDidEndEditing(_ textView: UITextView) { updateInputBorder() }

    func textViewDidChange(_ textView: UITextView) {
        model.text = textView.text
        input.invalidateIntrinsicContentSize()
        view.layoutIfNeeded()
        let caret = input.caretRect(for: input.selectedTextRange?.end ?? input.endOfDocument)
        scroll.scrollRectToVisible(input.convert(caret.insetBy(dx: 0, dy: -12), to: scroll), animated: false)
    }
}
