import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

public struct ReadingContinuationCandidate: Sendable {
    public let contentSHA: String
    public let token: String
    public let configuration: UUID
    public let location: ReadingContinuation

    public init(contentSHA: String, token: String, configuration: UUID, location: ReadingContinuation) {
        self.contentSHA = contentSHA
        self.token = token
        self.configuration = configuration
        self.location = location
    }
}
public struct ReadingResumeContext: Sendable {
    public let localOffset: UInt64?
    public let candidate: ReadingContinuationCandidate?

    public init(localOffset: UInt64?, candidate: ReadingContinuationCandidate?) {
        self.localOffset = localOffset
        self.candidate = candidate
    }
}
