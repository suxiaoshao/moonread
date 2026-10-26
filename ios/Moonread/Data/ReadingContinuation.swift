import Foundation

/// Device-only evidence of an actual local write, never a competing sync fact.
struct LocalReadingResumeState: Codable {
    struct Entry: Codable, Sendable {
        var offset: UInt64
        var lastLocalWriteToken: String?
    }
    static let key = "Moonread.localReadingResume.v1"
    var schemaVersion = 1
    var scopes: [String: [String: Entry]] = [:]
    init(data: Data?) throws {
        if let data {
            self = try JSONDecoder().decode(Self.self, from: data)
            guard schemaVersion == 1 else { throw UserSyncCompatibilityError() }
        }
    }
}

struct ReadingContinuationCandidate: Sendable {
    let contentSHA: String
    let token: String
    let configuration: UUID
    let location: ReadingContinuation
}
struct ReadingResumeContext: Sendable {
    let localOffset: UInt64?
    let candidate: ReadingContinuationCandidate?
}

extension Notification.Name {
    static let cloudReadingPositionsReceived = Notification.Name("Moonread.cloudReadingPositionsReceived")
    static let readingContinuationInvalidated = Notification.Name("Moonread.readingContinuationInvalidated")
}

extension AppDataService {
    private var localResumeScope: String { userDirectoryName + "/" + (userCloudOwner() ?? "local") }

    func rememberLocalReadingPosition(key: String, offset: UInt64, token: String) throws {
        guard case .formal = try parseReadingKey(value: key) else { return }
        var state = try LocalReadingResumeState(data: sourceDefaults.data(forKey: LocalReadingResumeState.key))
        var entries = state.scopes[localResumeScope] ?? [:]
        entries[key] = .init(offset: offset, lastLocalWriteToken: token)
        state.scopes[localResumeScope] = entries
        sourceDefaults.set(try JSONEncoder().encode(state), forKey: LocalReadingResumeState.key)
    }

    /// Promotion uses the existing unique position winner; no second reduction
    /// or max-offset policy is introduced for a continuation suggestion.
    func readingResumeContext(_ id: String, currentOffset: UInt64? = nil) async throws -> ReadingResumeContext {
        let configuration = userCloudConfigurationRevision
        try await promoteUserData(id)
        let key = try userKey(id)
        guard case .formal = try parseReadingKey(value: key) else { return .init(localOffset: nil, candidate: nil) }
        let state = try LocalReadingResumeState(data: sourceDefaults.data(forKey: LocalReadingResumeState.key))
        guard let local = state.scopes[localResumeScope]?[key], let localToken = local.lastLocalWriteToken else {
            return .init(localOffset: nil, candidate: nil)
        }
        let stored = try await userStore().storedValue("position/" + key)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        guard let stored, stored.token != localToken else { return .init(localOffset: nil, candidate: nil) }
        let winner = try PositionCandidate(stored)
        let localOffset = currentOffset ?? local.offset
        let query = try await bookQuery(id)
        let location = try query.readingContinuation(bookId: id, localOffset: localOffset, winningOffset: winner.value.offset)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return ReadingResumeContext(localOffset: location == nil ? nil : localOffset,
            candidate: location.map { .init(contentSHA: key, token: stored.token, configuration: configuration, location: $0) })
    }
}
