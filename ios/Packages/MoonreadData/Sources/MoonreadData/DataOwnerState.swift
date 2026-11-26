import Foundation
import MoonreadDataTypes

public struct DataOwnerState: Codable, Equatable {
    public struct Move: Codable, Equatable {
        public let id: UUID
        public let target: DataScope

        public init(id: UUID, target: DataScope) {
            self.id = id
            self.target = target
        }
    }
    var version = 1
    public var current: DataScope = .local
    public var lastConfirmed: DataScope?
    public var ownedIndex = false
    public var move: Move?

    public static func load(at url: URL) throws -> Self {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .init() }
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.version == 1, state.current.valid,
              state.lastConfirmed.map({ $0.valid && $0 != .local }) ?? true,
              state.move.map({ $0.target.valid && $0.target != .local }) ?? true else {
            throw DataV2Error.invalidOwnerState
        }
        return state
    }

    public func save(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    public func plan(_ status: DataIdentityStatus) throws -> (DataScopeSelection, DataScope?, DataOwnerState) {
        let next: DataScopeSelection
        let verified: DataScope?
        var state = self
        switch status {
        case .paused, .unknown:
            verified = nil
            next = .init(scope: lastConfirmed ?? .local, maySync: false)
        case .signedOut:
            verified = nil
            state.lastConfirmed = nil
            next = .init(scope: .local, maySync: false)
        case .confirmed(let scope, let requested, _):
            guard scope.valid, scope != .local else { throw DataV2Error.invalidOwnerState }
            verified = scope
            if lastConfirmed == nil {
                // Discovering the system account does not claim unassigned
                // data or authorize sync. The enable/consent path calls claimLocal.
                next = .init(scope: .local, maySync: false)
            } else {
                state.lastConfirmed = scope
                next = .init(scope: scope, maySync: requested)
            }
        }
        return (next, verified, state)
    }
}
