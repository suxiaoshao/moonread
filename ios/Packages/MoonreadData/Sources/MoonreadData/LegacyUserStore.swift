import Foundation

/// Paged, read-only projection of one already-frozen SwiftData store. The
/// host owns the store and its published model identities.
public struct LegacyUserStore: Sendable {
    public struct Cover: Sendable {
        public let id: String
        public let bytes: Data?
        public init(id: String, bytes: Data?) { self.id = id; self.bytes = bytes }
    }

    public struct Value: Sendable {
        public let key: String
        public let device: String
        public let payload: String
        public init(key: String, device: String, payload: String) {
            self.key = key; self.device = device; self.payload = payload
        }
    }

    public struct Position: Sendable {
        public let contentKey: String
        public let payload: String
        public init(contentKey: String, payload: String) { self.contentKey = contentKey; self.payload = payload }
    }

    public struct Annotation: Sendable {
        public let id: String
        public let contentKey: String
        public let markID: String
        public let payload: String
        public init(id: String, contentKey: String, markID: String, payload: String) {
            self.id = id; self.contentKey = contentKey; self.markID = markID; self.payload = payload
        }
    }

    public struct Fact: Sendable {
        public let id: String
        public let contentKey: String
        public let payload: String
        public init(id: String, contentKey: String, payload: String) {
            self.id = id; self.contentKey = contentKey; self.payload = payload
        }
    }

    public struct Reader {
        public typealias Page<Row> = (_ offset: Int, _ limit: Int) throws -> [Row]
        let covers: Page<Cover>
        let values: Page<Value>
        let positions: Page<Position>
        let annotations: Page<Annotation>
        let facts: Page<Fact>
        let clears: Page<String>

        public init(covers: @escaping Page<Cover>, values: @escaping Page<Value>,
                    positions: @escaping Page<Position>, annotations: @escaping Page<Annotation>,
                    facts: @escaping Page<Fact>, clears: @escaping Page<String>) {
            self.covers = covers
            self.values = values
            self.positions = positions
            self.annotations = annotations
            self.facts = facts
            self.clears = clears
        }
    }

    let count: @Sendable () throws -> Int
    let makeReader: @Sendable () -> Reader

    public init(count: @escaping @Sendable () throws -> Int, makeReader: @escaping @Sendable () -> Reader) {
        self.count = count
        self.makeReader = makeReader
    }
}
