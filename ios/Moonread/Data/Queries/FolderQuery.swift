import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import GRDB

extension ReaderIndex {
    func folderEntries(_ location: LibraryLocation, sort: LibrarySort) throws -> [LibraryEntry] {
        try FolderRead.entries(session.readUsers(lease) { try FolderRead.page($0, scope: self.lease.scope, location: location) }, sort: sort)
    }

    func folderDestinations(_ location: LibraryLocation) throws -> [LibraryEntry] {
        try FolderRead.entries(session.readUsers(lease) { try FolderRead.destinations($0, scope: self.lease.scope, location: location) })
    }
}
