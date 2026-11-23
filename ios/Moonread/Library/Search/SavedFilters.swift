import Foundation
import GRDB
import Observation

struct SavedFilter: Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var configuration: BookSearchConfiguration
}

struct SavedFilterSnapshot: Equatable, Sendable {
    let scope: DataScope
    let entries: [SavedFilter]
}

enum SavedFilterChange: Sendable {
    case create(SavedFilter)
    case update(UUID, BookSearchConfiguration)
    case rename(UUID, String)
    case remove(UUID)
}

extension AppDataService {
    func savedFilters() throws -> SavedFilterSnapshot {
        let index = try relationalUserIndex()
        return try index.session.readUsers(index.lease) { db in
            try Self.readSavedFilters(db, scope: index.lease.scope)
        }
    }

    func changeSavedFilters(_ change: SavedFilterChange, scope: DataScope) throws -> SavedFilterSnapshot {
        let index = try relationalUserIndex()
        guard index.lease.scope == scope else { throw CancellationError() }
        return try index.session.writeUsers(index.lease) { db in
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

@MainActor @Observable final class SavedFilters {
    private(set) var snapshot: SavedFilterSnapshot?
    private(set) var revision = 0
    private(set) var saving = false
    var error: String?
    private let service: AppDataService

    init(service: AppDataService) { self.service = service }

    var entries: [SavedFilter] { snapshot?.entries ?? [] }

    func rebind() {
        snapshot = nil
        error = nil
        revision += 1
    }

    func load() async {
        guard snapshot == nil else { return }
        let expected = revision
        do {
            let value = try await service.savedFilters()
            if revision == expected, !Task.isCancelled { snapshot = value }
        } catch is CancellationError {
        } catch {
            if revision == expected, !Task.isCancelled { self.error = ReaderMessages.error(error) }
        }
    }

    @discardableResult
    func change(_ change: SavedFilterChange) async -> Bool {
        guard let scope = snapshot?.scope, !saving else { return false }
        let expected = revision
        saving = true
        defer { saving = false }
        do {
            let value = try await service.changeSavedFilters(change, scope: scope)
            guard revision == expected else { return false }
            snapshot = value
            return true
        } catch is CancellationError {
            return false
        } catch {
            if revision == expected { self.error = ReaderMessages.error(error) }
            return false
        }
    }
}
