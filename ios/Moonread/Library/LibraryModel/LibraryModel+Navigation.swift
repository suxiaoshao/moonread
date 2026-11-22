import SwiftUI
import UniformTypeIdentifiers

/// Browsing pages carry their navigation owner through both layouts.
@MainActor
struct LibraryBrowsingHost {
    var push: ((LibraryRoute) -> Void)?
    var isCurrent: () -> Bool = { true }
    var allowsFileBrowsing = true
    var isOpenBook: (LibraryEntry) -> Bool = { _ in false }
    var returnToOpenBook: () -> Void = {}

    static var main: Self { .init(push: nil) }

    func open(_ entry: LibraryEntry, in model: LibraryModel) {
        guard isCurrent() else { return }
        if !entry.directory && isOpenBook(entry) { returnToOpenBook() }
        else { model.open(entry, push: push, isCurrent: isCurrent) }
    }

    func navigate(_ route: LibraryRoute, in model: LibraryModel) {
        guard isCurrent() else { return }
        if let push { push(route) } else { model.shell.path.append(route) }
    }
}

extension LibraryModel {
    func openIndexFailure(_ id: String) {
        Task {
            do { open(try await service.libraryEntry(id)) }
            catch { self.error = ReaderMessages.error(error) }
        }
    }
    func open(_ entry: LibraryEntry, expectedContentSHA: String? = nil, tap: TimeInterval = ProcessInfo.processInfo.systemUptime, push: ((LibraryRoute) -> Void)? = nil, isCurrent: @escaping () -> Bool = { true }) {
        guard isCurrent() else { return }
        if entry.directory {
            if let push { push(.folder(entry.location)) } else { shell.path.append(.folder(entry.location)) }
            return
        }
        let target = ReaderRoute.source(entry.source)
        if push == nil, case .reader(let previous) = shell.path.last,
           case .source(let source) = previous.target, source.id == entry.id,
           previous.expectedContentSHA == expectedContentSHA { return }

        let route = LibraryRoute.reader(OpeningRequest(target: target, tap: tap,
            expectedContentSHA: expectedContentSHA, metadataHint: entry.metadata,
            coverHint: entry.bookRow?.cardMetadata.map { .init(sha: entry.readingIdentity?.formalSHA256, card: $0) }))
        if let push { push(route) }
        // A second tap queued during the push supersedes its destination,
        // rather than stacking two readers. Destinations own their own tasks.
        else if shell.path.last?.isReader == true { shell.path[shell.path.count - 1] = route }
        else { shell.path.append(route) }
    }
    /// #287: capture the exact visible copy and identity before any await.
    func openRecent(_ entry: LibraryEntry) {
        guard systemReading.cancelForLibraryOpen() else { return }
        open(entry, expectedContentSHA: entry.readingIdentity?.formalSHA256)
    }

    func hideRecent(_ entry: LibraryEntry) async {
        guard let id = entry.readingKey else { return }
        do { try await service.hideRecent(id) }
        catch { self.error = ReaderMessages.error(error) }
    }
}
