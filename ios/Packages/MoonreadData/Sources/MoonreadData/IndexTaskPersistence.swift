import Foundation
import GRDB

public struct FullIndexRequest: Sendable {
    public struct Queued: Codable, Sendable {
        public var shelf: String
        public var includeCloud: Bool
        public var scannedOnly: Bool?

        public init(shelf: String, includeCloud: Bool, scannedOnly: Bool? = nil) {
            self.shelf = shelf; self.includeCloud = includeCloud; self.scannedOnly = scannedOnly
        }
    }

    public var shelf: String
    public var includeCloud: Bool
    public var resume: Bool
    public var queued: [Queued]?
    public var scannedOnly: Bool?

    public init(shelf: String, includeCloud: Bool, resume: Bool, queued: [Queued]? = nil, scannedOnly: Bool? = nil) {
        self.shelf = shelf; self.includeCloud = includeCloud; self.resume = resume
        self.queued = queued; self.scannedOnly = scannedOnly
    }
}

extension DataSession {
    private struct Options: Codable, Sendable {
        let includeCloud: Bool
        let scannedOnly: Bool?
    }

    public func fullIndexRequest() throws -> FullIndexRequest? {
        try readDeviceTask { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT shelf,options,resume FROM main.full_index_request WHERE id=1") else { return nil }
            let options = try JSONDecoder().decode(Options.self, from: row["options"])
            let queue = try Data.fetchAll(db, sql: "SELECT item FROM main.full_index_queue ORDER BY position").map {
                try JSONDecoder().decode(FullIndexRequest.Queued.self, from: $0)
            }
            return FullIndexRequest(shelf: row["shelf"], includeCloud: options.includeCloud, resume: row["resume"],
                           queued: queue, scannedOnly: options.scannedOnly)
        }
    }

    public func saveFullIndexRequest(_ request: FullIndexRequest) throws {
        try writeDeviceTask { db in
            let options = Options(includeCloud: request.includeCloud, scannedOnly: request.scannedOnly)
            try db.execute(sql: """
                INSERT INTO main.full_index_request VALUES(1,?,?,?)
                ON CONFLICT(id) DO UPDATE SET shelf=excluded.shelf, options=excluded.options, resume=excluded.resume
                """, arguments: [request.shelf,try JSONEncoder().encode(options),request.resume])
            try db.execute(sql: "DELETE FROM main.full_index_queue")
            for (position, item) in (request.queued ?? []).enumerated() {
                try db.execute(sql: "INSERT INTO main.full_index_queue VALUES(?,?)",
                               arguments: [position,try JSONEncoder().encode(item)])
            }
        }
    }
}
