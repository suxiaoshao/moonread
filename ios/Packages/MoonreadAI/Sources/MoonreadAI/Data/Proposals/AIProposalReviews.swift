import Foundation

public struct AICoverCandidate: Identifiable, Sendable {
    public let proposalRef: String
    public let attachment: AIImageAttachment
    public var origin: AIImageOrigin
    public init(proposalRef: String, attachment: AIImageAttachment, origin: AIImageOrigin) { self.proposalRef = proposalRef; self.attachment = attachment; self.origin = origin }
    public var id: String { attachment.attachmentRef }
    public var attachmentRef: String { attachment.attachmentRef }
    public var width: Int { attachment.width }
    public var height: Int { attachment.height }
    public var source: AIWebSource? { origin.webSource }
    public var domain: String? { source.flatMap { URL(string: $0.url)?.host } }
}
