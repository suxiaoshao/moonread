import Foundation

struct AIUsageSnapshot: Equatable, Sendable {
    struct Wallet: Equatable, Sendable {
        let currency: String
        let total: Decimal
        let toppedUp: Decimal
        let granted: Decimal
    }

    enum KeyLimit: Equatable, Sendable {
        case unlimited, limited(amount: Decimal, remaining: Decimal?)
    }

    enum Reset: Equatable, Sendable {
        case daily, weekly, monthly, none, unknown
    }

    enum Usage: Equatable, Sendable {
        case wallet([Wallet], serviceAvailable: Bool)
        case keyLimit(KeyLimit, cumulative: Decimal, reset: Reset, includesBYOK: Bool?)
        case gateway(balance: Decimal, cumulative: Decimal)
    }

    let usage: Usage
    let fetchedAt: Date
    var staleAt: Date { fetchedAt.addingTimeInterval(5 * 60) }
}
