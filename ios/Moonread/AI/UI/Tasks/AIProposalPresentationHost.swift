import MoonreadAI
import MoonreadData
import MoonreadLibrary
import MoonreadReader
import SwiftUI

struct AIResultCard: View {
    let result: AIResultValue

    var body: some View {
        MoonreadAI.AIResultCard(result: result) { edit, hooks, close in
            AnyView(NoteEditor(edit: edit, service: AppDataService.shared, aiCommit: hooks, close: close))
        }
    }
}

struct AIBookFilterCard: View {
    @Environment(LibraryModel.self) private var library
    let suggestion: AIBookFilterSuggestion
    let configuration: BookSearchConfiguration
    let open: () -> Void

    var body: some View {
        MoonreadAI.AIBookFilterCard(suggestion: suggestion, configuration: configuration,
                                    shelves: library.shelves, open: open)
    }
}

struct AIFilterShelfChoiceSheet: View {
    @Environment(LibraryModel.self) private var library
    let suggestion: AIBookFilterSuggestion
    let open: (BookSearchConfiguration) -> Void

    var body: some View {
        MoonreadAI.AIFilterShelfChoiceSheet(suggestion: suggestion, shelves: library.shelves, shelfLabel: { shelf in
            AnyView(BookSearchShelfOptionLabel(shelf: shelf, service: library.service, showsLocation: true))
        }, open: open)
    }
}
