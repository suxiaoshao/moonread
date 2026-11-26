import MoonreadDataTypes
import MoonreadCoreBindings
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
    /// A suggestion reads only the selected position, its device baseline
    /// and, if distant enough, the heading at the target.
    func readingResumeContext(_ id: String, currentOffset: UInt64? = nil) async throws -> ReadingResumeContext {
        let configuration = userCloudConfigurationRevision
        guard let resume = try await fixedReaderRead({ try $0.readerResume(id, currentOffset: currentOffset) }) else {
            return .init(localOffset: nil, candidate: nil)
        }
        return .init(localOffset: resume.localOffset,
                     candidate: .init(contentSHA: resume.key, token: resume.token, configuration: configuration, location: resume.location))
    }
}
