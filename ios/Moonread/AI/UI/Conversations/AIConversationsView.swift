import MoonreadAI
import SwiftUI

struct AIConversationsView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        AIConversationsContent(openSettings: { library.shell.openSettings(target: .ai) }) { id in
            AIChatView(conversationID: id)
        } libraryDestination: { (route: LibraryRoute) in
            LibraryDestination(route: route)
        }
    }
}
