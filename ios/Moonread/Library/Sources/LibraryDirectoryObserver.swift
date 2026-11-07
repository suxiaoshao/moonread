import Foundation

/// The presenter only signals invalidation. Coordinated scans and all content
/// work run on AppDataService, never on the presenter's queue or the main actor.
final class LibraryDirectoryObserver: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private var accessed: Bool
    init(url: URL) {
        presentedItemURL = url
        accessed = url.startAccessingSecurityScopedResource()
        presentedItemOperationQueue = OperationQueue()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    func stop() {
        NSFileCoordinator.removeFilePresenter(self)
        if accessed { presentedItemURL?.stopAccessingSecurityScopedResource(); accessed = false }
    }
    private func changed() { NotificationCenter.default.post(name: .libraryFilesChanged, object: nil) }
    func presentedItemDidChange() { changed() }
    func presentedItemDidMove(to newURL: URL) { changed() }
    func presentedSubitemDidAppear(at url: URL) { changed() }
    func presentedSubitemDidChange(at url: URL) { changed() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { changed() }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil); changed()
    }
}
