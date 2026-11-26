import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import GRDB
import SwiftUI

/// A description is syncable; a bookmark and the local shelf UUID are not.
public struct ShelfReferenceValue: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name: String
    var locationDescription: String

    public init(schemaVersion: Int = 1, name: String, locationDescription: String) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.locationDescription = locationDescription
    }
}

public struct ShelfReference: Identifiable, Equatable, Sendable {
    public let id: String
    public let value: ShelfReferenceValue
    public var locationLabel: String {
        value.locationDescription == "icloud-drive" ? String(localized: "iCloud Drive") : String(localized: "其他文件提供方", table: "ShelfRecovery")
    }

    public init(id: String, value: ShelfReferenceValue) {
        self.id = id
        self.value = value
    }
}

/// Device-only authorization and acknowledgement. Missing data is the v1 initial
/// state; an unknown version is never overwritten by an older installation.
public struct ShelfReferenceBindings: Codable, Equatable {
    public struct Scope: Codable, Equatable, Sendable {
        public var bindings: [String: String] = [:]
        public var ignored: Set<String> = []
        public var guided: Set<String> = []
        public var recovery: Set<String>? = nil
        public var published: [String: ShelfReferenceValue]? = nil
    }
    public var schemaVersion = 1
    public var scopes: [String: Scope] = [:]
    public static let key = "Moonread.shelfReferenceBindings.v1"
    public init(data: Data?) throws {
        if let data {
            self = try JSONDecoder().decode(Self.self, from: data)
            guard schemaVersion == 1 else { throw UserSyncCompatibilityError() }
        }
    }
    public static func read(_ db: Database) throws -> Scope {
        var scope = Scope()
        for row in try Row.fetchAll(db, sql: "SELECT key,kind,value FROM usr.local_shelf_recovery") {
            let key: String = row["key"]
            let kind: String = row["kind"]
            switch kind {
            case "binding":
                scope.bindings[key] = try JSONDecoder().decode(String.self, from: row["value"])
            case "ignored": scope.ignored.insert(key)
            case "guided": scope.guided.insert(key)
            case "recovery": scope.recovery = (scope.recovery ?? []).union([key])
            case "published":
                if scope.published == nil { scope.published = [:] }
                scope.published?[key] = try JSONDecoder().decode(ShelfReferenceValue.self, from: row["value"])
            default: throw UserSyncCompatibilityError()
            }
        }
        return scope
    }

    public static func write(_ db: Database, scope: Scope) throws {
        try db.execute(sql: "DELETE FROM usr.local_shelf_recovery")
        func insert(_ key: String, _ kind: String, value: Data? = nil) throws {
            try db.execute(sql: "INSERT INTO usr.local_shelf_recovery VALUES(?,?,?)", arguments: [key,kind,value])
        }
        for (key, value) in scope.bindings { try insert(key,"binding",value: JSONEncoder().encode(value)) }
        for key in scope.ignored { try insert(key,"ignored") }
        for key in scope.guided { try insert(key,"guided") }
        for key in scope.recovery ?? [] { try insert(key,"recovery") }
        for (key, value) in scope.published ?? [:] { try insert(key,"published",value: JSONEncoder().encode(value)) }
    }
}
