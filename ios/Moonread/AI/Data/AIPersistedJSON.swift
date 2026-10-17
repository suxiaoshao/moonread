import Foundation
import OSLog

/// Decode independently, but retain opaque elements on explicit writes. Never repair on read.
enum AIPersistedJSON {
    private static let logger = Logger(subsystem: "dev.moonread.Moonread", category: "Persistence")
    enum Failure: Error { case invalidContainer }

    static func skipped(_ key: String, index: Int) {
        // Do not log payloads, credentials, connection names or conversation text.
        logger.error("Skipped unreadable entry in \(key, privacy: .public) at index \(index)")
    }
    private static func object(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
    }
    private static func decode<T: Decodable>(_ object: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data(object))
    }
    private static func array(_ data: Data?) throws -> [Any] {
        guard let data else { return [] }
        guard let values = try object(data) as? [Any] else { throw Failure.invalidContainer }
        return values
    }
    static func readArray<T: Decodable>(_ type: T.Type, data: Data?, key: String) -> [T] {
        do {
            return try array(data).enumerated().compactMap { index, raw in
                do { return try decode(raw, as: type) }
                catch { skipped(key, index: index); return nil }
            }
        } catch { skipped(key, index: -1); return [] }
    }
    /// Match known rows by stable identity, update/remove those rows, preserve undecodable rows.
    static func encodeArray<T: Codable, ID: Hashable>(_ values: [T], original: Data?, id: (T) -> ID) throws -> Data {
        var remaining = values
        var result: [Any] = []
        for raw in try array(original) {
            guard let old = try? decode(raw, as: T.self) else { result.append(raw); continue }
            guard let index = remaining.firstIndex(where: { id($0) == id(old) }) else { continue }
            let new = remaining.remove(at: index)
            result.append(try merge(raw, old: object(JSONEncoder().encode(old)), new: object(JSONEncoder().encode(new))))
        }
        for value in remaining { result.append(try object(JSONEncoder().encode(value))) }
        return try data(result)
    }
    private static func dictionary(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let raw = try object(data)
        if let values = raw as? [String: Any] { return values }
        // Swift Codable dictionaries with enum keys have historically used alternating pairs.
        guard let pairs = raw as? [Any], pairs.count.isMultiple(of: 2) else { throw Failure.invalidContainer }
        var values: [String: Any] = [:]
        for index in stride(from: 0, to: pairs.count, by: 2) {
            guard let key = pairs[index] as? String, values[key] == nil else { throw Failure.invalidContainer }
            values[key] = pairs[index + 1]
        }
        return values
    }
    static func readDictionary<Key: RawRepresentable & Hashable, Value: Decodable>(
        _ type: Value.Type, data: Data?, key: String
    ) -> [Key: Value] where Key.RawValue == String {
        do {
            var result: [Key: Value] = [:]
            for (index, entry) in try dictionary(data).sorted(by: { $0.key < $1.key }).enumerated() {
                guard let known = Key(rawValue: entry.key), let value = try? decode(entry.value, as: type) else {
                    skipped(key, index: index); continue
                }
                result[known] = value
            }
            return result
        } catch { skipped(key, index: -1); return [:] }
    }
    static func encodeDictionary<Key: RawRepresentable & Hashable, Value: Codable>(
        _ values: [Key: Value], original: Data?
    ) throws -> Data where Key.RawValue == String {
        var result = try dictionary(original)
        var remaining = values
        for (key, raw) in result {
            guard let known = Key(rawValue: key), let old = try? decode(raw, as: Value.self) else { continue }
            if let new = remaining.removeValue(forKey: known) {
                result[key] = try merge(raw, old: object(JSONEncoder().encode(old)), new: object(JSONEncoder().encode(new)))
            } else { result.removeValue(forKey: key) }
        }
        for (key, value) in remaining {
            result[key.rawValue] = try object(JSONEncoder().encode(value))
        }
        return try data(result)
    }
    /// Preserve fields this version did not decode; remove only known fields the user cleared.
    private static func merge(_ raw: Any, old: Any, new: Any) -> Any {
        guard var result = raw as? [String: Any], let old = old as? [String: Any], let new = new as? [String: Any] else { return new }
        for key in old.keys where new[key] == nil { result.removeValue(forKey: key) }
        for (key, value) in new {
            if let prior = old[key], let original = result[key] { result[key] = merge(original, old: prior, new: value) }
            else { result[key] = value }
        }
        return result
    }
}
