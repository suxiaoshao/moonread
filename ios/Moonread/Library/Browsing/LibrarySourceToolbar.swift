import SwiftUI

/// A source stack's toolbar items stay absent until its reader has really left.
/// Route removal alone can precede the end of an interactive pop.
@MainActor @Observable
final class LibrarySourceToolbar {
    private var readers: [UUID: Int] = [:]

    func cover(_ opening: UUID, depth: Int) {
        guard readers[opening] != depth else { return }
        readers[opening] = depth
    }

    func completed(_ opening: UUID, popping: Bool, cancelled: Bool) {
        guard popping, !cancelled, readers[opening] != nil else { return }
        readers.removeValue(forKey: opening)
    }

    func covers(depth: Int, path: [LibraryRoute]) -> Bool {
        readers.values.contains { $0 > depth }
            || path.enumerated().contains { $0.element.isReader && $0.offset + 2 > depth }
    }
}

/// Depth applies only to items belonging to this page, not the navigation bar.
/// A reader's pushed settings/details are at its depth or above, so remain usable.
@MainActor
struct LibrarySourceToolbarContext {
    let owner: LibrarySourceToolbar
    let path: [LibraryRoute]
    var depth = 1

    var covered: Bool { owner.covers(depth: depth, path: path) }

    func page(_ route: LibraryRoute) -> Self {
        var next = self
        next.depth = path.lastIndex(of: route).map { $0 + 2 } ?? .max
        return next
    }
}

extension EnvironmentValues {
    @Entry var librarySourceToolbar: LibrarySourceToolbarContext? = nil
}
