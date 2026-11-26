import MoonreadCoreBindings
import MoonreadDataTypes
import Foundation

public enum ReaderRoute: Hashable, Sendable {
    public struct CachedBookID: Hashable, Sendable { public let value: String }
    case book(cache: CachedBookID)
    case source(SourceFile)
    public static func book(_ id: String) -> Self { .book(cache: .init(value: id)) }
    public var title: String { if case let .source(file) = self { return file.title }; return String(localized: "阅读") }
}
