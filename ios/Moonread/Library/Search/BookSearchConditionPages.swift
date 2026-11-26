import MoonreadCoreBindings
import MoonreadLibrary

extension BookSearchShelfOptionLabel {
    init(shelf: LibraryShelf, service: AppDataService, showsLocation: Bool = false) {
        self.init(shelf: shelf, showsLocation: showsLocation) {
            guard case .external(.usable(let url, _))? = try? await service.shelfSource(shelf) else { return nil }
            return url.deletingLastPathComponent().path(percentEncoded: false)
        }
    }
}
