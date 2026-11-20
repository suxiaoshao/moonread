import SwiftUI
import UIKit

struct ReaderTaskContent: View {
    let visit: ReaderToolVisit?
    let session: ReaderSession
    let tools: ReaderToolsModel
    let toolSession: ReaderToolSession
    @Binding var aiConversationID: String?
    let openingIsActive: () -> Bool
    let closeTask: () -> Void
    let navigate: (UInt64, UInt64?, ReadingTargetPlacement, String?) -> Void
    let edit: (ReaderMark) -> Void
    let editorClosed: () -> Void
    @Environment(AIService.self) private var ai

    var body: some View { taskContent.modifier(SystemReadingConfirmation()) }

    @ViewBuilder private var taskContent: some View {
        switch visit?.route {
        case .ai(let context) where ai.availability.isAvailable:
            AIReadingConversation(context: context, close: closeTask, selected: $aiConversationID, openingIsActive: openingIsActive)
        case .note(let model), .library(.note(_, let model)):
            NoteEditor(model: model, close: closeTask)
        case .history:
            ReaderHistorySheet(session: session, navigate: { navigate($0, nil, .start, $1) }, close: closeTask)
        case .chapter(let editor):
            if case let .chapter(draft) = editor.payload, let id = session.readingID {
                NavigationStack {
                    ChapterEditor(bookID: id, draft: draft) { await session.refreshOutline(); closeTask() }
                        .toolbar { ToolbarItem(placement: .topBarLeading) {
                            SystemToolbarButton("取消", role: .cancel, action: closeTask)
                        } }
                }
            }
        case .library:
            ReaderLibrarySheet(model: tools, session: session, navigate: { navigate($0, $1, $2, nil) },
                edit: edit, close: closeTask, editing: toolSession.libraryEditing, editorClosed: editorClosed)
                .disabled(session.navigating)
        default:
            EmptyView()
        }
    }
}
