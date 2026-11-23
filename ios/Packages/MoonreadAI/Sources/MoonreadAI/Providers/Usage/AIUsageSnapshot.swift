import Foundation

public struct AIUsageSnapshot: Equatable, Sendable {
    public struct Wallet: Equatable, Sendable {
        public let currency: String
        public let total: Decimal
        public let toppedUp: Decimal
        public let granted: Decimal
    }

    public enum KeyLimit: Equatable, Sendable {
        case unlimited, limited(amount: Decimal, remaining: Decimal?)
    }

    public enum Reset: Equatable, Sendable {
        case daily, weekly, monthly, none, unknown
    }

    public enum Usage: Equatable, Sendable {
        case wallet([Wallet], serviceAvailable: Bool)
        case keyLimit(KeyLimit, cumulative: Decimal, reset: Reset, includesBYOK: Bool?)
        case gateway(balance: Decimal, cumulative: Decimal)
    }

    public let usage: Usage
    public let fetchedAt: Date
    public var staleAt: Date { fetchedAt.addingTimeInterval(5 * 60) }
}
