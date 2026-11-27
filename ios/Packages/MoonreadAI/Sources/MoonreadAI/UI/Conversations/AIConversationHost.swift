import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import SwiftUI

public enum AIConversationSearchSummary {
    case filter(root: BookSearchNode?, title: LocalizedStringKey, sorts: [BookSearchSort])
    case books(content: AnyView)
}

public enum AIConversationHostAction {
    case openBook(reference: String, title: String, entry: LibraryEntry)
    case openFilter(AIBookFilterSuggestion)
}

/// App-only dependencies used by the AI conversation presentation.
@MainActor public struct AIConversationHost {
    public init(
        readingAccess: AIReadingAccess,
        shelves: @escaping @MainActor () -> [LibraryShelf],
        readingInputRevision: @escaping @MainActor () -> UInt64,
        noteEditor: @escaping AIProposalNoteEditor,
        replyFeedbackRecipient: String,
        searchSummary: @escaping @MainActor (AIConversationSearchSummary) -> AnyView,
        onAction: @escaping @MainActor (AIConversationHostAction) -> Bool
    ) {
        self.readingAccess = readingAccess; self.shelves = shelves; self.readingInputRevision = readingInputRevision
        self.noteEditor = noteEditor
        self.replyFeedbackRecipient = replyFeedbackRecipient; self.searchSummary = searchSummary; self.onAction = onAction
    }

    public let readingAccess: AIReadingAccess
    public let shelves: @MainActor () -> [LibraryShelf]
    public let readingInputRevision: @MainActor () -> UInt64
    public let noteEditor: AIProposalNoteEditor
    public let replyFeedbackRecipient: String
    public let searchSummary: @MainActor (AIConversationSearchSummary) -> AnyView
    public let onAction: @MainActor (AIConversationHostAction) -> Bool
}
