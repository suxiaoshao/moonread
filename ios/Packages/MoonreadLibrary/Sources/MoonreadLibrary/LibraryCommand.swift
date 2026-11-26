import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

public enum LibraryCommand {
    case rename(LibraryEntry, String), move(LibraryEntry, LibraryLocation), copy(LibraryEntry)
    case create(LibraryLocation, String), delete(LibraryEntry), receive(LibraryImportFile, LibraryLocation)
    public var filename: String {
        switch self {
        case .rename(_, let name), .create(_, let name): name
        case .move(let entry, _), .copy(let entry), .delete(let entry): entry.name
        case .receive(let file, _): file.url.lastPathComponent
        }
    }
}

public enum LibraryPendingDecision: Identifiable {
    case replacement(LibraryCommand, id: UUID = UUID())
    case trashUnsupported(LibraryEntry, id: UUID = UUID())
    public var id: UUID {
        switch self { case .replacement(_, let id), .trashUnsupported(_, let id): id }
    }
}

public enum LibraryTrashChoice { case permanentlyDelete, skip }
