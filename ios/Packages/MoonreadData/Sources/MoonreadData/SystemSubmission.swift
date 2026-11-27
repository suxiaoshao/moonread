import Foundation
import GRDB

public struct SystemSubmissionState: Sendable {
    public var scope: String
    public var contentVersion: Int
    public var ids: [String]

    public init(scope: String, contentVersion: Int = 0, ids: [String] = []) {
        self.scope = scope
        self.contentVersion = contentVersion
        self.ids = ids
    }
}

extension ReaderIndex {
    public func systemSubmission(_ kind: String) throws -> SystemSubmissionState {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT scope,format FROM main.system_submission_state WHERE kind=?
                """, arguments: [kind]) else { return .init(scope: "") }
            let ids = try String.fetchAll(db, sql: """
                SELECT item_id FROM main.system_submission_item WHERE kind=? ORDER BY item_id
                """, arguments: [kind])
            return .init(scope: row["scope"], contentVersion: row["format"], ids: ids)
        }
    }

    public func saveSystemSubmission(_ kind: String, state: SystemSubmissionState) throws {
        try write { db in
            try db.execute(sql: """
                INSERT INTO main.system_submission_state VALUES(?,?,?)
                ON CONFLICT(kind) DO UPDATE SET scope=excluded.scope, format=excluded.format
                """, arguments: [kind,state.scope,state.contentVersion])
            try db.execute(sql: "DELETE FROM main.system_submission_item WHERE kind=?", arguments: [kind])
            for id in state.ids {
                try db.execute(sql: "INSERT INTO main.system_submission_item VALUES(?,?)", arguments: [kind,id])
            }
        }
    }

    public func systemCatalogScope() throws -> String {
        try write { db in
            if let scope = try String.fetchOne(db, sql: "SELECT scope FROM main.system_catalog_state") { return scope }
            let scope = UUID().uuidString
            try db.execute(sql: "INSERT INTO main.system_catalog_state VALUES(1,?)", arguments: [scope])
            return scope
        }
    }


}
