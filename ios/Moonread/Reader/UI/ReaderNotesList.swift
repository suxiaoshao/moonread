import SwiftUI
import UIKit

struct ReaderNotesList: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    var preservedPosition: Binding<String?>? = nil
    @State private var restoredPosition = false
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(spacing: 0) {
            if model.deletedIDs != nil {
                HStack { Text("已删除"); Spacer(); Button("撤销") { Task { await model.undoDelete(); session.notesChanged() } } }
                    .font(.subheadline).padding(.horizontal).padding(.vertical, 8)
            }
            ScrollViewReader { proxy in
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
                    }.padding(.vertical, 8).id(mark.id)
                        .onGeometryChange(for: Bool.self) { geometry in
                            let frame = geometry.frame(in: .named("readerNotesViewport"))
                            return frame.minY <= 1 && frame.maxY > 1
                        } action: { atTop in
                            if atTop, restoredPosition { preservedPosition?.wrappedValue = mark.id }
                        }
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
                if model.moreNotes { LoadingActivity().task(id: model.notes.count) { await model.loadNotes(reset: false) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .coordinateSpace(name: "readerNotesViewport")
                .onChange(of: model.tab) { _, _ in restoredPosition = false }
                .onChange(of: model.loadingNotes, initial: true) { _, loading in
                    guard !restoredPosition, !loading, !model.notes.isEmpty else { return }
                    restoredPosition = true
                    if let id = preservedPosition?.wrappedValue, model.notes.contains(where: { $0.id == id }) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
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

}
