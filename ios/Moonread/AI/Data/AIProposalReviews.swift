import Foundation

struct AICoverCandidate: Identifiable, Sendable {
    let proposalRef: String
    let attachment: AIImageAttachment
    var origin: AIImageOrigin
    var id: String { attachment.attachmentRef }
    var attachmentRef: String { attachment.attachmentRef }
    var width: Int { attachment.width }
    var height: Int { attachment.height }
    var source: AIWebSource? { origin.webSource }
    var domain: String? { source.flatMap { URL(string: $0.url)?.host } }
}
