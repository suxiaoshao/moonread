import Foundation
import Observation

/// A superseded query cannot dismiss the next query's loading state.
@MainActor @Observable public final class LoadingState {
    public private(set) var request: UUID?
    public init() {}
    public var active: Bool { request != nil }
    @discardableResult public func begin() -> UUID { let id = UUID(); request = id; return id }
    public func finish(_ id: UUID) { if request == id { request = nil } }
}
