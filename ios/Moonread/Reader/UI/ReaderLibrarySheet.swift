import SwiftUI
import UIKit

@MainActor @Observable
final class ReaderLibraryEditing {
    var visibleChapters: Set<UInt64> = []
    var chapterVisibilityKnown = false
    var editingOutline = false
    @ObservationIgnored weak var readerTools: ReaderToolSession?
    var chapterEdit: ChapterEditDraft? {
        guard let editor = readerTools?.editor, case let .chapter(draft) = editor.payload else { return nil }
        return draft
    }
    func beginChapter(_ draft: ChapterEditDraft) {
        guard let readerTools else { return }
        readerTools.beginEditing(.chapter(draft), presenter: .library)
    }
    var rebuildModel: ChapterRebuildModel? {
        guard let editor = readerTools?.editor, case let .rebuild(model) = editor.payload else { return nil }
        return model
    }
    var rebuildingOutline: Bool { rebuildModel != nil }
    func beginRebuild(_ bookID: String) {
        guard let readerTools else { return }
        readerTools.beginEditing(.rebuild(ChapterRebuildModel(bookID: bookID)), presenter: .library)
    }
    var restoringOutline = false
    var removedChapter: ChapterEntry?
}

struct ReaderLibrarySheet: View {
    let model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    let close: () -> Void
    let editing: ReaderLibraryEditing
    var editorClosed: () -> Void = {}
    var body: some View {
        NavigationStack {
            ReaderLibraryContent(model: model, session: session, navigate: navigate, edit: edit, close: close, editing: editing, editorClosed: editorClosed)
        }
    }
}

