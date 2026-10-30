import SwiftUI
import UIKit

struct ReaderTaskContent: View {
    let panel: ReaderPanel?
    let session: ReaderSession
    let tools: ReaderToolsModel
    let toolSession: ReaderToolSession
    let retainedNote: NoteEditorModel?
    let retainedEditor: ReaderEditSession?
    let aiEntrySnapshot: AIEntryContext?
    let aiContext: () -> AIEntryContext
    @Binding var aiConversationID: String?
    let openingIsActive: () -> Bool
    let closeTask: () -> Void
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement) -> Void
    let edit: (ReaderMark) -> Void
    let editorClosed: () -> Void
    @Environment(AIService.self) private var ai
    var body: some View { taskContent.modifier(SystemReadingConfirmation()) }
    @ViewBuilder private var taskContent: some View {
        if panel == .ai, ai.availability.isAvailable {
            AIReadingConversation(context: aiEntrySnapshot ?? aiContext(), close: closeTask, selected: $aiConversationID, openingIsActive: openingIsActive)
        } else if let model = retainedNote ?? session.noteEditorModel {
            NoteEditor(model: model, close: closeTask)
        } else if panel == .history {
            ReaderHistorySheet(session: session, close: closeTask)
        } else if panel == .chapterEditor, let editor = retainedEditor ?? toolSession.editor,
                  case let .chapter(draft) = editor.payload, let id = session.readingID {
            NavigationStack {
                ChapterEditor(bookID: id, draft: draft) { await session.refreshOutline(); closeTask() }
                    .toolbar { ToolbarItem(placement: .topBarLeading) {
                        Button("取消", systemImage: "xmark", action: closeTask).labelStyle(.titleOnly)
                    } }
            }
        } else if panel == .library {
            ReaderLibrarySheet(model: tools, session: session, navigate: navigate, edit: edit, close: closeTask, editing: toolSession.libraryEditing, editorClosed: editorClosed)
            .disabled(session.navigating)
        }
    }

}
