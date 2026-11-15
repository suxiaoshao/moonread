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
    /// Promotion uses the existing unique position winner; no second reduction
    /// or max-offset policy is introduced for a continuation suggestion.
    func readingResumeContext(_ id: String, currentOffset: UInt64? = nil) async throws -> ReadingResumeContext {
        let configuration = userCloudConfigurationRevision
        try await promoteUserData(id)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        guard case .formal(let key) = try userKey(id) else { return .init(localOffset: nil, candidate: nil) }
        guard let basis = try relationalUserIndex().readingResumeBasis(sha: key) else {
            return .init(localOffset: nil, candidate: nil)
        }
        let localOffset = currentOffset ?? basis.local.offset
        let query = try await bookQuery(id)
        let location = try query.readingContinuation(bookId: id, localOffset: localOffset, winningOffset: basis.winner.value.offset)
        guard configuration == userCloudConfigurationRevision else { throw CancellationError() }
        return ReadingResumeContext(localOffset: location == nil ? nil : localOffset,
            candidate: location.map { .init(contentSHA: key, token: basis.winner.token, configuration: configuration, location: $0) })
    }
}