struct ReaderLibraryContent: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    let close: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @FocusState private var chapterFilterFocused: Bool
    @Bindable var editing: ReaderLibraryEditing
    var editorClosed: () -> Void = {}

    private var listTitle: String {
        switch model.tab {
        case .chapters: String(localized: "目录")
        case .bookmarks: String(localized: "书签")
        case .notes: String(localized: "标注与笔记")
        }
    }
    private var outlineActions: some View {
        ReaderChapterActions(editing: editing, bookID: session.readingID, incomplete: session.incomplete)
    }
    private var closeButton: some View {
        Button("关闭", systemImage: "xmark", action: close)
            .labelStyle(.iconOnly).toolbarGlyph().accessibilityIdentifier("closeReaderLibrary")
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        if model.tab == .chapters { ToolbarItem(placement: .topBarLeading) { outlineActions } }
        ToolbarItem(placement: .topBarTrailing) { closeButton }
    }

    private var preparedBookID: String? { session.opening.phase == .reading ? session.readingID : nil }

    var body: some View {
        libraryContent
            .navigationTitle(listTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { libraryToolbar }
    }

    private var libraryContent: some View {
            VStack(spacing: 0) {
                switch model.tab {
                case .chapters: chapterList
                case .bookmarks, .notes: notesList
                }
            }
            .dismissKeyboardOnOutsideTap($chapterFilterFocused)
            .background(Color(uiColor: theme.surface))
            .safeAreaInset(edge: .bottom) {
                if let removed = editing.removedChapter, let id = session.readingID {
                    HStack {
                        Text("已移除目录项").foregroundStyle(Color(uiColor: theme.secondary))
                        Spacer()
                        Button("撤销") {
                            Task {
                                do {
                                    try await AppDataService.shared.correctChapter(id, offset: removed.startUtf8, title: removed.title, level: removed.level)
                                    editing.removedChapter = nil; await refreshOutline()
                                } catch { model.error = ReaderMessages.error(error) }
                            }
                        }.accessibilityIdentifier("undoChapterRemoval")
                    }.padding().background(Color(uiColor: theme.raised))
                }
            }
            .modifier(ReaderLibraryEditorPresentation(editing: editing, session: session, refreshOutline: refreshOutline, closed: editorClosed))
            .confirmationDialog("恢复自动目录？", isPresented: $editing.restoringOutline, titleVisibility: .visible) {
                Button("清除人工修正", role: .destructive) {
                    guard let id = session.readingID else { return }
                    Task {
                        do { try await AppDataService.shared.restoreChapterCorrections(id); await refreshOutline() }
                        catch { model.error = ReaderMessages.error(error) }
                    }
                }
            } message: { Text("仅清除目录的人工修正，正文、书签和笔记保持不变。") }
            .task(id: preparedBookID) {
                guard let id = preparedBookID else { return }
                var available = session.book?.byteCount
                var complete = !session.incomplete
                await session.activity.flush()
                await model.prepare(bookID: id, currentChapter: session.chapter?.startUtf8 ?? 0, library: true, preservingPosition: true)
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
            .onChange(of: session.marksRevision) { _, _ in
                Task { await model.refreshVisibleMarks() }
            }
            .alert("暂时无法完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }

    private var chapterList: some View {
        ReaderChapterList(model: model, session: session, navigate: navigate,
                          visibleChapters: $editing.visibleChapters, chapterVisibilityKnown: $editing.chapterVisibilityKnown,
                          editingOutline: $editing.editingOutline, editChapter: editing.beginChapter, removedChapter: $editing.removedChapter,
                          chapterFilterFocused: $chapterFilterFocused, refreshOutline: refreshOutline)
    }
    private var notesList: some View {
        ReaderNotesList(model: model, session: session, navigate: navigate, edit: edit)
    }
    private func refreshOutline() async {
        await session.refreshOutline()
        await model.refreshChapters(jumpTo: session.anchor)
    }

}

private struct ReaderLibraryEditorPresentation: ViewModifier {
    @Bindable var editing: ReaderLibraryEditing
    let session: ReaderSession
    let refreshOutline: () async -> Void
    let closed: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        content
            .navigationDestination(item: chapterBinding) { draft in
                if let id = session.readingID {
                    ChapterEditor(bookID: id, draft: draft) { await refreshOutline() }
                        .onDisappear(perform: closed)
                }
            }
            .navigationDestination(isPresented: rebuildBinding) {
                if let model = editing.rebuildModel {
                    ChapterRebuildView(model: model) { await refreshOutline() }
                        .onDisappear(perform: closed)
                }
            }
    }
    private var chapterBinding: Binding<ChapterEditDraft?> {
        let current = editing.readerTools?.editor
        let token = editing.readerTools?.host.token
        let generation = editing.readerTools?.presentation.revision ?? 0
        return Binding(get: { current?.presenter == .library ? editing.chapterEdit : nil }, set: {
            if $0 == nil, let current, editing.readerTools?.acceptsNativeInput(token, generation: generation) == true {
                editing.readerTools?.finishEditing(current.id)
            }
        })
    }
    private var rebuildBinding: Binding<Bool> {
        let current = editing.readerTools?.editor
        let token = editing.readerTools?.host.token
        let generation = editing.readerTools?.presentation.revision ?? 0
        return Binding(get: { current?.presenter == .library && editing.rebuildingOutline }, set: {
            if !$0, let current, editing.readerTools?.acceptsNativeInput(token, generation: generation) == true {
                editing.readerTools?.finishEditing(current.id)
            }
        })
    }
}

struct ReaderChapterActions: View {
    @Bindable var editing: ReaderLibraryEditing
    let bookID: String?
    let incomplete: Bool
    var body: some View {
        Menu {
            Button(editing.editingOutline ? "结束整理" : "整理目录", systemImage: "pencil") { editing.editingOutline.toggle() }
            Button("重新识别目录", systemImage: "arrow.clockwise") { if let bookID { editing.beginRebuild(bookID) } }
            Button("恢复自动目录", systemImage: "arrow.uturn.backward") { editing.restoringOutline = true }
        } label: {
            Label("目录操作", systemImage: editing.editingOutline ? "pencil.circle.fill" : "ellipsis")
        }.disabled(incomplete).toolbarGlyph().accessibilityIdentifier("chapterActions")
    }
}
