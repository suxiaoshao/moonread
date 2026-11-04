import TipKit
import SwiftUI
import UniformTypeIdentifiers

/// Private item references can target any available shelf; external files only builtin.
struct LibraryShelfDropTarget: ViewModifier {
    let model: LibraryModel
    let shelf: LibraryShelf
    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.moonreadLibraryItem, .plainText],
                       delegate: LibraryShelfDropDelegate(model: model, destination: LibraryLocation(shelfID: shelf.id)))
    }
}

/// The system hands providers to performDrop before any application payload loading.
struct LibraryShelfDropDelegate: DropDelegate {
    let model: LibraryModel
    let destination: LibraryLocation
    func validateDrop(info: DropInfo) -> Bool { operation(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])) != .forbidden }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: operation(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])))
    }
    func performDrop(info: DropInfo) -> Bool { accept(info.itemProviders(for: [UTType.moonreadLibraryItem, .plainText])) }
    func operation(_ providers: [NSItemProvider]) -> DropOperation {
        guard model.canAcceptDrop(at: destination), let request = LibraryDropPolicy.request(providers, at: destination) else { return .forbidden }
        switch request { case .moveIDs, .moveProviders: return .move; case .importProviders: return .copy }
    }
    func accept(_ providers: [NSItemProvider]) -> Bool {
        guard let request = LibraryDropPolicy.request(providers, at: destination) else { return false }
        return model.acceptDrop(request, at: destination)
    }
}
