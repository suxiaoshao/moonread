import SwiftUI
import UIKit

struct ReaderNotesList: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    @Environment(\.theme) private var theme
    var body: some View {
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
                if model.moreNotes { LoadingActivity().task(id: model.notes.count) { await model.loadNotes(reset: false) }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator)) }
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
