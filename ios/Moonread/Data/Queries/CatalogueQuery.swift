import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import GRDB

extension ReaderIndex {
    func catalogue(_ shelfID: String, grouping: LibraryGrouping) throws -> CatalogueRead.Ordered {
        let snapshot = try session.readUsers(lease) {
            try CatalogueRead.fetch($0, scope: self.lease.scope, shelfID: shelfID, grouping: grouping)
        }
        return try CatalogueRead.order(snapshot)
    }
}
