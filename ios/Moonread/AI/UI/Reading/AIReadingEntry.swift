import MoonreadAI
import SwiftUI

struct AIReadingConversation: View {
    let context: AIEntryContext
    let close: () -> Void
    @Binding var selected: String?
    let openingIsActive: () -> Bool
    let readingSearch: AIReadingSearchContext

    var body: some View {
        AIReadingConversationContent(context: context, close: close, selected: $selected, openingIsActive: openingIsActive) { id in
            AIChatView(conversationID: id, placement: .sheet, readingSearch: readingSearch)
        }
    }
}
