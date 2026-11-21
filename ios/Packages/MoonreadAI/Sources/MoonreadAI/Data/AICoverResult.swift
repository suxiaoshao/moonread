import Foundation

public enum AIImageOrigin: Codable, Equatable, Sendable {
    case web(AIWebSource), generated, currentCover, unknown
    public var webSource: AIWebSource? { if case .web(let source) = self, source.isValid { source } else { nil } }
    public var isKnown: Bool { switch self { case .unknown: false; case .web(let source): source.isValid; default: true } }
    public var caption: String {
        switch self {
        case .web(let source): URL(string: source.url)?.host ?? String(localized: "图片")
        case .generated: String(localized: "生成")
        case .currentCover: String(localized: "封面参考")
        case .unknown: String(localized: "图片")
        }
    }
}
public struct AICoverProposal: Codable, Sendable, Identifiable {
    public var proposalRef: String
    public var bookRef: String
    public var attachment: AIImageAttachment
    public var origin: AIImageOrigin
    public var id: String { proposalRef }

    public init(
        proposalRef: String,
        bookRef: String,
        attachment: AIImageAttachment,
        origin: AIImageOrigin
    ) {
        self.proposalRef = proposalRef
        self.bookRef = bookRef
        self.attachment = attachment
        self.origin = origin
    }
}
public struct AIFindCoverResult: Codable, Sendable {
    public var bookRef: String
    public var candidates: [AICoverProposal]
    public var answer: String?
    public var sources: [AIWebSource] = []

    public init(
        bookRef: String,
        candidates: [AICoverProposal],
        answer: String? = nil,
        sources: [AIWebSource] = []
    ) {
        self.bookRef = bookRef
        self.candidates = candidates
        self.answer = answer
        self.sources = sources
    }
}
