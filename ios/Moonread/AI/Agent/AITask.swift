import Foundation
import Observation

enum AICoverMode: String, Codable, Hashable, Sendable { case find, generate }
enum AITaskKind: Codable, Hashable, Sendable {
    case metadata, cover(mode: AICoverMode), organization, statistics
    var purpose: String {
        switch self {
        case .metadata: String(localized: "完善资料")
        case .cover(.find): String(localized: "查找封面")
        case .cover(.generate): String(localized: "生成封面")
        case .organization: String(localized: "整理")
        case .statistics: String(localized: "分析阅读")
        }
    }
    func initialRequest(_ supplement: String) -> String {
        let supplement = supplement.trimmingCharacters(in: .whitespacesAndNewlines)
        return purpose + (supplement.isEmpty ? "" : "\n" + supplement)
    }
}
struct AITaskOrigin: Codable, Hashable, Sendable {
    enum Object: Hashable, Sendable {
        case book(bookSHA: String?, fileRef: String?)
        case file(String), files(Set<String>), folder(String)
        case statistics(from: String, to: String, bookSHA: String?)
    }
    var object: Object
    init(bookSHA: String?, fileRef: String? = nil) { object = .book(bookSHA: fileRef == nil ? bookSHA : nil, fileRef: fileRef) }
    init(fileRef: String) { object = .book(bookSHA: nil, fileRef: fileRef) }
    init(fileRefs: Set<String>) { object = .files(fileRefs) }
    init(scopeRef: String) { object = .folder(scopeRef) }
    init(from: String, to: String, bookSHA: String? = nil) { object = .statistics(from: from, to: to, bookSHA: bookSHA) }
    private enum Keys: String, CodingKey { case type, sha, file, files, scope, from, to }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "book": self.init(bookSHA: try c.decodeIfPresent(String.self, forKey: .sha), fileRef: try c.decodeIfPresent(String.self, forKey: .file))
        case "files": self.init(fileRefs: Set(try c.decode([String].self, forKey: .files)))
        case "folder": self.init(scopeRef: try c.decode(String.self, forKey: .scope))
        case "statistics": self.init(from: try c.decode(String.self, forKey: .from), to: try c.decode(String.self, forKey: .to), bookSHA: try c.decodeIfPresent(String.self, forKey: .sha))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Invalid entry locator")
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch object {
        case .book(let sha, let file):
            try c.encode("book", forKey: .type); try c.encodeIfPresent(file, forKey: .file)
            if file == nil { try c.encodeIfPresent(sha, forKey: .sha) }
        case .file(let file): try c.encode("book", forKey: .type); try c.encode(file, forKey: .file)
        case .files(let files): try c.encode("files", forKey: .type); try c.encode(files.sorted(), forKey: .files)
        case .folder(let scope): try c.encode("folder", forKey: .type); try c.encode(scope, forKey: .scope)
        case .statistics(let from, let to, let sha):
            try c.encode("statistics", forKey: .type); try c.encode(from, forKey: .from); try c.encode(to, forKey: .to); try c.encodeIfPresent(sha, forKey: .sha)
        }
    }
    func locator() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
