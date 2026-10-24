import Foundation
import OSLog

/// A read barrier, not a lossy repair. Quarantined records remain in SwiftData unchanged.
struct UserSyncCompatibilityError: LocalizedError, Sendable {
    var statistics = false
    var errorDescription: String? {
        statistics ? String(localized: "统计数据来自更新版本，请更新 App。") :
            String(localized: "部分阅读数据当前版本无法理解，已保留并设为只读，请更新 App。")
    }
}

/// Wire validation belongs here, never in the UniFFI records. No floating-point JSON
/// intermediate: JSONDecoder reads every integer directly into its declared width.
enum UserSyncJSON {
    struct CoverReference: Decodable { let id: String; let sha256: String }
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    indirect enum Shape: Sendable {
        case string, uint, int, uint32, int32, bool
        case choice(Set<String>), nullable(Shape), array(Shape), object([String: Shape])
    }
    enum ValueKind { case position, chapter, author, synopsis, status, cover, tag, palette, shelfReference }
    static func kind(_ key: String) -> ValueKind? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        if parts.count == 2 {
            switch parts[0] {
            case "position": return .position
            case "palette": return .palette
            case "shelf-reference": return UUID(uuidString: String(parts[1])) == nil ? nil : .shelfReference
            default: return nil
            }
        }
        guard parts.count == 3 else { return nil }
        if parts[0] == "chapter", UInt64(parts[2]) != nil { return .chapter }
        guard parts[0] == "metadata" else { return nil }
        switch parts[2] {
        case "author": return .author
        case "synopsis": return .synopsis
        case "status": return .status
        case "cover": return .cover
        default: return parts[2].hasPrefix("tag-") ? .tag : nil
        }
    }

    static let stored: Shape = .object(["updated": .int, "token": .string, "value": .string])
    static let sourceHint: Shape = .object(["source_kind": .choice(["managed_icloud", "managed_local", "external"]),
        "relative_path": .string, "file_name": .string, "byte_size": .nullable(.uint), "decoding": .string])
    static let position: Shape = .object(["content_key": .string, "offset": .uint, "source_hint": .nullable(sourceHint)])
    static let chapter: Shape = .object(["content_key": .string, "offset": .uint, "title": .string, "level": .uint32, "excluded": .bool])
    static let content: Shape = .object(["start": .uint, "end": .uint, "excerpt": .string, "note": .string])
    static let candidate: Shape = .object(["id": .string, "ancestors": .array(.string), "content": .nullable(content), "created": .uint,
                                          "bookmark": .bool, "relatedMarks": .array(.string), "mergedInto": .nullable(.string)])
    static let clear: Shape = .object(["book": .nullable(.string), "session": .nullable(.string), "through": .int, "ids": .array(.string)])
    static let cover: Shape = .object(["id": .string, "sha256": .string, "extension": .string, "width": .uint32, "height": .uint32])
    static let exposure: Shape = .object(["start_utf8": .uint, "end_utf8": .uint, "duration_ms": .uint])
    static let slice: Shape = .object(["id": .string, "session_id": .string, "visit_id": .string, "book_id": .string,
                                      "started_ms": .int, "ended_ms": .int, "local_day": .int, "utc_offset_seconds": .int32,
                                      "preview": .bool, "exposures": .array(exposure)])
    static let fact: Shape = .object(["content_key": .string, "title": .string, "device": .string, "slice": slice])
    private static let colorNames = "canvas surface raised input paper ink secondary disabled accent accent_surface on_accent border separator focus pressed selected annotation search search_current selection destructive on_destructive warning success moon maria".split(separator: " ").map(String.init)
    static let palette: Shape = .object(["id": .string, "name": .string, "appearance": .choice(["Light", "Dark"]), "custom": .bool,
                                        "colors": .object(Dictionary(uniqueKeysWithValues: colorNames.map { ($0, .uint32) })),
                                        "high_contrast": .object(Dictionary(uniqueKeysWithValues: colorNames.map { ($0, .uint32) }))])
    private struct Configuration { let shape: Shape; let envelope: Bool }
    private static let schemaKey = CodingUserInfoKey(rawValue: "Moonread.sync.schema")!
    private struct Validation: Decodable {
        init(from decoder: Decoder) throws {
            guard let configuration = decoder.userInfo[schemaKey] as? Configuration else { throw UserSyncCompatibilityError() }
            try validate(decoder, shape: configuration.shape, envelope: configuration.envelope)
        }
    }
    static func validate(_ text: String, as shape: Shape, envelope: Bool = false) throws {
        do {
            let decoder = JSONDecoder()
            decoder.userInfo[schemaKey] = Configuration(shape: shape, envelope: envelope)
            _ = try decoder.decode(Validation.self, from: Data(text.utf8))
        } catch { throw UserSyncCompatibilityError() }
    }
    private static func validate(_ decoder: Decoder, shape: Shape, envelope: Bool = false) throws {
        switch shape {
        case .object(let fields):
            let container = try decoder.container(keyedBy: Key.self)
            let actual = Set(container.allKeys.map(\.stringValue)), required = Set(fields.keys)
            guard required.isSubset(of: actual), actual.isSubset(of: envelope ? required.union(["v"]) : required) else { throw UserSyncCompatibilityError() }
            if envelope, container.contains(Key("v")) {
                guard try container.decode(Int.self, forKey: Key("v")) == 1 else { throw UserSyncCompatibilityError() }
            }
            for (key, nested) in fields { try validate(container.superDecoder(forKey: Key(key)), shape: nested) }
        case .array(let element):
            var container = try decoder.unkeyedContainer()
            while !container.isAtEnd { try validate(container.superDecoder(), shape: element) }
        case .nullable(let element):
            if !(try decoder.singleValueContainer().decodeNil()) { try validate(decoder, shape: element) }
        case .choice(let allowed):
            guard try allowed.contains(decoder.singleValueContainer().decode(String.self)) else { throw UserSyncCompatibilityError() }
        case .string: _ = try decoder.singleValueContainer().decode(String.self)
        case .bool: _ = try decoder.singleValueContainer().decode(Bool.self)
        case .uint: _ = try decoder.singleValueContainer().decode(UInt64.self)
        case .int: _ = try decoder.singleValueContainer().decode(Int64.self)
        case .uint32: _ = try decoder.singleValueContainer().decode(UInt32.self)
        case .int32: _ = try decoder.singleValueContainer().decode(Int32.self)
        }
    }
    static func decode<T: Decodable>(_ type: T.Type, _ text: String, as shape: Shape, envelope: Bool = false) throws -> T {
        try validate(text, as: shape, envelope: envelope)
        let value = try JSONDecoder().decode(type, from: Data(text.utf8))
        if let position = value as? PositionValue, let hint = position.source_hint {
            guard hint.isValid, (try? normalizeSourceDecoding(decoding: hint.decoding)) == hint.decoding else { throw UserSyncCompatibilityError() }
        }
        return value
    }
    /// Add only a top-level version, without parsing/re-encoding integer payloads.
    static func envelope(_ object: String) throws -> String {
        let object = object.trimmingCharacters(in: .whitespacesAndNewlines)
        guard object.first == "{", object.last == "}" else { throw UserSyncCompatibilityError() }
        return object == "{}" ? "{\"v\":1}" : "{\"v\":1," + object.dropFirst()
    }
    private struct VersionPresence: Decodable {
        let present: Bool
        init(from decoder: Decoder) throws { present = try decoder.container(keyedBy: Key.self).contains(.init("v")) }
    }
    static func versioned(_ text: String) throws -> String {
        try JSONDecoder().decode(VersionPresence.self, from: Data(text.utf8)).present ? text : envelope(text)
    }
    static func encode<T: Encodable>(_ value: T, envelope: Bool = false) throws -> String {
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        return envelope ? try Self.envelope(text) : text
    }
    static func validateValue(_ text: String, key: String) throws {
        guard let kind = kind(key) else { throw UserSyncCompatibilityError() }
        switch kind {
        case .position:
            let value = try decode(PositionValue.self, text, as: position)
            guard "position/" + value.content_key == key else { throw UserSyncCompatibilityError() }
        case .chapter:
            if text == "null" { return }
            let value = try decode(ChapterValue.self, text, as: chapter)
            guard "chapter/\(value.content_key)/\(value.offset)" == key else { throw UserSyncCompatibilityError() }
        case .shelfReference:
            let value = try decode(ShelfReferenceValue.self, text, as: .object(["schemaVersion": .uint, "name": .string, "locationDescription": .choice(["icloud-drive", "file-provider"])]))
            guard value.schemaVersion == 1 else { throw UserSyncCompatibilityError() }
        case .cover: try validate(text, as: .nullable(cover))
        case .tag: try validate(text, as: .nullable(.string))
        case .author, .synopsis, .status: try validate(text, as: .string)
        case .palette:
            try validate(text, as: .nullable(palette))
            if text != "null" {
                do { _ = try decodeThemePalette(json: text) }
                catch { throw UserSyncCompatibilityError() }
            }
        }
    }
    static func storedValue(_ payload: String, key: String) throws -> StoredValue {
        let value = try decode(StoredValue.self, payload, as: stored, envelope: true)
        guard !value.token.isEmpty else { throw UserSyncCompatibilityError() }
        try validateValue(value.value, key: key)
        return value
    }
    static func annotation(_ payload: String, id: String) throws -> AnnotationCandidate {
        let value = try decode(AnnotationCandidate.self, payload, as: candidate, envelope: true)
        guard value.id == id, !id.isEmpty else { throw UserSyncCompatibilityError() }
        return value
    }
    private struct FactIdentity: Decodable {
        struct Slice: Decodable { let id: String }
        let slice: Slice
    }
    static func validateFact(_ payload: String, id: String) throws {
        try validate(payload, as: fact, envelope: true)
        guard try JSONDecoder().decode(FactIdentity.self, from: Data(payload.utf8)).slice.id == id, !id.isEmpty else { throw UserSyncCompatibilityError() }
    }
    static func quarantined(_ type: String) {
        Logger(subsystem: "dev.moonread.Moonread", category: "SyncCompatibility").error("Quarantined unsupported \(type, privacy: .public) record")
    }
}

/// Scope can be trusted only when both keys are present and have the declared type.
/// A malformed scope is conservatively global; never interpret a missing key as null.
struct UserSyncClearScope: Decodable, Sendable {
    let book: String?
    let session: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: UserSyncJSON.Key.self)
        guard container.contains(.init("book")), container.contains(.init("session")) else { throw UserSyncCompatibilityError(statistics: true) }
        book = try container.decode(String?.self, forKey: .init("book"))
        session = try container.decode(String?.self, forKey: .init("session"))
        guard book != "", session != "" else { throw UserSyncCompatibilityError(statistics: true) }
    }
    func intersects(book: String?, session: String?) -> Bool {
        (self.book == nil || book == nil || self.book == book) && (self.session == nil || session == nil || self.session == session)
    }
}
