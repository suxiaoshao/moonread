import Foundation
import GRDB
import MoonreadCoreBindings

public struct HandoffAssociation: Codable, Sendable {
    public let fileID: String
    public let bookID: String?
    public let decoding: String
    public init(fileID: String, bookID: String?, decoding: String) {
        self.fileID = fileID
        self.bookID = bookID
        self.decoding = decoding
    }
}

public struct CloudHandoffReceipt: Codable, Sendable {
    enum Stage: String, Codable, Sendable { case intent, copied, published }
    private(set) var stage: Stage
    public let bytesHash: String
    public var association: HandoffAssociation?
    public var copied: Bool { stage == .copied || stage == .published }
    public var published: Bool { stage == .published }

    public init(bytesHash: String, association: HandoffAssociation? = nil) {
        stage = .intent; self.bytesHash = bytesHash; self.association = association
    }
    public mutating func recordCopy() throws {
        switch stage {
        case .intent: stage = .copied
        case .copied, .published: break
        }
    }
    public mutating func recordPublication() throws {
        switch stage {
        case .copied: stage = .published
        case .published: break
        case .intent: throw ReaderError.SourceChanged
        }
    }

}

extension ReaderIndex {
    public func cloudHandoffReceipts(owner: String) throws -> [String: CloudHandoffReceipt] {
        try read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
                SELECT relative_path,receipt FROM main.cloud_file_handoff WHERE owner=?
                """, arguments: [owner]).map {
                    ($0["relative_path"], try JSONDecoder().decode(CloudHandoffReceipt.self, from: $0["receipt"]))
                })
        }
    }

    public func saveCloudHandoffReceipts(_ receipts: [String: CloudHandoffReceipt], owner: String) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM main.cloud_file_handoff WHERE owner=?", arguments: [owner])
            for (path, receipt) in receipts {
                try db.execute(sql: "INSERT INTO main.cloud_file_handoff VALUES(?,?,?)",
                               arguments: [owner,path,try JSONEncoder().encode(receipt)])
            }
        }
    }
}
