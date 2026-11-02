import SwiftUI
import UIKit

struct ReaderNotesList: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    @Environment(\.theme) private var theme
    @State private var sharing: NoteSharePayload?
    @State private var deleting: NoteCandidates?
    @State private var deletingIDs: Set<String> = []
    @State private var busy = false
    @State private var confirmDelete = false
    var body: some View {
        VStack(spacing: 0) {
            if model.deletedIDs != nil {
                HStack { Text("已删除"); Spacer(); Button("撤销") { Task { await model.undoDelete(); session.notesChanged() } } }
                    .font(.subheadline).padding(.horizontal).padding(.vertical, 8)
            }
            if let error = model.notesLoadError {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                    Button("重试") { Task { await model.loadNotes(reset: true) } }
                }.padding()
            }
            List(selection: Binding(get: { model.selectedNotes }, set: { model.updateNoteSelection($0) })) {
                if let title = session.book?.title {
                    Text(verbatim: title).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        .frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                        .listRowBackground(Color(uiColor: theme.surface)).listRowSeparator(.hidden).selectionDisabled()
                }
                ForEach(model.notes, id: \.id) { mark in
                    HStack(alignment: .top, spacing: 12) {
                        if mark.kind == .annotation {
                            RoundedRectangle(cornerRadius: 2).fill(Color(uiColor: theme.annotation))
                                .frame(width: 3).frame(maxHeight: .infinity)
                        }
                        Group {
                            if model.selectingNotes { noteContent(mark) }
                            else {
                                Button {
                                    navigate(mark.startUtf8, mark.kind == .annotation ? mark.endUtf8 : nil, mark.kind == .annotation ? .context : .start)
                                } label: { noteContent(mark) }.buttonStyle(.plain)
                            }
                        }.accessibilityIdentifier("noteRow-\(mark.id)")
                        if mark.kind == .annotation && !model.selectingNotes {
                            Button { edit(mark) } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("编辑批注").accessibilityIdentifier("editNote-\(mark.id)")
                        }
                    }.frame(maxWidth: 680).frame(maxWidth: .infinity).padding(.vertical, 8)
                        .tag(mark.id).selectionDisabled(!model.selectingNotes)
                        .listRowBackground(Color(uiColor: theme.surface))
                        .listRowSeparatorTint(Color(uiColor: theme.separator))
                        .swipeActions {
                            if !model.selectingNotes { Button("删除", systemImage: "trash", role: .destructive) {
                                Task { await model.delete(mark); session.notesChanged() }
                            }
                            .labelStyle(.titleAndIcon)
                            .tint(Color(uiColor: theme.destructive)) }
                        }
                }
                if model.moreNotes { LoadingActivity().selectionDisabled().task(id: model.notes.count) { await model.loadNotes(reset: false) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(model.selectingNotes ? .active : .inactive))
                .overlay {
                    if model.notes.isEmpty && model.loadingNotes {
                        LoadingActivity(fullPage: true, waitingLabel: "正在加载")
                    } else if model.notes.isEmpty && !model.loadingNotes && model.notesLoadError == nil {
                        ThemedEmptyState(title: model.noteKind == .bookmark ? String(localized: "暂无书签") : String(localized: "暂无笔记"), symbol: model.noteKind == .bookmark ? "bookmark" : "square.and.pencil")
                    }
                }
        }.disabled(busy)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Group {
                    if model.selectingNotes {
                        SystemToolbarButton("结束选择", role: .confirm) { model.selectingNotes = false; model.clearNoteSelection() }
                    } else {
                        Button { model.selectingNotes = true } label: { Image(systemName: "checklist") }
                            .accessibilityLabel(model.noteKind == .bookmark ? String(localized: "选择书签") : String(localized: "选择标注与笔记"))
                    }
                }.disabled(busy || (model.notes.isEmpty && !model.selectingNotes))
            }
            if model.noteKind == .annotation {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let id = model.noteBookID { NavigationLink("导出整本笔记") { NoteExportView(bookID: id) } }
                    } label: { Image(systemName: "ellipsis") }.accessibilityLabel("小说选项")
                }
            }
            if model.selectingNotes {
                ToolbarItem(placement: .bottomBar) {
                    Button("分享", systemImage: "square.and.arrow.up") { Task { await shareSelected() } }.disabled(busy || model.selectedNotes.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
                selectionStatusItem
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        guard let snapshot = model.noteSnapshot else { return }
                        deletingIDs = model.selectedNotes
                        deleting = NoteCandidates(key: snapshot.key, groups: model.selectedCandidates, blocked: snapshot.blocked)
                        confirmDelete = true
                    }.disabled(busy || model.selectedNotes.isEmpty).tint(Color(uiColor: theme.destructive))
                }
            }
        }
        .onChange(of: model.deletedIDs, initial: true) { _, ids in model.setUndoVisible(ids != nil) }
        .onDisappear { model.setUndoVisible(false) }
        .confirmationDialog(model.noteKind == .bookmark ? String(localized: "删除 \(deletingIDs.count) 个书签？") : String(localized: "删除 \(deletingIDs.count) 项笔记？"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let expected = deleting else { return }
                let ids = deletingIDs
                Task { busy = true; await model.deleteSelectedNotes(expected, ids: ids); busy = false; session.notesChanged() }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("会同步删除其他设备上的这些记录，小说原文件不受影响。") }
        .sheet(item: $sharing) { LibraryShareSheet(files: $0.files, text: $0.text) }
    }
    private func noteContent(_ mark: ReaderMark) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: mark.excerpt).foregroundStyle(Color(uiColor: theme.ink)).lineLimit(3)
            if !mark.note.isEmpty { Text(verbatim: mark.note).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(2) }
            Text(verbatim: [model.noteLocations[mark.id], Date(timeIntervalSince1970: Double(mark.created) / 1000).formatted(date: .abbreviated, time: .omitted)]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
    }
    private var selectionStatus: some View {
        Group {
            if busy { ProgressView() } else { Text("已选 \(model.selectedNotes.count) 项") }
        }.font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
    }
    @ToolbarContentBuilder private var selectionStatusItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .bottomBar) { selectionStatus }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .bottomBar) { selectionStatus }
        }
    }
    private func shareSelected() async {
        guard !busy, let id = model.noteBookID else { return }
        busy = true; defer { busy = false }
        do {
            let document = try await AppDataService.shared.noteDocument(id, ids: model.selectedNotes)
            guard !document.records.isEmpty else { await model.loadNotes(reset: true); return }
            sharing = NoteSharePayload(text: document.render(.text, file: false))
        } catch { model.error = ReaderMessages.error(error) }
    }
}
