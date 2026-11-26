import Foundation
import GRDB
import MoonreadDataTypes

public struct SavedFilter: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var configuration: BookSearchConfiguration

    public init(id: UUID, name: String, configuration: BookSearchConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}

public struct SavedFilterSnapshot: Equatable, Sendable {
    public let scope: DataScope
    public let entries: [SavedFilter]
}

public enum SavedFilterChange: Sendable {
    case create(SavedFilter)
    case update(UUID, BookSearchConfiguration)
    case rename(UUID, String)
    case remove(UUID)
}

extension ReaderIndex {
    public func savedFilters() throws -> SavedFilterSnapshot {
        return try session.readUsers(lease) { db in
            try Self.readSavedFilters(db, scope: self.lease.scope)
        }
    }

    public func changeSavedFilters(_ change: SavedFilterChange, scope: DataScope) throws -> SavedFilterSnapshot {
        guard lease.scope == scope else { throw CancellationError() }
        return try session.writeUsers(lease) { db in
            switch change {
            case .create(let entry):
                try db.execute(sql: "INSERT INTO usr.local_saved_filter(id,name,configuration) VALUES(?,?,?)",
                               arguments: [entry.id.uuidString, entry.name, try JSONEncoder().encode(entry.configuration.forVirtualShelf)])
            case .update(let id, let configuration):
                // Re-saving the conditions moves this filter to the top of the recently saved list.
                try db.execute(sql: """
                    UPDATE usr.local_saved_filter
                    SET sequence=(SELECT max(sequence)+1 FROM usr.local_saved_filter),configuration=? WHERE id=?
                    """, arguments: [try JSONEncoder().encode(configuration.forVirtualShelf), id.uuidString])
            case .rename(let id, let name):
                try db.execute(sql: "UPDATE usr.local_saved_filter SET name=? WHERE id=?", arguments: [name, id.uuidString])
            case .remove(let id):
                try db.execute(sql: "DELETE FROM usr.local_saved_filter WHERE id=?", arguments: [id.uuidString])
            }
            return try Self.readSavedFilters(db, scope: scope)
        }
    }

    private static func readSavedFilters(_ db: Database, scope: DataScope) throws -> SavedFilterSnapshot {
        let rows = try Row.fetchAll(db, sql: "SELECT id,name,configuration FROM usr.local_saved_filter ORDER BY sequence DESC")
        let decoder = JSONDecoder()
        let entries = try rows.map { row in
            guard let id = UUID(uuidString: row["id"]) else { throw DataV2Error.incompatibleSource("saved filter ID") }
            return SavedFilter(id: id, name: row["name"],
                               configuration: try decoder.decode(BookSearchConfiguration.self, from: row["configuration"]))
        }
        return SavedFilterSnapshot(scope: scope, entries: entries)
    }
}
