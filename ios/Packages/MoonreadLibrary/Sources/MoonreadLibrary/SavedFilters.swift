import Foundation
import MoonreadData
import MoonreadDataTypes
import Observation

@MainActor @Observable public final class SavedFilters {
    public private(set) var snapshot: SavedFilterSnapshot?
    public private(set) var revision = 0
    public private(set) var saving = false
    public var error: String?
    private let read: () async throws -> SavedFilterSnapshot
    private let write: (SavedFilterChange, DataScope) async throws -> SavedFilterSnapshot
    private let describeError: (Error) -> String

    public init(read: @escaping () async throws -> SavedFilterSnapshot,
                write: @escaping (SavedFilterChange, DataScope) async throws -> SavedFilterSnapshot,
                describeError: @escaping (Error) -> String) {
        self.read = read; self.write = write; self.describeError = describeError
    }

    public var entries: [SavedFilter] { snapshot?.entries ?? [] }

    public func rebind() {
        snapshot = nil
        error = nil
        revision += 1
    }

    public func load() async {
        guard snapshot == nil else { return }
        let expected = revision
        do {
            let value = try await read()
            if revision == expected, !Task.isCancelled { snapshot = value }
        } catch is CancellationError {
        } catch {
            if revision == expected, !Task.isCancelled { self.error = describeError(error) }
        }
    }

    @discardableResult
    public func change(_ change: SavedFilterChange) async -> Bool {
        guard let scope = snapshot?.scope, !saving else { return false }
        let expected = revision
        saving = true
        defer { saving = false }
        do {
            let value = try await write(change, scope)
            guard revision == expected else { return false }
            snapshot = value
            return true
        } catch is CancellationError {
            return false
        } catch {
            if revision == expected { self.error = describeError(error) }
            return false
        }
    }
}
