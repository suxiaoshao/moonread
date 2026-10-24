import SwiftUI

struct ChapterEditDraft: Identifiable, Hashable {
    let start: UInt64
    let title: String
    let level: UInt32
    var id: UInt64 { start }
}

struct ChapterEditor: View {
    let bookID: String
    let draft: ChapterEditDraft
    let saved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var title: String
    @State private var level: UInt32
    @State private var saving = false
    @State private var error: String?
    init(bookID: String, draft: ChapterEditDraft, saved: @escaping () async -> Void) {
        self.bookID = bookID; self.draft = draft; self.saved = saved
        _title = State(initialValue: draft.title); _level = State(initialValue: draft.level)
    }
    var body: some View {
        Form {
            Section {
                TextField("章节名称", text: $title, axis: .vertical).focused($focused)
                    .keyboardInputRegion().accessibilityIdentifier("chapterEditTitle")
                Picker("层级", selection: $level) {
                    Text("章").tag(UInt32(1)); Text("卷").tag(UInt32(0))
                }.pickerStyle(.segmented).accessibilityIdentifier("chapterEditLevel")
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .themedPage().dismissKeyboardOnOutsideTap($focused)
        .navigationTitle("编辑目录项").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("保存", systemImage: "checkmark") { save() }.labelStyle(.titleOnly)
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveChapterEdit")
        } }
        .onAppear { focused = true }
        .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() {
        guard !saving else { return }; saving = true
        Task {
            defer { saving = false }
            do {
                try await ReaderService.shared.correctChapter(bookID, offset: draft.start, title: title, level: level)
                focused = false; await saved(); dismiss()
            } catch { self.error = ReaderMessages.error(error) }
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
    var canApply: Bool { job != nil && progress?.done == true && progress?.cancelled != true && !invalid && !applying && !loadingMore }
    @ObservationIgnored private let start: @MainActor (String) async throws -> ChapterRebuild
    @ObservationIgnored private let advance: @MainActor (ChapterRebuild) async throws -> ChapterRebuildProgress
    @ObservationIgnored private let preview: @MainActor (ChapterRebuild, UInt64) async throws -> [ChapterInfo]
    @ObservationIgnored private let commit: @MainActor (ChapterRebuild) async throws -> Void
    init(bookID: String, reader: ReaderService = .shared,
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
        do {
            let value = try await start(bookID); job = value
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
    func cancel() { invalid = true; job?.cancel() }
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var model: ChapterRebuildModel
    init(bookID: String, model: ChapterRebuildModel? = nil, applied: @escaping () async -> Void) {
        _model = State(initialValue: model ?? ChapterRebuildModel(bookID: bookID)); self.applied = applied
    }
    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    if model.progress?.done != true { LoadingActivity(size: 28, fraction: model.progress?.fraction) }
                    Text("已识别 \(Int(model.progress?.count ?? 0)) 章").monospacedDigit(); Spacer()
                }.frame(minHeight: 44)
            }.listRowBackground(Color(uiColor: theme.surface))
            Section {
                ForEach(model.headings, id: \.startUtf8) { heading in
                    Text(heading.title).font(heading.level == 0 ? .headline : .body)
                        .padding(.leading, heading.level == 0 ? 0 : 12).listRowBackground(Color(uiColor: theme.surface))
                }
                if model.hasMore {
                    HStack {
                        Button("显示更多章节") { Task { await model.loadMore() } }.disabled(model.loadingMore)
                        Spacer()
                        if model.loadingMore { LoadingActivity(size: 22, waitingLabel: "正在加载") }
                    }.listRowBackground(Color(uiColor: theme.surface))
                }
            }
            if let error = model.rebuildError ?? model.actionError { Text(error).foregroundStyle(Color(uiColor: theme.destructive)).listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
        }
        .themedPage().navigationTitle("目录预览").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("应用目录", systemImage: "checkmark") {
                Task { if await model.apply() { await applied(); dismiss() } }
            }.labelStyle(.titleOnly).disabled(!model.canApply).accessibilityIdentifier("applyChapterRebuild")
        } }
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .overlay { if model.applying { LoadingActivity(size: 32, waitingLabel: "正在应用目录") } }
    }
}
