import SwiftUI
import UIKit

struct ReaderTaskContent: View {
    let panel: ReaderPanel?
    let session: ReaderSession
    let tools: ReaderToolsModel
    let libraryEditing: ReaderLibraryEditing
    let aiEntrySnapshot: AIEntryContext?
    let aiContext: () -> AIEntryContext
    @Binding var aiConversationID: String?
    let openingIsActive: () -> Bool
    let closeTask: () -> Void
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    @Environment(AIService.self) private var ai
    @ViewBuilder var body: some View {
        if panel == .ai, ai.availability.isAvailable {
            AIReadingConversation(context: aiEntrySnapshot ?? aiContext(), close: closeTask, selected: $aiConversationID, openingIsActive: openingIsActive)
        } else if let mark = session.editor {
            NoteEditor(edit: mark, close: closeTask)
        } else if panel == .history {
            ReaderHistorySheet(session: session, close: closeTask)
        } else if panel == .chapterEditor, let draft = session.chapterDraft, let id = session.readingID {
            NavigationStack {
                ChapterEditor(bookID: id, draft: draft) { await session.refreshOutline(); closeTask() }
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("取消", systemImage: "xmark", action: closeTask).labelStyle(.titleOnly)
                    } }
            }
        } else if panel == .library {
            ReaderLibrarySheet(model: tools, session: session, navigate: navigate, edit: edit, close: closeTask, editing: libraryEditing)
            .disabled(session.navigating)
        }
    }

}
