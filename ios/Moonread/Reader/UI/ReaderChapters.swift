import SwiftUI

@MainActor @Observable final class ChapterEditDraft: Identifiable, Hashable {
    nonisolated let id = UUID()
    let start: UInt64
    var title: String
    var level: UInt32
    var saving = false
    var error: String?
    init(start: UInt64, title: String, level: UInt32) { self.start = start; self.title = title; self.level = level }
    nonisolated static func == (lhs: ChapterEditDraft, rhs: ChapterEditDraft) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChapterEditor: View {
    let bookID: String
    @Bindable var draft: ChapterEditDraft
    let saved: () async -> Void
    let finished: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    init(bookID: String, draft: ChapterEditDraft, saved: @escaping () async -> Void, finished: (() -> Void)? = nil) {
        self.bookID = bookID; self.draft = draft; self.saved = saved; self.finished = finished
    }
    var body: some View {
        Form {
            Section {
                TextField("章节名称", text: $draft.title, axis: .vertical).focused($focused)
                    .keyboardInputRegion().accessibilityIdentifier("chapterEditTitle")
                Picker("层级", selection: $draft.level) {
                    Text("章").tag(UInt32(1)); Text("卷").tag(UInt32(0))
                }.pickerStyle(.segmented).accessibilityIdentifier("chapterEditLevel")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .themedPage().dismissKeyboardOnOutsideTap($focused)
        .navigationTitle("编辑目录项").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("保存", systemImage: "checkmark") { save() }.labelStyle(.titleOnly)
                .disabled(draft.saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveChapterEdit")
        } }
        .onAppear { focused = true }
        .alert("暂时无法完成", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) {
            Button("知道了", role: .cancel) { draft.error = nil }
        } message: { Text(draft.error ?? "") }
    }
    private func save() {
        guard !draft.saving else { return }; draft.saving = true
        Task {
            defer { draft.saving = false }
            do {
                try await AppDataService.shared.correctChapter(bookID, offset: draft.start, title: draft.title, level: draft.level)
                focused = false; await saved(); if let finished { finished() } else { dismiss() }
            } catch { draft.error = ReaderMessages.error(error) }
        }
    }
}

@MainActor @Observable final class ChapterRebuildModel {
    let bookID: String
    private(set) var job: ChapterRebuild?
    var progress: ChapterRebuildProgress?
    var headings: [ChapterInfo] = []
    var hasMore: Bool { headings.count < Int(progress?.count ?? 0) }
    var loadingMore = false
    var applying = false
    private(set) var invalid = false
    #if DEBUG
    @ObservationIgnored private var fixtureApplyFailure = true
    #endif
    var rebuildError: String?
    var actionError: String?
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    private var started = false
    var canApply: Bool { job != nil && progress?.done == true && progress?.cancelled != true && !invalid && !applying && !loadingMore }
    @ObservationIgnored private let start: @MainActor (String) async throws -> ChapterRebuild
    @ObservationIgnored private let advance: @MainActor (ChapterRebuild) async throws -> ChapterRebuildProgress
    @ObservationIgnored private let preview: @MainActor (ChapterRebuild, UInt64) async throws -> [ChapterInfo]
    @ObservationIgnored private let commit: @MainActor (ChapterRebuild) async throws -> Void
    init(bookID: String, reader: AppDataService = .shared,
         start: (@MainActor (String) async throws -> ChapterRebuild)? = nil,
         advance: (@MainActor (ChapterRebuild) async throws -> ChapterRebuildProgress)? = nil,
         preview: (@MainActor (ChapterRebuild, UInt64) async throws -> [ChapterInfo])? = nil,
         commit: (@MainActor (ChapterRebuild) async throws -> Void)? = nil) {
        self.bookID = bookID
        self.start = start ?? { try await reader.rebuildChapters($0) }
        self.advance = advance ?? { try await reader.advanceRebuild($0) }
        self.preview = preview ?? { try await reader.rebuildPreview($0, from: $1) }
        self.commit = commit ?? { try await reader.applyRebuild($0) }
    }
    func load() async {
        guard !started, !invalid else { return }
        started = true
        do {
            let value = try await start(bookID)
            guard !invalid, !Task.isCancelled else { value.cancel(); return }
            job = value
            while !Task.isCancelled {
                let result = try await advance(value)
                guard !Task.isCancelled else { cancel(); return }
                progress = result
                if result.cancelled { invalid = true; return }
                if result.done { await loadMore(); return }
                try await Task.sleep(for: .milliseconds(15))
            }
            cancel()
        } catch is CancellationError { cancel() }
        catch { invalid = true; rebuildError = ReaderMessages.error(error) }
    }
    func startIfNeeded() {
        guard loadingTask == nil, !started, !invalid else { return }
        loadingTask = Task { await load() }
    }
    func cancel() { invalid = true; loadingTask?.cancel(); loadingTask = nil; job?.cancel() }
    func loadMore() async {
        guard let job, !loadingMore, !invalid else { return }
        loadingMore = true; actionError = nil; defer { loadingMore = false }
        do {
            let rows = try await preview(job, headings.last.map { $0.startUtf8 + 1 } ?? 0)
            headings += rows
        } catch { actionError = ReaderMessages.error(error) }
    }
    func apply() async -> Bool {
        guard canApply, let job else { return false }
        applying = true; actionError = nil; defer { applying = false }
        do {
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if fixtureApplyFailure && args.contains("--ui-testing") && args.contains("--ui-test-session") && args.contains("--ui-test-chapter-preview-error") {
                fixtureApplyFailure = false; throw CocoaError(.fileWriteUnknown)
            }
            #endif
            try await commit(job); return true
        }
        catch {
            if let error = error as? ReaderError, [.Paused, .SourceChanged, .NotFound].contains(error) { invalid = true }
            actionError = ReaderMessages.error(error); return false
        }
    }
}

struct ChapterRebuildView: View {
    let applied: () async -> Void
    let finished: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var model: ChapterRebuildModel
    init(model: ChapterRebuildModel, applied: @escaping () async -> Void, finished: (() -> Void)? = nil) {
        self.model = model; self.applied = applied; self.finished = finished
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if model.progress?.done != true && model.rebuildError == nil { LoadingActivity(size: 28, fraction: model.progress?.fraction) }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.rebuildError != nil ? "识别未完成" : (model.progress?.done == true ? "识别完成" : "正在识别目录")).font(.headline)
                            Text("已识别 \(Int(model.progress?.count ?? 0)) 章").monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                        }
                        Spacer()
                    }
                    if let error = model.rebuildError ?? model.actionError {
                        Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)).accessibilityIdentifier("chapterRebuildError")
                    }
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                ForEach(model.headings, id: \.startUtf8) { heading in
                    Text(heading.title).font(heading.level == 0 ? .headline : .body)
                        .padding(.leading, heading.level == 0 ? 0 : 12).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
                if model.hasMore {
                    HStack {
                        Button("显示更多章节") { Task { await model.loadMore() } }.disabled(model.loadingMore)
                        Spacer()
                        if model.loadingMore { LoadingActivity(size: 22, waitingLabel: "正在加载") }
                    }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                }
            }
        }
        .themedPage().navigationTitle("目录预览").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("应用目录", systemImage: "checkmark") {
                Task { if await model.apply() { await applied(); if let finished { finished() } else { dismiss() } } }
            }.labelStyle(.titleOnly).disabled(!model.canApply).accessibilityIdentifier("applyChapterRebuild")
        } }
        .onAppear { model.startIfNeeded() }
        .overlay { if model.applying { LoadingActivity(size: 32, waitingLabel: "正在应用目录") } }
    }
}
