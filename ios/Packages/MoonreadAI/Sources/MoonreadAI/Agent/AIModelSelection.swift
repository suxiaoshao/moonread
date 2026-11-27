import Foundation

public struct AIModelSelection: Equatable {
    public var connectionID: String
    public var modelID: String
    public var thinking: String?
    public init(connectionID: String, modelID: String, thinking: String? = nil) {
        self.connectionID = connectionID; self.modelID = modelID; self.thinking = thinking
    }
    public static func defaultThinking(_ model: AIModelOption) -> String? {
        model.defaultThinking.flatMap { model.thinking.contains($0) ? $0 : nil }
    }
    public mutating func select(_ model: AIModelOption, connection: AIConnection) {
        if connectionID != connection.id || modelID != model.id {
            connectionID = connection.id; modelID = model.id; thinking = Self.defaultThinking(model)
        } else { thinking = thinking.flatMap { model.thinking.contains($0) ? $0 : nil } ?? Self.defaultThinking(model) }
    }
}
public enum AIModelSelectionTarget: Equatable { case conversation(String), session(String), defaults }

public extension AIModelSelectionTarget {
    var isDefault: Bool { if case .defaults = self { true } else { false } }
}
