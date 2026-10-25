import SwiftUI
import UIKit

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
                                    try await AppDataService.shared.correctChapter(id, offset: removed.startUtf8, title: removed.title, level: removed.level)
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
                        do { try await AppDataService.shared.restoreChapterCorrections(id); await refreshOutline() }
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
        ReaderChapterList(model: model, session: session, navigate: navigate,
                          visibleChapters: $visibleChapters, chapterVisibilityKnown: $chapterVisibilityKnown,
                          editingOutline: $editingOutline, chapterEdit: $chapterEdit, removedChapter: $removedChapter,
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
